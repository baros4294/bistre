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
import '../../design/popover_placement.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'context_breakdown_popover.dart';

/// Compact radial conversation-limit gauge (`docs/design/design.md` §8) that opens a breakdown
/// of what fills the conversation context window.
///
/// [usage] comes from core (`context_breakdown`): what the next request sends, after any
/// compaction or context pin, so the gauge never counts text the model will not see. Opening
/// the breakdown asks core again with the composer draft ([loadWithDraft]).
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
    this.overLimit = false,
  });

  /// The provider said this chat is over its limit: the ring is full and red whatever the
  /// local count says, so the ring and the error notice agree.
  final bool overLimit;

  /// Narrow windows and large text show only the ring; the numbers stay in its screen-reader
  /// label and the popover.
  final bool showLabel;

  final EngineContextBreakdown usage;
  final int? limitTokens;
  final double size;

  /// Total recorded session spend for the active chat in micro-USD (`SessionSpend.kt`).
  final int sessionSpendMicros;

  /// Number of files currently attached to the composer.
  final int uploadedFilesCount;
  final Future<EngineContextBreakdown> Function()? loadWithDraft;
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
  EngineContextBreakdown? _withDraft;
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
    final used = widget.usage.totalSent;
    final limit = widget.usage.limitTokens ?? widget.limitTokens;
    final fraction = widget.overLimit ? 1.0 : _fraction(used, limit);
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
                    'percent': contextPercent(used, limit),
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
    final dir = Directionality.of(context);
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
          // Moved back inside the window on a narrow screen (never off its edge).
          offset: Offset(
            PopoverPlacement.popoverShiftFor(
              this.context,
              width: PopoverPlacement.popoverWidthFor(context, 360),
              alignStart: false,
            ),
            -8,
          ),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: PopoverPlacement.popoverWidthFor(context, 300),
                maxWidth: PopoverPlacement.popoverWidthFor(context, 360),
              ),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
                borderRadius: 12,
                boxShadow: theme.floatingShadow,
                child: ContextBreakdownPanel(
                  breakdown: _withDraft ?? widget.usage,
                  limitTokens: widget.limitTokens,
                  sessionSpendMicros: widget.sessionSpendMicros,
                  uploadedFilesCount: widget.uploadedFilesCount,
                  onClose: _popover.hide,
                  onShorten: widget.onShorten,
                  onOpenPrices: widget.onOpenPrices,
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
