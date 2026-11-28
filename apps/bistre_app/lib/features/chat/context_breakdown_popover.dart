import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/engine_models.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Whole percent, the same on the ring and in this panel (40 for 39.8). A share that is
/// not empty never reads 0, and one that is not full never reads 100.
String contextPercent(int tokens, int limit) {
  if (tokens <= 0 || limit <= 0) return '0';
  if (tokens >= limit) return '${(tokens * 100 / limit).round()}';
  final pct = (tokens * 100 / limit).round();
  if (pct < 1) return '<1';
  return '${pct > 99 ? 99 : pct}';
}

/// The context window breakdown (DESIGN §8): what fills the next request, row by row,
/// with each share of the window, the reserve kept free for shortening, and free space; then
/// what is not sent (MCP schemas loaded on demand). The MCP row opens a second page listing
/// each server's tools. Esc goes back a page, then closes. Core owns every number.
class ContextBreakdownPanel extends StatefulWidget {
  const ContextBreakdownPanel({
    super.key,
    required this.breakdown,
    required this.limitTokens,
    required this.sessionSpendMicros,
    required this.uploadedFilesCount,
    required this.onClose,
    this.onShorten,
    this.onOpenPrices,
  });

  final EngineContextBreakdown breakdown;
  final int? limitTokens;
  final int sessionSpendMicros;
  final int uploadedFilesCount;
  final VoidCallback onClose;
  final VoidCallback? onShorten;
  final VoidCallback? onOpenPrices;

  @override
  State<ContextBreakdownPanel> createState() => _ContextBreakdownPanelState();
}

class _ContextBreakdownPanelState extends State<ContextBreakdownPanel> {
  bool _mcpPage = false;

  /// Holds focus inside the popover so Esc reaches this panel first (back a page, then the
  /// overlay closes).
  final FocusNode _focus = FocusNode(debugLabel: 'context-breakdown');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _setPage(bool mcp) {
    setState(() => _mcpPage = mcp);
    _focus.requestFocus();
  }

  static String compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  L10nKey _labelFor(String kind) => switch (kind) {
    'messages' => L10nKey.chatContextCatMessages,
    'built_in_tools' => L10nKey.chatContextCatBuiltInTools,
    'mcp_tools' => L10nKey.chatContextCatMcpTools,
    'system_prompt' => L10nKey.chatContextCatSystemPrompt,
    'project_instructions' => L10nKey.chatContextCatProjectInstructions,
    'workspace_instructions' => L10nKey.chatContextCatWorkspaceInstructions,
    'story' => L10nKey.chatContextCatStory,
    'attachments' => L10nKey.chatContextCatAttachments,
    'draft' => L10nKey.chatContextCatDraft,
    'deferred_mcp_tools' => L10nKey.chatContextCatDeferredMcpTools,
    _ => L10nKey.chatContextCatOther,
  };

