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
import 'chat_files_tab.dart';

/// Multi-tab right-hand Studio Pane (`328px` wide, hidden by default) hosting:
/// - `[Runs]`: OS Sleep & Disruption Guard, active/recent SQLite-journaled runs, `INDETERMINATE_HALT`
///   reconciliation, and mid-stream steering queue.
/// - `[Files]`: the chat's files, sent, made, and edited (`chat_files_tab.dart`).
/// - `[Story]` & `[Prompt]`: Story Bible & Live Prompt Inspector tabs.
/// - `[Sources]`: web pages the chat's replies used, parsed in core.
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
        (StudioTab.sources, L10nKey.studioTabSources, BistreUiIcon.globe),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
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
                  const SizedBox(width: 4),
                  BistreIconButton(
                    icon: BistreUiIcon.close,
                    size: 14,
                    dimension: 28,
                    semanticsLabel: l10n.t(L10nKey.shellClose),
                    onPressed: controller.toggleStudioPane,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
              // Every tab stays in view: the row wraps instead of clipping.
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final tab in _tabs)
                    InkChip(
                      label: l10n.t(tab.$2),
                      selected: activeTab == tab.$1,
                      onSelected: () => controller.setStudioTab(tab.$1),
                    ),
                ],
              ),
            ),
            const FolioDivider(),
            Expanded(
              child: switch (activeTab) {
                StudioTab.runs => _RunsTabBody(controller: controller),
                StudioTab.files => ChatFilesTab(controller: controller),
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
                StudioTab.sources => _SourcesTabBody(controller: controller),
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
                        semanticsLabel: l10n.t(L10nKey.shellRemove),
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

/// The web pages the open chat's replies used, newest reply last.
class _SourcesTabBody extends StatelessWidget {
  const _SourcesTabBody({required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final sources = controller.threadGrounding;
    if (sources.isEmpty) {
      return const _StoryPlaceholderBody(
        titleKey: L10nKey.studioTabSources,
        bodyKey: L10nKey.studioSourcesEmpty,
      );
    }
    return SmoothScrollable(
      builder: (_, scroll) => ListView.builder(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(12),
        itemCount: sources.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsetsDirectional.only(bottom: BistreSpacing.s8),
          child: GroundingSourceRow(
            source: sources[index],
            onCopyLink: () =>
                unawaited(controller.copyText(sources[index].url)),
          ),
        ),
      ),
    );
  }
}

/// One source: title, site, the cited passage, and Copy link.
class GroundingSourceRow extends StatelessWidget {
  const GroundingSourceRow({
    super.key,
    required this.source,
    required this.onCopyLink,
  });

  final EngineGroundingSource source;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final cited = source.citedText;
    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 8,
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 2),
            child: BistreIcon(
              BistreUiIcon.globe,
              size: 13,
              color: theme.accentBrass,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkText(
                  source.title.isEmpty ? source.url : source.title,
                  role: InkTextRole.labelStrong,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                InkText(
                  source.host,
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (cited != null && cited.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  InkText(
                    cited,
                    role: InkTextRole.bodyCompact,
                    color: theme.inkSecondary,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          BistreIconButton(
            icon: BistreUiIcon.copy,
            size: 13,
            dimension: 28,
            semanticsLabel: l10n.t(L10nKey.chatActionCopy),
            onPressed: onCopyLink,
          ),
        ],
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
              if (isAwake)
                WaxSealBadge(label: l10n.t(L10nKey.studioAwakeBadge)),
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

  static L10nKey? _modeKey(String mode) => switch (mode) {
    'chat' => L10nKey.modeChat,
    'code' => L10nKey.modeCode,
    'plan' => L10nKey.modePlan,
    'write' => L10nKey.modeWrite,
    'translate' => L10nKey.modeTranslate,
    _ => null,
  };

  static L10nKey _statusKey(String status) => switch (status) {
    'running' => L10nKey.studioRunStatusRunning,
    'waiting_approval' => L10nKey.studioRunStatusWaitingApproval,
    'backoff_wait' => L10nKey.studioRunStatusBackoffWait,
    'sleep_paused' => L10nKey.studioRunStatusSleepPaused,
    'indeterminate_halt' => L10nKey.studioRunStatusIndeterminateHalt,
    'completed' => L10nKey.studioRunStatusCompleted,
    'cancelled' => L10nKey.studioRunStatusCancelled,
    _ => L10nKey.studioRunStatusFailed,
  };

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    // A run at work is the normal state: calm, not a warning.
    final statusBadge = switch (run.status) {
      'running' => WaxSealStatus.neutral,
      'waiting_approval' || 'backoff_wait' => WaxSealStatus.warn,
      'completed' => WaxSealStatus.ok,
      'indeterminate_halt' || 'failed' => WaxSealStatus.error,
      _ => WaxSealStatus.neutral,
    };

    final thread = controller.threads
        .where((t) => t.id == run.threadId)
        .firstOrNull;
    final runTitle = thread == null || thread.title.trim().isEmpty
        ? l10n.t(L10nKey.shellThreadDefaultTitle)
        : thread.title;
    final modeKey = _modeKey(run.mode);
    final meta = l10n.joinMeta(<String>[
      if (modeKey != null) l10n.t(modeKey),
      l10n.t(L10nKey.studioRunStep, <String, Object?>{
        'step': run.stepIndex + 1,
      }),
      FolioController.formatMicrosUsd(run.costMicros, showSubCent: true),
    ]);
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
              WaxSealBadge(
                label: l10n.t(_statusKey(run.status)),
                status: statusBadge,
              ),
            ],
          ),
          const SizedBox(height: 4),
          InkText(meta, role: InkTextRole.captionMeta, color: theme.inkMuted),
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
