import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

String _tokens(BistreLocalizationController l10n, int tokens) =>
    l10n.t(L10nKey.chatContextTokens, <String, Object?>{'tokens': tokens});

/// A block's title in words. Core's block ids are stable (`prompt_assembler.rs`); its labels
/// are written for the model, so only the name after "·" in a named block is shown.
String promptBlockTitle(
  BistreLocalizationController l10n,
  EnginePromptBlock b,
) {
  final cut = b.label.lastIndexOf(' · ');
  final name = l10n.isolate(cut < 0 ? b.label : b.label.substring(cut + 3));
  final id = b.id;
  if (id.startsWith('char_')) {
    return l10n.t(L10nKey.storyBlockCharacter, <String, Object?>{'name': name});
  }
  if (id.startsWith('lore_')) {
    return l10n.t(L10nKey.storyBlockLore, <String, Object?>{'name': name});
  }
  return switch (id) {
    'system_base' => l10n.t(L10nKey.storyBlockSystem),
    'user_persona' => l10n.t(L10nKey.storyBlockPersona, <String, Object?>{
      'name': name,
    }),
    'story_memory' => l10n.t(L10nKey.storyBlockMemory),
    'era_summaries' => l10n.t(L10nKey.storyBlockEras),
    'author_note' => l10n.t(L10nKey.storyBlockAuthorNote),
    'scene_beats' => l10n.t(L10nKey.storyBlockSceneBeats),
    _ => name,
  };
}

/// Why a lore entry was or was not added, in words (core's codes, `lorebook.rs`).
String loreReason(BistreLocalizationController l10n, String code) {
  if (code.startsWith('recursive_depth_')) {
    return l10n.t(L10nKey.storyLoreReasonRecursive);
  }
  return switch (code) {
    'constant' => l10n.t(L10nKey.storyLoreReasonConstant),
    'sticky' => l10n.t(L10nKey.storyLoreReasonSticky),
    'keyword_match' => l10n.t(L10nKey.storyLoreReasonKeyword),
    'budget_exceeded' => l10n.t(L10nKey.storyLoreReasonBudget),
    _ => l10n.t(L10nKey.storyLoreReasonNotTriggered),
  };
}

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
                  semanticsLabel: l10n.t(L10nKey.settingsStorageRefreshFiles),
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
                    l10n.t(L10nKey.storyInspectorMeter, <String, Object?>{
                      'total': report.totalEstimatedTokens,
                      'reused': report.staticPrefixTokens,
                    }),
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

            // --- Exact credential-free outbound request from core ---
            const SizedBox(height: 12),
            _RealRequestCard(controller: controller),

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
                  l10n.t(L10nKey.storyInspectorLoreBudget, <String, Object?>{
                    'used': report.loreTokensUsed,
                    'limit': report.loreTokenBudgetCap,
                  }),
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
                  l10n.t(L10nKey.storyInspectorLoreEmpty),
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
                              loreReason(l10n, item.reason),
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
                        _tokens(l10n, item.estimatedTokens),
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
        Expanded(child: Container(height: 1, color: theme.borderHairline)),
        Flexible(
          flex: 6,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 6),
            child: InkText(
              label,
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Expanded(child: Container(height: 1, color: theme.borderHairline)),
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
    final l10n = BistreLocalizations.of(context);
    final b = widget.block;

    return PressFeedback(
      pressScale: kRowPressScale,
      hoverScale: 1,
      child: GestureDetector(
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
                      promptBlockTitle(l10n, b),
                      role: InkTextRole.labelStrong,
                      color: theme.inkPrimary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkText(
                    _tokens(l10n, b.estimatedTokens),
                    role: InkTextRole.captionMeta,
                    color: b.isStaticPrefix
                        ? theme.statusOk
                        : theme.accentBrass,
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
      ),
    );
  }
}

class _RealRequestCard extends StatefulWidget {
  const _RealRequestCard({required this.controller});

  final FolioController controller;

  @override
  State<_RealRequestCard> createState() => _RealRequestCardState();
}

class _RealRequestCardState extends State<_RealRequestCard> {
  bool _open = false;

  static String _requestLine(EngineInspectedRequest req) =>
      '${req.method} ${req.url}';

  static String _headerLine((String, String) h) => '${h.$1}: ${h.$2}';

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final req = widget.controller.inspectedRequest;
    final errKey = widget.controller.inspectedRequestError;
    if (req == null && errKey == null) return const SizedBox.shrink();

    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 10,
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: PressableArea(
                  label: l10n.t(L10nKey.storyInspectorRealRequest),
                  onPressed: () => setState(() => _open = !_open),
                  child: Row(
                    children: [
                      BistreIcon(
                        _open
                            ? BistreUiIcon.chevronDown
                            : BistreUiIcon.chevronEnd,
                        size: 12,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.storyInspectorRealRequest),
                          role: InkTextRole.labelStrong,
                          color: errKey != null
                              ? theme.statusErr
                              : theme.inkPrimary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (req != null)
                BistreIconButton(
                  icon: BistreUiIcon.copy,
                  size: 12,
                  dimension: 24,
                  semanticsLabel: l10n.t(L10nKey.chatActionCopy),
                  onPressed: () =>
                      unawaited(widget.controller.copyText(req.bodyJson)),
                ),
            ],
          ),
          if (errKey != null) ...[
            const SizedBox(height: 6),
            InkText(
              l10n.tRawKey(errKey),
              role: InkTextRole.captionMeta,
              color: theme.statusErr,
            ),
          ] else if (req != null)
            DisclosureReveal(
              open: _open,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkText(
                      _requestLine(req),
                      role: InkTextRole.codeBlock,
                      color: theme.accentBrass,
                    ),
                    for (final h in req.headers)
                      InkText(
                        _headerLine(h),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    const SizedBox(height: 6),
                    InkText(
                      req.bodyJson,
                      role: InkTextRole.codeBlock,
                      color: theme.inkSecondary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
