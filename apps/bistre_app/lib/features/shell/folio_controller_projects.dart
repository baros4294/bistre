part of 'folio_controller.dart';

/// Projects: named groups of chats with a folder they work in and instructions core sends
/// with every reply in them. Core owns them; this keeps the list the sidebar groups by.
extension FolioProjects on FolioController {
  List<EngineProject> get projects => _projects;

  /// The project Settings > Projects opens on: an id, `''` for a new one, or null.
  String? get editingProjectId => _editingProjectId;

  /// The chat's project, or null outside one.
  EngineProject? projectOf(EngineThread? thread) {
    if (thread == null) return null;
    return _projects.where((p) => p.id == thread.workspaceId).firstOrNull;
  }

  /// The folder the open chat's tools work in: its project's folder when the project has
  /// one, else the app's open folder (core resolves the same way).
  String get workspaceRootPath {
    final folder = projectOf(_activeThread)?.folderPath.trim() ?? '';
    return folder.isNotEmpty ? folder : _workspaceRootPath;
  }

  /// Opens Settings > Projects on [projectId], or on a new project with `''`.
  void openProjectEditor(String projectId) {
    _editingProjectId = projectId;
    openSettings(SettingsTab.projects);
  }

  Future<void> _loadProjects() async {
    try {
      _projects = await _gateway.listProjects();
    } catch (e) {
      _noteNonFatal('load_projects', e);
    }
  }

  /// Creates (empty id) or updates a project; the saved project, or null on failure.
  Future<EngineProject?> saveProject(EngineProject project) async {
    try {
      final saved = await _gateway.saveProject(project);
      _projects = await _gateway.listProjects();
      if (_editingProjectId == '') _editingProjectId = saved.id;
      _syncChatFolder();
      showToast(L10nKey.toastSettingsSaved);
      _notify();
      return saved;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  /// Deletes a project; its chats stay, outside any project.
  Future<void> deleteProject(String projectId) async {
    try {
      await _gateway.deleteProject(projectId);
      if (_editingProjectId == projectId) _editingProjectId = null;
      await _reloadProjectsAndChats();
      showToast(L10nKey.toastDeleted);
    } catch (e) {
      _fail(e);
    }
  }

  /// Moves a chat into [projectId], or out of every project with null.
  Future<void> moveThreadToProject(String threadId, String? projectId) async {
    try {
      await _gateway.moveThreadToProject(threadId, projectId);
      await _reloadProjectsAndChats();
    } catch (e) {
      _fail(e);
    }
  }

  /// The open chat's project when that project has its own folder: the chat works only
  /// there, so folder pickers open the project's settings instead.
  EngineProject? get folderProject => switch (projectOf(activeThread)) {
    final p? when p.folderPath.trim().isNotEmpty => p,
    _ => null,
  };

  /// The hooks file in a project's [folder] for review, or null when it has none or it
  /// could not be read (the reason is kept as the last diagnostic).
  Future<EngineWorkspaceHooksStatus?> projectHooks(String folder) async {
    if (folder.trim().isEmpty) return null;
    try {
      return await _gateway.workspaceHooksStatus(folder.trim());
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      return null;
    }
  }

  /// Allows the hooks of a project's [folder] exactly as shown; core refuses a file that
  /// changed since ([digest] no longer matches).
  Future<void> approveProjectHooks(String folder, String digest) async {
    try {
      await _gateway.approveWorkspaceHooks(folder.trim(), digest);
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _fail(e);
    }
  }

  /// Starts a chat in [projectId] and opens it.
  Future<void> createChatInProject(String projectId) =>
      createNewFolio(projectId: projectId);

  Future<void> _reloadProjectsAndChats() async {
    final (projects, threads) = await (
      _gateway.listProjects(),
      _gateway.listThreads(),
    ).wait;
    _projects = projects;
    _threads = _withoutPendingDeletes(threads);
    final activeId = _activeThread?.id;
    _activeThread =
        _threads.where((t) => t.id == activeId).firstOrNull ?? _activeThread;
    _syncChatFolder();
    _notify();
  }

  /// The open chat's folder changed (another chat, a move, a project edit): the branch
  /// chip follows it. The `@` menu's entries are keyed by folder and reload on their own.
  void _syncChatFolder() {
    if (workspaceRootPath.trim() != _branchRoot) unawaited(_refreshGitBranch());
  }
}
