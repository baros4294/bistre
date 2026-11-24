import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

String _formatTokenCount(int tokens) => '$tokens tok';
String _formatPromptMeter(EnginePromptReport report) =>
    '${report.staticPrefixTokens} cached + ${report.totalEstimatedTokens - report.staticPrefixTokens} dynamic = ${report.totalEstimatedTokens} tok';
String _formatLoreBudget(EnginePromptReport report) =>
    '${report.loreTokensUsed} / ${report.loreTokenBudgetCap} tok';

/// Live Prompt & Lorebook V3 Activation Inspector mounted inside Studio Pane `[Prompt]` tab.
/// Visualizes the exact compiled outbound prompt order, highlights the Prompt Cache Prefix
/// Boundary, and logs every Lorebook entry's trigger or skip reason cleanly.
class PromptInspectorPanel extends StatelessWidget {
  const PromptInspectorPanel({super.key, required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final report = controller.promptReport;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BistreIcon(
                  BistreUiIcon.eye,
                  size: 14,
                  color: theme.accentBrass,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkText(
                    l10n.t(L10nKey.storyInspectorTitle),
                    role: InkTextRole.labelStrong,
                    color: theme.inkPrimary,
                  ),
                ),
                BistreIconButton(
                  icon: BistreUiIcon.refresh,
                  size: 13,
                  dimension: 26,
                  semanticsLabel: l10n.t(L10nKey.storyInspectorTitle),
                  onPressed: () =>
                      unawaited(controller.refreshPromptInspector()),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkText(
                    _formatPromptMeter(report),
                    role: InkTextRole.captionMeta,
                    color: theme.inkPrimary,
                  ),
                  const SizedBox(height: 6),
                  _TokenRatioBar(
                    staticTokens: report.staticPrefixTokens,
                    totalTokens: report.totalEstimatedTokens,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // --- Compiled Prompt Stack with explicit Prompt Cache Prefix Boundary ---
            for (var i = 0; i < report.blocks.length; i++) ...[
              if (i == report.cacheBoundaryIndex) ...[
                _CacheBoundaryDivider(
                  label: l10n.t(L10nKey.storyInspectorCacheBoundary),
                ),
                const SizedBox(height: 8),
              ],
              _PromptBlockCard(block: report.blocks[i]),
              const SizedBox(height: 6),
            ],
            if (report.blocks.isNotEmpty &&
                report.cacheBoundaryIndex >= report.blocks.length) ...[
              _CacheBoundaryDivider(
                label: l10n.t(L10nKey.storyInspectorCacheBoundary),
              ),
              const SizedBox(height: 8),
            ],

            // --- Lorebook V3 Activation & Skip Trace ---
            const SizedBox(height: 8),
            Row(
              children: [
                BistreIcon(
                  BistreUiIcon.bookOpen,
                  size: 14,
                  color: theme.accentBrass,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkText(
                    l10n.t(L10nKey.storyInspectorLoreTrace),
                    role: InkTextRole.labelStrong,
                    color: theme.inkPrimary,
                  ),
                ),
                InkText(
                  _formatLoreBudget(report),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (report.loreTrace.isEmpty)
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: InkText(
                  l10n.t(L10nKey.storyCodexTitle),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                ),
              )
            else
              for (final item in report.loreTrace) ...[
                FolioSurface(
                  tone: FolioTone.elevated,
                  borderRadius: 10,
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      BistreIcon(
                        item.fired ? BistreUiIcon.check : BistreUiIcon.close,
                        size: 12,
                        color: item.fired ? theme.statusOk : theme.inkMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkText(
                              item.name,
                              role: InkTextRole.labelStrong,
                              color: theme.inkPrimary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            InkText(
                              item.reason,
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkText(
                        _formatTokenCount(item.estimatedTokens),
                        role: InkTextRole.captionMeta,
                        color: theme.inkSecondary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
          ],
        ),
      ),
    );
  }
}

class _TokenRatioBar extends StatelessWidget {
  const _TokenRatioBar({required this.staticTokens, required this.totalTokens});

  final int staticTokens;
  final int totalTokens;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final ratio = totalTokens > 0
        ? (staticTokens / totalTokens).clamp(0.0, 1.0)
        : 0.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child: ColoredBox(
          color: theme.borderHairline,
          child: FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: ratio,
            child: ColoredBox(color: theme.statusOk),
          ),
        ),
      ),
    );
  }
}

class _CacheBoundaryDivider extends StatelessWidget {
  const _CacheBoundaryDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: theme.accentBrass)),
        Flexible(
          flex: 6,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 6),
            child: WaxSealBadge(label: label, status: WaxSealStatus.warn),
          ),
        ),
        Expanded(child: Container(height: 1, color: theme.accentBrass)),
      ],
    );
  }
}

class _PromptBlockCard extends StatefulWidget {
  const _PromptBlockCard({required this.block});

  final EnginePromptBlock block;

  @override
  State<_PromptBlockCard> createState() => _PromptBlockCardState();
}

class _PromptBlockCardState extends State<_PromptBlockCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final b = widget.block;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: FolioSurface(
        tone: FolioTone.elevated,
        borderRadius: 10,
        padding: const EdgeInsetsDirectional.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BistreIcon(
                  _expanded
                      ? BistreUiIcon.chevronDown
                      : BistreUiIcon.chevronEnd,
                  size: 12,
                  color: theme.inkMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkText(
                    b.label,
                    role: InkTextRole.labelStrong,
                    color: theme.inkPrimary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                InkText(
                  _formatTokenCount(b.estimatedTokens),
                  role: InkTextRole.captionMeta,
                  color: b.isStaticPrefix ? theme.statusOk : theme.accentBrass,
                ),
              ],
            ),
            DisclosureReveal(
              open: _expanded,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(top: 6),
                child: InkText(
                  b.content,
                  role: InkTextRole.captionMeta,
                  color: theme.inkSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
