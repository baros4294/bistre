import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Unified Settings view (`SettingsTab.memory`) for:
/// 1. Cross-Chat Saved Memory (local SQLite `memory_entries`)
/// 2. Progressive-disclosure Workspace Skills (`SKILL.md`)
/// 3. Background Scheduled Tasks (`cron_jobs` owned by `bistre-daemon` / Android `WorkManager`).
class MemorySkillsSettingsView extends StatefulWidget {
  const MemorySkillsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<MemorySkillsSettingsView> createState() =>
      _MemorySkillsSettingsViewState();
}

class _MemorySkillsSettingsViewState extends State<MemorySkillsSettingsView> {
  final TextEditingController _memContentCtrl = TextEditingController();
  final FocusNode _memContentFocus = FocusNode();
  final TextEditingController _cronNameCtrl = TextEditingController();
  final FocusNode _cronNameFocus = FocusNode();
  final TextEditingController _cronExprCtrl = TextEditingController();
  final FocusNode _cronExprFocus = FocusNode();
  final TextEditingController _cronPromptCtrl = TextEditingController();
  final FocusNode _cronPromptFocus = FocusNode();

  String? _expandedSkillPath;
  String _expandedSkillBody = '';

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshMemorySkillsAndCron());
  }

  @override
  void dispose() {
    _memContentCtrl.dispose();
    _memContentFocus.dispose();
    _cronNameCtrl.dispose();
    _cronNameFocus.dispose();
    _cronExprCtrl.dispose();
    _cronExprFocus.dispose();
    _cronPromptCtrl.dispose();
    _cronPromptFocus.dispose();
    super.dispose();
  }

  Future<void> _saveMemory() async {
    final text = _memContentCtrl.text.trim();
    if (text.isEmpty) return;
    await widget.controller.addMemoryEntry(content: text);
    if (mounted) _memContentCtrl.clear();
  }

  Future<void> _addSchedule() async {
    final expr = _cronExprCtrl.text.trim();
    final prompt = _cronPromptCtrl.text.trim();
    if (expr.isEmpty || prompt.isEmpty) return;
    final name = _cronNameCtrl.text.trim().isEmpty
        ? prompt.split('\n').first
        : _cronNameCtrl.text.trim();
    await widget.controller.createCronJob(
      name: name,
      scheduleExpr: expr,
      prompt: prompt,
    );
    if (mounted) {
      _cronNameCtrl.clear();
      _cronExprCtrl.clear();
      _cronPromptCtrl.clear();
    }
  }

  Future<void> _toggleSkill(EngineSkillIndex skill) async {
    if (_expandedSkillPath == skill.path) {
      setState(() {
        _expandedSkillPath = null;
        _expandedSkillBody = '';
      });
      return;
    }
    final body = await widget.controller.loadSkillBody(skill.path);
    if (mounted) {
      setState(() {
        _expandedSkillPath = skill.path;
        _expandedSkillBody = body;
      });
    }
  }

  static String _formatCronMeta(
    BistreLocalizationController l10n,
    EngineCronJob job,
  ) => l10n.joinMeta(<String>[job.scheduleExpr, job.lastStatus]);

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final memories = ctrl.memoryEntries;
    final skills = ctrl.discoveredSkills;
    final jobs = ctrl.cronJobs;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Cross-Chat Saved Memory
            FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.all(18),
              boxShadow: theme.cardShadow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.memory,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.memoryTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: QuillInput(
                          controller: _memContentCtrl,
                          focusNode: _memContentFocus,
                          placeholder: l10n.t(L10nKey.memoryAddPlaceholder),
                          maxLines: 1,
                          onSubmitted: () => unawaited(_saveMemory()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      EngravedButton(
                        label: l10n.t(L10nKey.memoryAddAction),
                        primary: true,
                        compact: true,
                        onPressed: () => unawaited(_saveMemory()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (memories.isEmpty)
                    InkText(
                      l10n.t(L10nKey.memoryEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    )
                  else
                    for (final mem in memories) ...[
                      FolioSurface(
                        child: Row(
                          children: [
                            Expanded(
                              child: InkText(
                                mem.content,
                                role: InkTextRole.bodyCompact,
                                color: theme.inkPrimary,
                              ),
                            ),
                            const SizedBox(width: 6),
                            BistreIconButton(
                              icon: mem.pinned
                                  ? BistreUiIcon.pinFilled
                                  : BistreUiIcon.pin,
                              size: 13,
                              dimension: 26,
                              color: mem.pinned
                                  ? theme.accentBrass
                                  : theme.inkMuted,
                              semanticsLabel: l10n.t(L10nKey.threadPin),
                              onPressed: () =>
                                  unawaited(ctrl.toggleMemoryPinned(mem)),
                            ),
                            BistreIconButton(
                              icon: BistreUiIcon.trash,
                              size: 13,
                              dimension: 26,
                              semanticsLabel: l10n.t(L10nKey.threadDelete),
                              onPressed: () =>
                                  unawaited(ctrl.deleteMemoryEntry(mem.id)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 2. Scheduled Tasks (Automations)
            FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.all(18),
              boxShadow: theme.cardShadow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.schedule,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.automationsTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: QuillInput(
                          controller: _cronNameCtrl,
                          focusNode: _cronNameFocus,
                          placeholder: l10n.t(L10nKey.automationsTitle),
                          maxLines: 1,
                          onSubmitted: () => unawaited(_addSchedule()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: QuillInput(
                          controller: _cronExprCtrl,
                          focusNode: _cronExprFocus,
                          placeholder: l10n.t(
                            L10nKey.automationsSchedulePlaceholder,
                          ),
                          maxLines: 1,
                          onSubmitted: () => unawaited(_addSchedule()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: QuillInput(
                          controller: _cronPromptCtrl,
                          focusNode: _cronPromptFocus,
                          placeholder: l10n.t(
                            L10nKey.automationsPromptPlaceholder,
                          ),
                          maxLines: 1,
                          onSubmitted: () => unawaited(_addSchedule()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      EngravedButton(
                        label: l10n.t(L10nKey.automationsAddAction),
                        primary: true,
                        compact: true,
                        onPressed: () => unawaited(_addSchedule()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (jobs.isEmpty)
                    InkText(
                      l10n.t(L10nKey.automationsEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    )
                  else
                    for (final job in jobs) ...[
                      FolioSurface(
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  InkText(
                                    job.name,
                                    role: InkTextRole.labelStrong,
                                  ),
                                  const SizedBox(height: 2),
                                  InkText(
                                    _formatCronMeta(l10n, job),
                                    role: InkTextRole.captionMeta,
                                    color: theme.inkMuted,
                                  ),
                                ],
                              ),
                            ),
                            BistreSwitch(
                              value: job.enabled,
                              semanticsLabel: job.name,
                              reduceMotionOverride: ctrl.reduceMotionOverride,
                              onChanged: (enabled) => unawaited(
                                ctrl.toggleCronJobEnabled(job, enabled),
                              ),
                            ),
                            const SizedBox(width: 6),
                            BistreIconButton(
                              icon: BistreUiIcon.trash,
                              size: 13,
                              dimension: 26,
                              semanticsLabel: l10n.t(L10nKey.threadDelete),
                              onPressed: () =>
                                  unawaited(ctrl.deleteCronJob(job.id)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 3. Progressive-Disclosure Workspace Skills (SKILL.md)
            FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.all(18),
              boxShadow: theme.cardShadow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.worktree,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.skillsTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (skills.isEmpty)
                    InkText(
                      l10n.t(L10nKey.skillsEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    )
                  else
                    for (final sk in skills) ...[
                      FolioSurface(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => unawaited(_toggleSkill(sk)),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        InkText(
                                          sk.name,
                                          role: InkTextRole.labelStrong,
                                        ),
                                        if (sk.description.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          InkText(
                                            sk.description,
                                            role: InkTextRole.captionMeta,
                                            color: theme.inkSecondary,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  BistreIcon(
                                    _expandedSkillPath == sk.path
                                        ? BistreUiIcon.chevronUp
                                        : BistreUiIcon.chevronDown,
                                    size: 13,
                                    color: theme.inkMuted,
                                  ),
                                ],
                              ),
                            ),
                            DisclosureReveal(
                              open:
                                  _expandedSkillPath == sk.path &&
                                  _expandedSkillBody.isNotEmpty,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 8),
                                  const FolioDivider(),
                                  const SizedBox(height: 8),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 200,
                                    ),
                                    child: SmoothScrollable(
                                      builder: (_, scroll) =>
                                          SingleChildScrollView(
                                            controller: scroll,
                                            child: InkText(
                                              _expandedSkillBody,
                                              role: InkTextRole.codeBlock,
                                              color: theme.inkSecondary,
                                            ),
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
