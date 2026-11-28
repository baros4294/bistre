//! FFI entrypoints for projects: named groups of chats with a folder and instructions.

use bistre_protocol::ProjectRecord;

use super::{current_engine, frb};
use crate::dto_mapping::ffi_err;

/// Thin FFI DTO mirror of `ProjectRecord`; an empty `folder_path` keeps the app's open folders.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiProject {
    pub id: String,
    pub name: String,
    pub folder_path: String,
    pub instructions: String,
    pub created_at_ms: i64,
}

fn map_project(p: ProjectRecord) -> FfiProject {
    FfiProject {
        id: p.id,
        name: p.name,
        folder_path: p.folder_path,
        instructions: p.instructions,
        created_at_ms: p.created_at_ms,
    }
}

/// Every project, oldest first.
#[frb]
pub async fn list_projects() -> Result<Vec<FfiProject>, String> {
    let projects = current_engine()?.list_projects().await.map_err(ffi_err)?;
    Ok(projects.into_iter().map(map_project).collect())
}

/// Creates (empty `id`) or updates a project and returns it as saved.
#[frb]
pub async fn save_project(project: FfiProject) -> Result<FfiProject, String> {
    let saved = current_engine()?
        .save_project(ProjectRecord {
            id: project.id,
            name: project.name,
            folder_path: project.folder_path,
            instructions: project.instructions,
            created_at_ms: project.created_at_ms,
        })
        .await
        .map_err(ffi_err)?;
    Ok(map_project(saved))
}

/// Deletes a project; its chats stay, outside any project.
#[frb]
pub async fn delete_project(project_id: String) -> Result<(), String> {
    current_engine()?
        .delete_project(project_id)
        .await
        .map_err(ffi_err)
}

/// Moves a chat into `project_id`, or out of every project with `None`.
#[frb]
pub async fn move_thread_to_project(
    thread_id: String,
    project_id: Option<String>,
) -> Result<(), String> {
    current_engine()?
        .move_thread_to_project(thread_id, project_id)
        .await
        .map_err(ffi_err)
}
