import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/engine_models.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Compact radial conversation-limit gauge (`docs/design/DESIGN.md` §8) that opens a breakdown
/// of what fills the conversation context window.
///
/// [usage] comes from core (`context_usage`): what the next request sends, after any compaction
/// or context pin, so the gauge never counts text the model will not see. Opening the popover
/// asks core again with the composer draft ([loadWithDraft]).
class ContextGaugeRing extends StatefulWidget {
  const ContextGaugeRing({
    super.key,
    required this.usage,
    this.limitTokens,
    this.size = 18,
    this.sessionSpendMicros = 0,
    this.uploadedFilesCount = 0,
    this.loadWithDraft,
    this.onShorten,
    this.onOpenPrices,
    this.showLabel = true,
  });

  /// Narrow windows and large text show only the ring; the numbers stay in its screen-reader
  /// label and the popover.
  final bool showLabel;

  final EngineContextUsage usage;
  final int? limitTokens;
  final double size;

  /// Total recorded session spend for the active chat in micro-USD (`SessionSpend.kt`).
  final int sessionSpendMicros;

  /// Number of files currently attached to the composer (`ContextWindowBreakdownPopover` L1314).
  final int uploadedFilesCount;
  final Future<EngineContextUsage> Function()? loadWithDraft;
  final VoidCallback? onShorten;
  final VoidCallback? onOpenPrices;

  static String compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  @override
  State<ContextGaugeRing> createState() => _ContextGaugeRingState();
}

