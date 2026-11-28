//! Project repository (`impl StorageHandle`): the `workspaces` rows other than the default one,
//! and which project a chat belongs to.

use super::{
    BistreError, BistreResult, DEFAULT_WORKSPACE_ID, DiagnosticKey, OptionalExtension,
    ProjectRecord, StorageHandle, Uuid, map_sqlite_err, now_unix_ms, params,
};

fn read_project(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProjectRecord> {
    Ok(ProjectRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        folder_path: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        instructions: row.get(3)?,
        created_at_ms: row.get(4)?,
    })
}

impl StorageHandle {
    /// Every project, oldest first (the default workspace is not one).
    pub fn list_projects(&self) -> BistreResult<Vec<ProjectRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, root_path, instructions, created_at_ms FROM workspaces
                 WHERE id != ?1 ORDER BY created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![DEFAULT_WORKSPACE_ID], read_project)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// The project `project_id`, or `None` for the default workspace or an unknown id.
    pub fn get_project(&self, project_id: &str) -> BistreResult<Option<ProjectRecord>> {
        if project_id == DEFAULT_WORKSPACE_ID {
            return Ok(None);
        }
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT id, name, root_path, instructions, created_at_ms FROM workspaces WHERE id = ?1",
            params![project_id],
            read_project,
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Creates the project (empty id) or updates it; the caller has validated the fields.
    pub fn save_project(&self, mut project: ProjectRecord) -> BistreResult<ProjectRecord> {
        if project.id == DEFAULT_WORKSPACE_ID {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "default_workspace_is_no_project",
            ));
        }
        if project.id.trim().is_empty() {
            project.id = Uuid::now_v7().to_string();
            project.created_at_ms = now_unix_ms();
        }
        self.write(move |conn| {
            let folder = (!project.folder_path.trim().is_empty()).then(|| project.folder_path.clone());
            let changed = conn
                .execute(
                    "INSERT INTO workspaces (id, name, root_path, instructions, created_at_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                         root_path = excluded.root_path, instructions = excluded.instructions",
                    params![
                        project.id,
                        project.name,
                        folder,
                        project.instructions,
                        project.created_at_ms
                    ],
                )
                .map_err(map_sqlite_err)?;
            if changed == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            conn.query_row(
                "SELECT id, name, root_path, instructions, created_at_ms FROM workspaces WHERE id = ?1",
                params![project.id],
                read_project,
            )
            .map_err(map_sqlite_err)
        })
    }

    /// Deletes the project; its chats move to the default workspace first, so none is lost.
    pub fn delete_project(&self, project_id: String) -> BistreResult<()> {
        if project_id == DEFAULT_WORKSPACE_ID {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "default_workspace_is_no_project",
            ));
        }
        self.write(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            tx.execute(
                "UPDATE threads SET workspace_id = ?1 WHERE workspace_id = ?2",
                params![DEFAULT_WORKSPACE_ID, project_id],
            )
            .map_err(map_sqlite_err)?;
            tx.execute("DELETE FROM workspaces WHERE id = ?1", params![project_id])
                .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })
    }

    /// Moves a chat into `project_id`, or out of every project with `None`.
    pub fn move_thread_to_project(
        &self,
        thread_id: String,
        project_id: Option<String>,
    ) -> BistreResult<()> {
        let target = project_id.unwrap_or_else(|| DEFAULT_WORKSPACE_ID.to_owned());
        self.write(move |conn| {
            let known: bool = conn
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?1)",
                    params![target],
                    |row| row.get(0),
                )
                .map_err(map_sqlite_err)?;
            if !known {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            let changed = conn
                .execute(
                    "UPDATE threads SET workspace_id = ?1 WHERE id = ?2",
                    params![target, thread_id],
                )
                .map_err(map_sqlite_err)?;
            if changed == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            Ok(())
        })
    }
}
