import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Interactive per-turn token, timing, and cost summary pill.
/// Shows the compact meta summary at rest, a hover hint on pointer rest, and opens a
/// focusable breakdown card on tap/Enter/Space with model, input/output tokens, speed, and cost.
class UsageDetailsPill extends StatefulWidget {
  const UsageDetailsPill({
    super.key,
    required this.usage,
    required this.summaryText,
    this.spokenLabel,
    this.reduceMotionOverride = false,
  });

  final NodeUsageMeta usage;
  final String summaryText;

  /// The line in words for screen readers (the visible line uses arrows).
  final String? spokenLabel;
  final bool reduceMotionOverride;

  @override
  State<UsageDetailsPill> createState() => _UsageDetailsPillState();
}

class _UsageDetailsPillState extends State<UsageDetailsPill> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();
  bool _hovered = false;
  bool _focused = false;

  /// Hover opens the breakdown after a short rest; a click or Enter pins it open.
  static const Duration _hoverDelay = Duration(milliseconds: 500);
  Timer? _hoverTimer;
  bool _pinned = false;
  bool _openedByHover = false;

  void _onHover(bool inside) {
    _hoverTimer?.cancel();
    if (inside) {
      if (_popover.isShowing) return;
      _hoverTimer = Timer(_hoverDelay, () {
        if (!mounted || _popover.isShowing) return;
        _openedByHover = true;
        _popover.show();
        setState(() {});
      });
    } else if (_openedByHover && !_pinned) {
      _hoverTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted || _pinned) return;
        _openedByHover = false;
        _popover.hide();
        setState(() {});
      });
    }
  }

  void _toggle() {
    _hoverTimer?.cancel();
    if (_popover.isShowing && (_pinned || !_openedByHover)) {
      _pinned = false;
      _openedByHover = false;
      _popover.hide();
    } else {
      _pinned = true;
      _openedByHover = false;
      _popover.show();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final hint = l10n.t(L10nKey.chatUsageDetailsHint);

    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) => _onHover(true),
          onExit: (_) => _onHover(false),
          child: PressFeedback(
            pressScale: kRowPressScale,
            hoverScale: 1,
            child: Semantics(
              button: true,
              label: widget.spokenLabel ?? widget.summaryText,
              hint: hint,
              child: FocusableActionDetector(
                mouseCursor: SystemMouseCursors.click,
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _hovered || _popover.isShowing
                          ? theme.hoverTint
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      border: _focused
                          ? Border.all(color: theme.accentBrass, width: 1.5)
                          : null,
                    ),
                    child: InkText(
                      widget.summaryText,
                      role: InkTextRole.captionMeta,
                      color: _hovered || _popover.isShowing
                          ? theme.accentBrass
                          : theme.inkMuted,
                      // Wraps rather than hiding the cost at large text.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
    final u = widget.usage;

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
          targetAnchor: AlignmentDirectional.topStart.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          offset: const Offset(0, -6),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.05),
            reduceMotionOverride: widget.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
                borderRadius: 10,
                boxShadow: theme.floatingShadow,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkText(
                            u.modelId.isNotEmpty
                                ? u.modelId
                                : l10n.t(L10nKey.shellRoleAssistant),
                            role: InkTextRole.labelStrong,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        BistreIconButton(
                          icon: BistreUiIcon.close,
                          size: 11,
                          dimension: 22,
                          semanticsLabel: l10n.t(L10nKey.threadCancel),
                          onPressed: _popover.hide,
                        ),
                      ],
                    ),
                    if (u.providerName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      InkText(
                        u.providerName,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    const FolioDivider(),
                    const SizedBox(height: 6),
                    UsageBreakdownRows(usage: u),
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: InkText(
            label,
            role: InkTextRole.captionMeta,
            color: theme.inkSecondary,
          ),
        ),
        InkText(
          value,
          role: InkTextRole.captionMeta,
          color: accent ? theme.accentBrass : theme.inkPrimary,
        ),
      ],
    );
  }
}

/// The reply's usage in plain rows: sent, reused and saved cache, thinking, received, time to
/// first word, total time, speed, and cost. Shared by the usage popover and Turn details.
class UsageBreakdownRows extends StatelessWidget {
  const UsageBreakdownRows({super.key, required this.usage});

  final NodeUsageMeta usage;

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final u = usage;
    final costValue = u.costKnown
        ? FolioController.formatMicrosUsd(u.costMicros, showSubCent: true)
        : l10n.t(L10nKey.chatCostUnavailableTitle);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (u.hasTokens) ...[
          _DetailRow(
            label: l10n.t(L10nKey.chatUsageInputTokens),
            value: '${u.inputTokens}',
          ),
          if (u.cachedInputTokens > 0) ...[
            const SizedBox(height: 3),
            _DetailRow(
              label: l10n.t(L10nKey.chatUsageCachedTokens),
              value: '${u.cachedInputTokens}',
            ),
          ],
          if (u.cacheCreationInputTokens > 0) ...[
            const SizedBox(height: 3),
            _DetailRow(
              label: l10n.t(L10nKey.chatUsageCacheWriteTokens),
              value: '${u.cacheCreationInputTokens}',
            ),
          ],
          if (u.reasoningTokens > 0) ...[
            const SizedBox(height: 3),
            _DetailRow(
              label: l10n.t(L10nKey.chatUsageReasoningTokens),
              value: '${u.reasoningTokens}',
            ),
          ],
          const SizedBox(height: 3),
          _DetailRow(
            label: l10n.t(L10nKey.chatUsageOutputTokens),
            value: '${u.outputTokens}',
          ),
          const SizedBox(height: 3),
        ],
        if (u.firstTokenMs > 0) ...[
          _DetailRow(
            label: l10n.t(L10nKey.chatUsageTtftLabel),
            value: '${(u.firstTokenMs / 1000.0).toStringAsFixed(2)}s',
          ),
          const SizedBox(height: 3),
        ],
        if (u.elapsedMs > 0) ...[
          _DetailRow(
            label: l10n.t(L10nKey.chatUsageDurationLabel),
            value: '${(u.elapsedMs / 1000.0).toStringAsFixed(1)}s',
          ),
          const SizedBox(height: 3),
        ],
        if (u.tokensPerSecond case final tps?) ...[
          _DetailRow(
            label: l10n.t(L10nKey.chatUsageSpeedLabel),
            value: '${tps.toStringAsFixed(1)} tok/s',
          ),
          const SizedBox(height: 3),
        ],
        _DetailRow(
          label: l10n.t(L10nKey.chatUsageCostLabel),
          value: costValue,
          accent: u.costKnown && u.costMicros > 0,
        ),
      ],
    );
  }
}