  Color _colorFor(BistreThemeData theme, String kind) => switch (kind) {
    'messages' => theme.inkSecondary,
    'built_in_tools' => theme.statusWarn,
    'mcp_tools' => theme.statusWarn.withValues(alpha: 0.6),
    'system_prompt' => theme.accentBrass,
    'project_instructions' => theme.accentBrass.withValues(alpha: 0.8),
    'workspace_instructions' => theme.accentBrass.withValues(alpha: 0.6),
    'story' => theme.accentWax,
    'attachments' => theme.accentWax.withValues(alpha: 0.75),
    'draft' => theme.statusOk,
    _ => theme.inkMuted,
  };

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _mcpPage) {
      _setPage(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = BistreMotion.shouldReduceMotion(context);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: AnimatedSwitcher(
        duration: reduce ? Duration.zero : BistreMotion.arriving,
        child: _mcpPage
            ? KeyedSubtree(key: const ValueKey('mcp'), child: _buildMcpPage())
            : KeyedSubtree(key: const ValueKey('main'), child: _buildMain()),
      ),
    );
  }

  Widget _buildMain() {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final b = widget.breakdown;
    final limit = b.limitTokens ?? widget.limitTokens;
    final used = b.totalSent;
    final sent = b.categories.where((c) => c.sent && c.tokens > 0).toList();
    final notSent = b.categories.where((c) => !c.sent && c.tokens > 0).toList();
    final reserve = limit == null ? 0 : math.min(b.reserveTokens, limit);
    final free = limit == null ? 0 : math.max(0, limit - used - reserve);
    final bar = <(int, Color)>[
      for (final c in sent) (c.tokens, _colorFor(theme, c.kind)),
      if (reserve > 0) (reserve, theme.borderHairline.withValues(alpha: 0.9)),
      if (free > 0) (free, theme.borderHairline),
    ];
    final barTotal = bar.fold<int>(0, (sum, r) => sum + r.$1);
    String pct(int tokens) => limit == null || limit <= 0
        ? l10n.t(L10nKey.chatContextNoPercent)
        : l10n.t(L10nKey.chatContextPercent, <String, Object?>{
            'percent': contextPercent(tokens, limit),
          });

    Widget row(
      String label,
      int tokens,
      Color dot, {
      String? percent,
      VoidCallback? onTap,
    }) {
      final pctText = percent ?? pct(tokens);
      final tokensText = l10n.t(L10nKey.chatContextTokens, <String, Object?>{
        'tokens': compact(tokens),
      });
      final content = Padding(
        padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dot,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: InkText(label, role: InkTextRole.bodyCompact)),
            InkText(
              tokensText,
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 46,
              child: InkText(
                pctText,
                role: InkTextRole.captionMeta,
                color: theme.inkSecondary,
                textAlign: TextAlign.end,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              BistreIcon(
                BistreUiIcon.chevronEnd,
                size: 11,
                color: theme.inkMuted,
              ),
            ],
          ],
        ),
      );
      return MergeSemantics(
        child: Semantics(
          label: l10n.t(L10nKey.chatContextRowSemantics, <String, Object?>{
            'label': label,
            'tokens': tokensText,
            'percent': pctText,
          }),
          button: onTap != null,
          child: ExcludeSemantics(
            child: onTap == null
                ? content
                : FocusableActionDetector(
                    mouseCursor: SystemMouseCursors.click,
                    actions: <Type, Action<Intent>>{
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) {
                          onTap();
                          return null;
                        },
                      ),
                    },
                    child: PressFeedback(
                      pressScale: kRowPressScale,
                      hoverScale: 1,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTap,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 40),
                          child: content,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: InkText(
                l10n.t(L10nKey.chatContextTitle),
                role: InkTextRole.labelStrong,
              ),
            ),
            if (limit != null && limit > 0)
              InkText(
                l10n.t(L10nKey.chatContextPercentUsed, <String, Object?>{
                  'percent': contextPercent(used, limit),
                }),
                role: InkTextRole.labelStrong,
                color: theme.accentBrass,
              ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final r in bar)
                  if (r.$1 > 0 && barTotal > 0)
                    Expanded(
                      flex: math.max(1, r.$1 * 1000 ~/ barTotal),
                      child: ColoredBox(color: r.$2),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        InkText(
          limit == null
              ? l10n.t(L10nKey.chatContextTokens, <String, Object?>{
                  'tokens': compact(used),
                })
              : l10n.t(L10nKey.chatContextGaugeOfLimit, <String, Object?>{
                  'used': compact(used),
                  'limit': compact(limit),
                }),
          role: InkTextRole.captionMeta,
          color: theme.inkMuted,
        ),
        const SizedBox(height: BistreSpacing.s8),
        for (final c in sent)
          row(
            l10n.t(_labelFor(c.kind), <String, Object?>{'count': c.count ?? 0}),
            c.tokens,
            _colorFor(theme, c.kind),
            onTap: c.kind == 'mcp_tools' && b.mcp.isNotEmpty
                ? () => _setPage(true)
                : null,
          ),
        if (reserve > 0)
          row(
            l10n.t(L10nKey.chatContextCatReserve),
            reserve,
            theme.borderHairline.withValues(alpha: 0.9),
          ),
        if (limit != null)
          row(l10n.t(L10nKey.chatContextCatFree), free, theme.borderHairline),
        if (notSent.isNotEmpty) ...[
          const SizedBox(height: 6),
          const FolioDivider(),
          const SizedBox(height: 6),
          InkText(
            l10n.t(L10nKey.chatContextNotSent),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
          for (final c in notSent)
            row(
              l10n.t(_labelFor(c.kind), <String, Object?>{
                'count': c.count ?? 0,
              }),
              c.tokens,
              theme.inkMuted,
              percent: l10n.t(L10nKey.chatContextNoPercent),
              onTap: b.mcp.isNotEmpty ? () => _setPage(true) : null,
            ),
        ],
        if (widget.uploadedFilesCount > 0)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(vertical: 3),
            child: InkText(
              l10n.t(L10nKey.chatContextFiles, <String, Object?>{
                'count': widget.uploadedFilesCount,
              }),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
          ),
        const SizedBox(height: BistreSpacing.s8),
        InkText(
          l10n.joinMeta(<String>[
            if (widget.sessionSpendMicros > 0)
              l10n.t(L10nKey.chatContextSessionCost, <String, Object?>{
                'cost': FolioController.formatMicrosUsd(
                  widget.sessionSpendMicros,
                  showSubCent: true,
                ),
              }),
            l10n.t(L10nKey.chatContextEstimateHint),
          ]),
          role: InkTextRole.captionMeta,
          color: theme.inkMuted,
        ),
        if (widget.onShorten != null || widget.onOpenPrices != null) ...[
          const SizedBox(height: BistreSpacing.s8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (widget.onShorten != null && (b.countOf('messages') ?? 0) > 2)
                EngravedButton(
                  label: l10n.t(L10nKey.chatCompactAction),
                  compact: true,
                  onPressed: () {
                    widget.onClose();
                    widget.onShorten!();
                  },
                ),
              if (widget.onOpenPrices != null)
                EngravedButton(
                  label: l10n.t(L10nKey.chatContextPrices),
                  compact: true,
                  onPressed: () {
                    widget.onClose();
                    widget.onOpenPrices!();
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMcpPage() {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.chatContextBack),
              compact: true,
              leading: BistreIcon(
                BistreUiIcon.chevronStart,
                size: 11,
                color: theme.inkSecondary,
              ),
              onPressed: () => _setPage(false),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkText(
                l10n.t(L10nKey.chatContextMcpPageTitle),
                role: InkTextRole.labelStrong,
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final srv in widget.breakdown.mcp) ...[
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkText(
                            srv.label,
                            role: InkTextRole.labelStrong,
                          ),
                        ),
                        InkText(
                          l10n.t(L10nKey.chatContextTokens, <String, Object?>{
                            'tokens': compact(srv.tokens),
                          }),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                      ],
                    ),
                  ),
                  for (final tool in srv.tools)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        3,
                        0,
                        3,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkText(
                              tool.deferred
                                  ? l10n.t(
                                      L10nKey.chatContextToolOnDemand,
                                      <String, Object?>{'name': tool.name},
                                    )
                                  : tool.name,
                              role: InkTextRole.bodyCompact,
                              color: tool.deferred
                                  ? theme.inkMuted
                                  : theme.inkPrimary,
                            ),
                          ),
                          InkText(
                            l10n.t(L10nKey.chatContextTokens, <String, Object?>{
                              'tokens': compact(tool.tokens),
                            }),
                            role: InkTextRole.captionMeta,
                            color: theme.inkMuted,
                          ),
                        ],
                      ),
                    ),
                ],
                if (widget.breakdown.mcpTruncated)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: InkText(
                      l10n.t(L10nKey.chatContextMcpTruncated),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
