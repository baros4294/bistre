import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/power_guard_host.dart';
import '../shell/folio_controller.dart';

/// Multi-tab right-hand Studio Pane (`328px` wide, hidden by default) hosting:
/// - `[Runs]`: OS Sleep & Disruption Guard, active/recent SQLite-journaled runs, `INDETERMINATE_HALT`
///   reconciliation, and mid-stream steering queue.
/// - `[Files]`: Touched workspace files / checkpoints with 1-click Rewind & inline `"Comment in chat"`
///   chips (`@file:L1-L20` attached straight into composer).
/// - `[Story]` & `[Prompt]`: Story Bible & Live Prompt Inspector tabs (extended in Wave E).
class RunsDockPanel extends StatelessWidget {
  const RunsDockPanel({
    super.key,
    required this.controller,
    this.storyTabBuilder,
    this.promptTabBuilder,
  });

  final FolioController controller;
  final WidgetBuilder? storyTabBuilder;
  final WidgetBuilder? promptTabBuilder;

  static const List<(StudioTab, L10nKey, BistreUiIcon)> _tabs =
      <(StudioTab, L10nKey, BistreUiIcon)>[
        (StudioTab.runs, L10nKey.studioTabRuns, BistreUiIcon.awake),
        (StudioTab.files, L10nKey.studioTabFiles, BistreUiIcon.folder),
        (StudioTab.story, L10nKey.studioTabStory, BistreUiIcon.bookOpen),
        (StudioTab.prompt, L10nKey.studioTabPrompt, BistreUiIcon.eye),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final power = controller.powerStatus;
    final activeTab = controller.studioTab;

    return SizedBox(
      width: 328,
      child: ColoredBox(
        color: theme.bgSurface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 8, 8),
              child: Row(
                children: [
                  BistreIcon(
                    BistreUiIcon.server,
                    size: 15,
                    color: theme.accentBrass,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkText(
                      l10n.t(L10nKey.studioTitle),
                      role: InkTextRole.labelStrong,
                      color: theme.inkPrimary,
                    ),
                  ),
                  if (power.keepAwakeActive)
                    WaxSealBadge(label: l10n.t(L10nKey.studioAwakeBadge)),
                  const SizedBox(width: 4),
                  BistreIconButton(
                    icon: BistreUiIcon.close,
                    size: 14,
                    dimension: 28,
                    semanticsLabel: l10n.t(L10nKey.threadCancel),
                    onPressed: controller.toggleStudioPane,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < _tabs.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      InkChip(
                        label: l10n.t(_tabs[i].$2),
                        selected: activeTab == _tabs[i].$1,
                        onSelected: () => controller.setStudioTab(_tabs[i].$1),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const FolioDivider(),
            Expanded(
              child: switch (activeTab) {
                StudioTab.runs => _RunsTabBody(controller: controller),
                StudioTab.files => _FilesTabBody(controller: controller),
                StudioTab.story =>
                  storyTabBuilder?.call(context) ??
                      const _StoryPlaceholderBody(
                        titleKey: L10nKey.studioTabStory,
                        bodyKey: L10nKey.storyCodexTitle,
                      ),
                StudioTab.prompt =>
                  promptTabBuilder?.call(context) ??
                      const _StoryPlaceholderBody(
                        titleKey: L10nKey.storyInspectorTitle,
                        bodyKey: L10nKey.storyInspectorLoreTrace,
                      ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RunsTabBody extends StatelessWidget {
  const _RunsTabBody({required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final power = controller.powerStatus;
    final runs = controller.agentRuns;
    final steering = controller.pendingSteering;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PowerGuardCard(power: power, controller: controller),
            if (steering.isNotEmpty) ...[
              const SizedBox(height: 14),
              InkText(
                l10n.t(L10nKey.composerSteerQueued, <String, Object?>{
                  'count': steering.length,
                }),
                role: InkTextRole.captionMeta,
                color: theme.inkMuted,
              ),
              const SizedBox(height: 6),
              for (final msg in steering) ...[
                FolioSurface(
                  tone: FolioTone.elevated,
                  padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkText(
                          msg.content,
                          role: InkTextRole.bodyCompact,
                          color: theme.inkPrimary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 12,
                        dimension: 24,
                        semanticsLabel: l10n.t(L10nKey.threadCancel),
                        onPressed: () =>
                            unawaited(controller.removeSteeringMessage(msg.id)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
              ],
            ],
            const SizedBox(height: 14),
            InkText(
              l10n.t(L10nKey.studioTabRuns),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
            const SizedBox(height: 8),
            if (runs.isEmpty)
              FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.all(14),
                child: InkText(
                  l10n.t(L10nKey.studioRunsEmpty),
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
              )
            else
              for (final run in runs) ...[
                _RunCard(run: run, controller: controller),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

class _FilesTabBody extends StatelessWidget {
  const _FilesTabBody({required this.controller});

  final FolioController controller;

  static String _formatHashPair(EngineCheckpoint cp) {
    final pre = cp.preHashBlake3.length <= 8
        ? cp.preHashBlake3
        : cp.preHashBlake3.substring(0, 8);
    final post = cp.postHashBlake3.length <= 8
        ? cp.postHashBlake3
        : cp.postHashBlake3.substring(0, 8);
    return '$pre -> $post';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final checkpoints = controller.checkpoints;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (checkpoints.isEmpty)
              FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.all(14),
                child: InkText(
                  l10n.t(L10nKey.studioFilesEmpty),
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
              )
            else
              for (final cp in checkpoints) ...[
                FolioSurface(
                  tone: FolioTone.elevated,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          BistreIcon(
                            BistreUiIcon.document,
                            size: 13,
                            color: theme.accentBrass,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: InkText(
                              cp.filePath,
                              role: InkTextRole.labelStrong,
                              color: theme.inkPrimary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      InkText(
                        _formatHashPair(cp),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          EngravedButton(
                            label: l10n.t(L10nKey.studioCommentAdd),
                            compact: true,
                            onPressed: () => controller.attachInlineFileComment(
                              cp.filePath,
                              'L1-L20',
                            ),
                          ),
                          EngravedButton(
                            label: l10n.t(L10nKey.toolRewind),
                            compact: true,
                            leading: BistreIcon(
                              BistreUiIcon.rewind,
                              size: 12,
                              color: theme.inkSecondary,
                            ),
                            onPressed: () =>
                                unawaited(controller.rewindCheckpoint(cp.id)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

class _StoryPlaceholderBody extends StatelessWidget {
  const _StoryPlaceholderBody({required this.titleKey, required this.bodyKey});

  final L10nKey titleKey;
  final L10nKey bodyKey;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.all(14),
      child: FolioSurface(
        tone: FolioTone.elevated,
        padding: const EdgeInsetsDirectional.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkText(l10n.t(titleKey), role: InkTextRole.labelStrong),
            const SizedBox(height: 6),
            InkText(
              l10n.t(bodyKey),
              role: InkTextRole.bodyCompact,
              color: theme.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _PowerGuardCard extends StatelessWidget {
  const _PowerGuardCard({required this.power, required this.controller});

  final EnginePowerGuardStatus power;
  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final isAwake = power.keepAwakeActive || power.androidFgsActive;

    return FolioSurface(
      tone: FolioTone.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkText(
                  l10n.t(L10nKey.studioPowerGuardTitle),
                  role: InkTextRole.labelStrong,
                  color: theme.inkPrimary,
                ),
              ),
              WaxSealBadge(
                label: isAwake
                    ? l10n.t(L10nKey.studioAwakeBadge)
                    : power.platform.toUpperCase(),
                status: isAwake ? WaxSealStatus.ok : WaxSealStatus.neutral,
              ),
            ],
          ),
          const SizedBox(height: 6),
          InkText(
            isAwake
                ? l10n.t(L10nKey.studioPowerActive)
                : l10n.t(L10nKey.studioPowerIdle),
            role: InkTextRole.captionMeta,
            color: theme.inkSecondary,
          ),
          if (BistrePowerGuardHost.isAndroid &&
              !power.androidBatteryUnrestricted) ...[
            const SizedBox(height: 10),
            EngravedButton(
              label: l10n.t(L10nKey.settingsSleepAndroidBatteryAllow),
              compact: true,
              onPressed: () =>
                  unawaited(controller.requestAndroidBatteryUnrestricted()),
            ),
          ],
        ],
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, required this.controller});

  final EngineAgentRun run;
  final FolioController controller;

  static String _formatRunTitle(
    BistreLocalizationController l10n,
    EngineAgentRun run,
  ) => l10n.joinMeta(<String>[run.mode.toUpperCase(), '#${run.stepIndex + 1}']);

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final statusBadge = switch (run.status) {
      'running' => WaxSealStatus.warn,
      'completed' => WaxSealStatus.ok,
      'indeterminate_halt' || 'failed' => WaxSealStatus.error,
      _ => WaxSealStatus.neutral,
    };

    final runTitle = _formatRunTitle(l10n, run);
    return FolioSurface(
      tone: FolioTone.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkText(
                  runTitle,
                  role: InkTextRole.labelStrong,
                  color: theme.inkPrimary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              WaxSealBadge(label: run.status, status: statusBadge),
            ],
          ),
          const SizedBox(height: 4),
          InkText(
            FolioController.formatMicrosUsd(run.costMicros, showSubCent: true),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
          if (run.status == 'indeterminate_halt') ...[
            const SizedBox(height: 8),
            InkText(
              l10n.t(L10nKey.diagRunIndeterminateHalt),
              role: InkTextRole.captionMeta,
              color: theme.statusErr,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: EngravedButton(
                    label: l10n.t(L10nKey.studioConfirmCompleted),
                    compact: true,
                    onPressed: () => unawaited(
                      controller.resolveIndeterminateRun(
                        run.id,
                        confirmCompleted: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: EngravedButton(
                    label: l10n.t(L10nKey.studioRetryStep),
                    primary: true,
                    compact: true,
                    onPressed: () => unawaited(
                      controller.resolveIndeterminateRun(
                        run.id,
                        confirmCompleted: false,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
