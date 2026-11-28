//! Projects: named groups of chats with a folder they work in and instructions every reply in
//! them reads. A project is a `workspaces` row; a chat's `workspace_id` names its project.

use std::path::PathBuf;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ProjectRecord};
use bistre_storage::StorageHandle;

use crate::{BoxFuture, InProcessEngine};

/// Most projects one data folder keeps.
pub const MAX_PROJECTS: usize = 200;
/// Longest project name, in characters.
pub const MAX_PROJECT_NAME_CHARS: usize = 120;
/// Longest project instructions, in characters.
pub const MAX_PROJECT_INSTRUCTIONS_CHARS: usize = 16_000;

fn invalid(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::InvalidInput, detail)
}

/// The chat's project, or `None` outside one. An unreadable chat or project is an error, so
/// a reply never runs in the wrong folder or without its instructions.
fn project_of(storage: &StorageHandle, thread_id: &str) -> BistreResult<Option<ProjectRecord>> {
    let Some(thread) = storage.get_thread(thread_id)? else {
        return Ok(None);
    };
    storage.get_project(&thread.workspace_id)
}

/// The folders a chat's tools work in: its project's folder when the project has one, else
/// the folders the app has open. With no chat (`None`), the app's folders.
pub(crate) fn workspace_roots_for(
    storage: &StorageHandle,
    thread_id: Option<&str>,
) -> BistreResult<Vec<PathBuf>> {
    if let Some(id) = thread_id
        && let Some(project) = project_of(storage, id)?
        && !project.folder_path.trim().is_empty()
    {
        return Ok(vec![PathBuf::from(project.folder_path.trim())]);
    }
    Ok(crate::agent_context::load_workspace_roots(storage))
}

/// The chat's project instructions under their heading, as a reply sends them; `None`
/// outside a project or when the project has none.
pub(crate) fn project_instructions(
    storage: &StorageHandle,
    thread_id: &str,
) -> BistreResult<Option<String>> {
    let Some(project) = project_of(storage, thread_id)? else {
        return Ok(None);
    };
    let text = project.instructions.trim();
    Ok((!text.is_empty()).then(|| format!("[Project instructions]\n{text}")))
}

/// Adds the chat's project instructions to `prompt` after a blank line.
pub(crate) fn append_project_instructions(
    storage: &StorageHandle,
    thread_id: &str,
    prompt: &mut String,
) -> BistreResult<()> {
    if let Some(block) = project_instructions(storage, thread_id)? {
        if !prompt.trim().is_empty() {
            prompt.push_str("\n\n");
        }
        prompt.push_str(&block);
    }
    Ok(())
}

impl InProcessEngine {
    pub fn list_projects(&self) -> BoxFuture<'_, BistreResult<Vec<ProjectRecord>>> {
        Box::pin(async move { self.storage.list_projects() })
    }

    /// Creates (empty id) or updates a project. The name is required; the name, folder, and
    /// instructions are trimmed and bounded.
    pub fn save_project(
        &self,
        project: ProjectRecord,
    ) -> BoxFuture<'_, BistreResult<ProjectRecord>> {
        Box::pin(async move {
            let name = project.name.trim();
            if name.is_empty() || name.chars().count() > MAX_PROJECT_NAME_CHARS {
                return Err(invalid("project_name_length"));
            }
            let instructions = project.instructions.trim();
            if instructions.chars().count() > MAX_PROJECT_INSTRUCTIONS_CHARS {
                return Err(invalid("project_instructions_length"));
            }
            if project.id.trim().is_empty() && self.storage.list_projects()?.len() >= MAX_PROJECTS {
                return Err(invalid("too_many_projects"));
            }
            self.storage.save_project(ProjectRecord {
                id: project.id.trim().to_owned(),
                name: name.to_owned(),
                folder_path: project.folder_path.trim().to_owned(),
                instructions: instructions.to_owned(),
                created_at_ms: project.created_at_ms,
            })
        })
    }

    /// Deletes a project; its chats stay, outside any project.
    pub fn delete_project(&self, project_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_project(project_id) })
    }

    /// Moves a chat into `project_id`, or out of every project with `None`.
    pub fn move_thread_to_project(
        &self,
        thread_id: String,
        project_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.move_thread_to_project(thread_id, project_id) })
    }
}

#[cfg(test)]
#[path = "projects_tests.rs"]
mod tests;
