import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../chat/content_direction.dart';
import '../shell/folio_controller.dart';
import 'workspace_hooks_card.dart';

/// Settings > Projects: each project's name, the folder its chats work in, and the
/// instructions every reply in it reads. The project list sits beside the editor at 680 px
/// and wider, above it when narrower.
class ProjectsSettingsView extends StatefulWidget {
  const ProjectsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ProjectsSettingsView> createState() => _ProjectsSettingsViewState();
}

class _ProjectsSettingsViewState extends State<ProjectsSettingsView> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _instructionsCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final FocusNode _instructionsFocus = FocusNode();

  /// The project shown; `''` while a new one is being written.
  String _selectedId = '';
  String _folderPath = '';
  bool _nameRequiredError = false;
  bool _confirmDelete = false;

  /// The hooks file of the saved project's folder, for review; null when it has none.
  EngineWorkspaceHooksStatus? _hooks;

  /// The controller's last open-on request this page followed.
  String? _followedRequest;

  @override
  void initState() {
    super.initState();
    _followRequest();
  }

  /// Shows the project the controller asked for (the sidebar's buttons), a new one for
  /// `''`, else the first project.
  void _followRequest() {
    final ctrl = widget.controller;
    final request = ctrl.editingProjectId;
    _followedRequest = request;
    final target = ctrl.projects.where((p) => p.id == request).firstOrNull;
    final shown = target ?? (request == '' ? null : ctrl.projects.firstOrNull);
    if (shown != null) {
      _load(shown);
    } else {
      _startNew();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _instructionsCtrl.dispose();
    _nameFocus.dispose();
    _instructionsFocus.dispose();
    super.dispose();
  }

  void _load(EngineProject p) {
    _hooks = null;
    unawaited(_loadHooks(p.id, p.folderPath));
    _selectedId = p.id;
    _folderPath = p.folderPath;
    _nameRequiredError = false;
    _confirmDelete = false;
    _nameCtrl.text = p.name;
    _instructionsCtrl.text = p.instructions;
  }

  /// Reads the hooks of [folder] for [projectId], kept only while that project is shown.
  Future<void> _loadHooks(String projectId, String folder) async {
    final hooks = await widget.controller.projectHooks(folder);
    if (mounted && _selectedId == projectId) setState(() => _hooks = hooks);
  }

  void _startNew() {
    _hooks = null;
    _selectedId = '';
    _folderPath = '';
    _nameRequiredError = false;
    _confirmDelete = false;
    _nameCtrl.clear();
    _instructionsCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _nameRequiredError = true);
      _nameFocus.requestFocus();
      return;
    }
    final ctrl = widget.controller;
    final existing = ctrl.projects
        .where((p) => p.id == _selectedId)
        .firstOrNull;
    final saved = await ctrl.saveProject(
      EngineProject(
        id: _selectedId,
        name: _nameCtrl.text,
        folderPath: _folderPath,
        instructions: _instructionsCtrl.text,
        createdAtMs: existing?.createdAtMs ?? 0,
      ),
    );
    if (saved != null && mounted) setState(() => _load(saved));
  }

  Future<void> _pickFolder(BistreLocalizationController l10n) async {
    final picked = await BistreDesktopHost.pickLocalFolder(
      title: l10n.t(L10nKey.settingsProjectsFolder),
    );
    if (picked != null && mounted) setState(() => _folderPath = picked);
  }

  Future<void> _delete() async {
    if (!_confirmDelete) {
      setState(() => _confirmDelete = true);
      return;
    }
    final ctrl = widget.controller;
    await ctrl.deleteProject(_selectedId);
    if (!mounted) return;
    setState(() {
      final next = ctrl.projects.firstOrNull;
      if (next != null) {
        _load(next);
      } else {
        _startNew();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    if (ctrl.editingProjectId != _followedRequest) _followRequest();
    // A project deleted elsewhere (the sidebar) leaves the editor on the next one.
    if (_selectedId.isNotEmpty &&
        !ctrl.projects.any((p) => p.id == _selectedId)) {
      final next = ctrl.projects.firstOrNull;
      if (next != null) {
        _load(next);
      } else {
        _startNew();
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final list = _buildList(theme, l10n, ctrl);
        final editor = _buildEditor(theme, l10n, ctrl);
        if (constraints.maxWidth < 680) {
          return SmoothScrollable(
            builder: (_, scroll) => SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  list,
                  const SizedBox(height: BistreSpacing.s16),
                  const FolioDivider(),
                  const SizedBox(height: BistreSpacing.s16),
                  editor,
                ],
              ),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 248,
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 18, 12, 24),
                  child: list,
                ),
              ),
            ),
            const FolioDivider(vertical: true),
            Expanded(
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 36),
                  child: editor,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Secondary button: Create/Save in the editor carries the single primary CTA weight.
        EngravedButton(
          label: l10n.t(L10nKey.settingsProjectsNew),
          leading: BistreIcon(
            BistreUiIcon.plus,
            size: 14,
            color: theme.accentBrass,
          ),
          onPressed: () => setState(_startNew),
        ),
        const SizedBox(height: BistreSpacing.s12),
        for (final p in ctrl.projects) ...[
          _ProjectListTile(
            project: p,
            selected: p.id == _selectedId,
            onTap: () => setState(() => _load(p)),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  Widget _buildEditor(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final creating = _selectedId.isEmpty;
    final folder = _folderPath.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkText(
          creating
              ? l10n.t(L10nKey.settingsProjectsNew)
              : l10n.t(L10nKey.settingsProjectsEditTitle),
          role: InkTextRole.titleLarge,
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          children: [
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsAssistantsNameLabel),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  QuillInput(
                    controller: _nameCtrl,
                    focusNode: _nameFocus,
                    placeholder: l10n.t(
                      L10nKey.settingsProjectsNamePlaceholder,
                    ),
                    maxLines: 1,
                    submitOnEnter: false,
                    onChanged: (_) {
                      if (_nameRequiredError &&
                          _nameCtrl.text.trim().isNotEmpty) {
                        setState(() => _nameRequiredError = false);
                      }
                    },
                    onSubmitted: () => unawaited(_save()),
                  ),
                  if (_nameRequiredError) ...[
                    const SizedBox(height: 6),
                    InkText(
                      l10n.t(L10nKey.diagValidationInvalidInput),
                      role: InkTextRole.captionMeta,
                      color: theme.statusErr,
                    ),
                  ],
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsProjectsFolder),
              description: l10n.t(L10nKey.settingsProjectsFolderHint),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (folder.isNotEmpty) ...[
                    // A path keeps its own order: `/books/x` never reads `books/x/` in RTL.
                    OwnDirection(
                      text: folder,
                      child: InkText(
                        folder,
                        role: InkTextRole.codeBlock,
                        color: theme.inkPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: BistreSpacing.s8,
                    runSpacing: BistreSpacing.s8,
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsProjectsChooseFolder),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.folder,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        onPressed: () => unawaited(_pickFolder(l10n)),
                      ),
                      if (folder.isNotEmpty)
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsProjectsClearFolder),
                          compact: true,
                          onPressed: () => setState(() => _folderPath = ''),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsProjectsInstructions),
              description: l10n.t(L10nKey.settingsProjectsInstructionsHint),
              bottom: QuillInput(
                controller: _instructionsCtrl,
                focusNode: _instructionsFocus,
                placeholder: l10n.t(
                  L10nKey.settingsProjectsInstructionsPlaceholder,
                ),
                minLines: 4,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
          ],
        ),
        if (_hooks case final hooks? when !creating) ...[
          const SizedBox(height: BistreSpacing.s16),
          WorkspaceHooksCard(
            hooks: hooks,
            onAllow: () => unawaited(() async {
              final saved = ctrl.projects
                  .where((p) => p.id == _selectedId)
                  .firstOrNull;
              if (saved == null) return;
              await ctrl.approveProjectHooks(saved.folderPath, hooks.digest);
              await _loadHooks(saved.id, saved.folderPath);
            }()),
          ),
        ],
        const SizedBox(height: BistreSpacing.s16),
        Wrap(
          spacing: BistreSpacing.s8,
          runSpacing: BistreSpacing.s8,
          children: [
            EngravedButton(
              label: creating
                  ? l10n.t(L10nKey.settingsProjectsCreate)
                  : l10n.t(L10nKey.settingsAssistantsSaveAction),
              primary: true,
              onPressed: () => unawaited(_save()),
            ),
            if (!creating) ...[
              EngravedButton(
                label: l10n.t(L10nKey.sidebarProjectNewChat),
                leading: BistreIcon(
                  BistreUiIcon.newChat,
                  size: 13,
                  color: theme.inkSecondary,
                ),
                onPressed: () {
                  ctrl.closeSettings();
                  unawaited(ctrl.createChatInProject(_selectedId));
                },
              ),
              EngravedButton(
                label: _confirmDelete
                    ? l10n.t(L10nKey.settingsProjectsDeleteConfirm)
                    : l10n.t(L10nKey.settingsProjectsDelete),
                leading: BistreIcon(
                  BistreUiIcon.trash,
                  size: 13,
                  color: theme.statusErr,
                ),
                onPressed: () => unawaited(_delete()),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ProjectListTile extends StatefulWidget {
  const _ProjectListTile({
    required this.project,
    required this.selected,
    required this.onTap,
  });

  final EngineProject project;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ProjectListTile> createState() => _ProjectListTileState();
}

class _ProjectListTileState extends State<_ProjectListTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final p = widget.project;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: p.name,
      child: FocusableActionDetector(
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: PressFeedback(
            pressScale: kRowPressScale,
            hoverScale: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minTapTarget),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? theme.bgElevated
                        : (_hovered ? theme.hoverTint : null),
                    borderRadius: BorderRadius.circular(10),
                    border: _focused
                        ? Border.all(color: theme.accentBrass, width: 1.4)
                        : (widget.selected
                              ? Border.all(color: theme.borderHairline)
                              : null),
                    boxShadow: widget.selected ? theme.cardShadow : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        BistreIcon(
                          BistreUiIcon.folder,
                          size: 15,
                          color: widget.selected
                              ? theme.accentBrass
                              : theme.inkSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkText(
                            p.name,
                            role: widget.selected
                                ? InkTextRole.labelStrong
                                : InkTextRole.bodyCompact,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