class _ContextGaugeRingState extends State<ContextGaugeRing> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();
  EngineContextUsage? _withDraft;
  int _loadSeq = 0;
  bool _hovered = false;
  bool _focused = false;

  void _toggle() {
    if (_popover.isShowing) {
      _popover.hide();
      return;
    }
    _withDraft = null;
    _popover.show();
    final load = widget.loadWithDraft;
    if (load == null) return;
    final seq = ++_loadSeq;
    unawaited(
      load().then(
        (usage) {
          if (!mounted || seq != _loadSeq) return;
          setState(() => _withDraft = usage);
        },
        onError: (Object e, StackTrace st) {
          // The popover keeps showing the ring's own numbers (without the draft).
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: e,
              stack: st,
              library: 'context_gauge_ring',
            ),
          );
        },
      ),
    );
  }

  static double _fraction(int used, int? limit) =>
      (limit == null || limit <= 0) ? 0.0 : (used / limit).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final used = widget.usage.totalTokens;
    final limit = widget.limitTokens;
    final fraction = _fraction(used, limit);
    final ringColor = fraction >= 0.9
        ? theme.statusErr
        : fraction >= 0.75
        ? theme.statusWarn
        : theme.accentBrass;
    const compact = ContextGaugeRing.compact;
    final label = limit == null
        ? l10n.t(L10nKey.chatContextGaugeUsed, <String, Object?>{
            'used': compact(used),
          })
        : l10n.t(L10nKey.chatContextGaugeOfLimit, <String, Object?>{
            'used': compact(used),
            'limit': compact(limit),
          });
    final gauge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          // The fill eases to a new value (DESIGN §6: counters ease, never snap).
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: fraction),
            duration: BistreMotion.shouldReduceMotion(context)
                ? Duration.zero
                : BistreMotion.travelling,
            curve: Curves.easeOut,
            builder: (context, value, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _GaugePainter(
                fraction: value,
                track: theme.borderHairline,
                fill: ringColor,
              ),
            ),
          ),
        ),
        if (widget.showLabel) const SizedBox(width: 6),
        if (widget.showLabel)
          InkText(
            limit == null
                ? compact(used)
                : l10n.t(L10nKey.chatContextGaugeShort, <String, Object?>{
                    'used': compact(used),
                    'limit': compact(limit),
                    'percent': (fraction * 100).round(),
                  }),
            role: InkTextRole.captionMeta,
            color: _hovered ? theme.inkSecondary : theme.inkMuted,
          ),
      ],
    );
    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: TapTargetExpander(
          minSize: minTapTarget,
          child: HoverHint(
            message: l10n.t(L10nKey.chatContextOpen),
            child: PressFeedback(
              child: Semantics(
                button: true,
                label: label,
                hint: l10n.t(L10nKey.chatContextOpen),
                excludeSemantics: true,
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
                        _toggle();
                        return null;
                      },
                    ),
                  },
                  mouseCursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggle,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _hovered ? theme.hoverTint : null,
                        borderRadius: BorderRadius.circular(8),
                        border: _focused
                            ? Border.all(color: theme.accentBrass, width: 1.6)
                            : null,
                      ),
                      child: gauge,
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

  Widget _buildPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final usage = _withDraft ?? widget.usage;
    final limit = widget.limitTokens;
    final used = usage.totalTokens;
    final free = limit == null ? 0 : math.max(0, limit - used);
    const compact = ContextGaugeRing.compact;
    final rows = <(L10nKey, Map<String, Object?>, int, Color)>[
      (
        L10nKey.chatContextInstructions,
        const <String, Object?>{},
        usage.systemTokens,
        theme.accentBrass,
      ),
      if (usage.storyTokens > 0)
        (
          L10nKey.chatContextStory,
          const <String, Object?>{},
          usage.storyTokens,
          theme.accentWax,
        ),
      (
        L10nKey.chatContextHistory,
        <String, Object?>{'count': usage.historyTurns},
        usage.historyTokens,
        theme.inkSecondary,
      ),
      if (usage.draftTokens > 0)
        (
          L10nKey.chatContextDraft,
          const <String, Object?>{},
          usage.draftTokens,
          theme.statusOk,
        ),
      if (limit != null)
        (
          L10nKey.chatContextFree,
          const <String, Object?>{},
          free,
          theme.borderHairline,
        ),
    ];
    final barTotal = rows.fold<int>(0, (sum, r) => sum + r.$3);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _popover.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.topEnd.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomEnd.resolve(dir),
          offset: const Offset(0, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 300, maxWidth: 340),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
                borderRadius: 12,
                boxShadow: theme.floatingShadow,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Stacked title + usage/cost subtitle (`ContextWindowBreakdownPopover` L1365-L1377).
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkText(
                          l10n.t(L10nKey.chatContextTitle),
                          role: InkTextRole.labelStrong,
                        ),
                        const SizedBox(height: 2),
                        InkText(
                          l10n.joinMeta(<String>[
                            limit == null
                                ? compact(used)
                                : l10n.t(
                                    L10nKey.chatContextGaugeShort,
                                    <String, Object?>{
                                      'used': compact(used),
                                      'limit': compact(limit),
                                      'percent': (_fraction(used, limit) * 100)
                                          .round(),
                                    },
                                  ),
                            if (widget.sessionSpendMicros > 0)
                              l10n.t(
                                L10nKey.chatContextSessionCost,
                                <String, Object?>{
                                  'cost': FolioController.formatMicrosUsd(
                                    widget.sessionSpendMicros,
                                    showSubCent: true,
                                  ),
                                },
                              ),
                          ]),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
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
                            for (final r in rows)
                              if (r.$3 > 0 && barTotal > 0)
                                Expanded(
                                  flex: math.max(1, r.$3 * 1000 ~/ barTotal),
                                  child: ColoredBox(color: r.$4),
                                ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsetsDirectional.symmetric(
                          vertical: 3,
                        ),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: r.$4,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: InkText(
                                l10n.t(r.$1, r.$2),
                                role: InkTextRole.bodyCompact,
                              ),
                            ),
                            InkText(
                              l10n.t(
                                L10nKey.chatContextTokens,
                                <String, Object?>{'tokens': compact(r.$3)},
                              ),
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                            ),
                          ],
                        ),
                      ),
                    if (widget.uploadedFilesCount > 0)
                      Padding(
                        padding: const EdgeInsetsDirectional.symmetric(
                          vertical: 3,
                        ),
                        child: Row(
                          children: [
                            BistreIcon(
                              BistreUiIcon.paperclip,
                              size: 11,
                              color: theme.accentBrass,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: InkText(
                                l10n.t(
                                  L10nKey.chatContextFiles,
                                  <String, Object?>{
                                    'count': widget.uploadedFilesCount,
                                  },
                                ),
                                role: InkTextRole.bodyCompact,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.t(L10nKey.chatContextEstimateHint),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                    if (widget.onShorten != null ||
                        widget.onOpenPrices != null) ...[
                      const SizedBox(height: BistreSpacing.s8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (widget.onShorten != null &&
                              usage.historyTurns > 2)
                            EngravedButton(
                              label: l10n.t(L10nKey.chatCompactAction),
                              compact: true,
                              onPressed: () {
                                _popover.hide();
                                widget.onShorten!();
                              },
                            ),
                          if (widget.onOpenPrices != null)
                            EngravedButton(
                              label: l10n.t(L10nKey.chatContextPrices),
                              compact: true,
                              onPressed: () {
                                _popover.hide();
                                widget.onOpenPrices!();
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(arcRect, 0, math.pi * 2, false, trackPaint);
    if (fraction > 0) {
      final fillPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = fill;
      canvas.drawArc(
        arcRect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}
