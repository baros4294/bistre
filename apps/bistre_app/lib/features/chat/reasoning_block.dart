import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Collapsible editorial thinking/reasoning hairline drawer (`Thinking · 3.8s`)
/// supporting live streaming expansion and 1-click quoting into the composer.
class ReasoningBlock extends StatefulWidget {
  const ReasoningBlock({
    super.key,
    required this.thinkingText,
    this.durationMs = 0,
    this.isStreaming = false,
    this.onQuoteIntoComposer,
    this.autoCollapse = true,
  });

  final String thinkingText;
  final int durationMs;
  final bool isStreaming;
  final ValueChanged<String>? onQuoteIntoComposer;

  /// Settings > Appearance: fold the thinking once the reply arrives (and keep finished
  /// thinking folded). Off keeps it open.
  final bool autoCollapse;

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  bool _expanded = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming || !widget.autoCollapse;
  }

  @override
  void didUpdateWidget(covariant ReasoningBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.autoCollapse != widget.autoCollapse && !widget.isStreaming) {
      // The setting changed while this reply is on screen: apply it now.
      _expanded = !widget.autoCollapse;
    }
    if (oldWidget.isStreaming &&
        !widget.isStreaming &&
        _expanded &&
        widget.autoCollapse) {
      // Collapse gently once final prose arrives so reading canvas stays calm.
      _expanded = false;
    }
  }

  static String _formatSeconds(int ms) {
    final secs = ms / 1000.0;
    return secs >= 10 ? secs.toStringAsFixed(0) : secs.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final headerLabel = widget.durationMs > 0
        ? l10n.t(L10nKey.chatThinkingSeconds, <String, Object?>{
            'seconds': _formatSeconds(widget.durationMs),
          })
        : l10n.t(L10nKey.chatThinkingLabel);

    final hasText = widget.thinkingText.trim().isNotEmpty;
    // Quiet `> Thought 2.4s` disclosure on the trailing edge above the reply; expanding
    // shows a tinted panel whose content fades in (the size snaps; layout never animates).
    final toggle = Semantics(
      button: true,
      expanded: _expanded,
      label: headerLabel,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              setState(() => _expanded = !_expanded);
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: _focused
                    ? Border.all(color: theme.accentBrass, width: 2)
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BistreIcon(
                      _expanded
                          ? BistreUiIcon.chevronDown
                          : BistreUiIcon.chevronEnd,
                      size: 12,
                      color: theme.inkMuted,
                    ),
                    const SizedBox(width: 4),
                    if (widget.isStreaming) ...[
                      BistreIcon(
                        BistreUiIcon.think,
                        size: 12,
                        color: theme.accentWax,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: InkText(
                        headerLabel,
                        role: InkTextRole.captionMeta,
                        color: _hovered ? theme.inkPrimary : theme.inkSecondary,
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
    );

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: BistreSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: AlignmentDirectional.centerEnd, child: toggle),
          if (hasText)
            DisclosureReveal(
              open: _expanded,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.bgSurface.withValues(
                    alpha: theme.isDark ? 0.5 : 0.7,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.borderHairline),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: SmoothScrollable(
                          builder: (_, scroll) => SingleChildScrollView(
                            controller: scroll,
                            child: InkText(
                              widget.thinkingText.trim(),
                              role: InkTextRole.bodyCompact,
                              color: theme.inkSecondary,
                            ),
                          ),
                        ),
                      ),
                      if (widget.onQuoteIntoComposer != null) ...[
                        const SizedBox(height: 4),
                        // An icon like the reply's Reply action; its name is in the
                        // hover hint and the screen-reader label.
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: BistreIconButton(
                            icon: BistreUiIcon.reply,
                            size: 13,
                            dimension: 28,
                            semanticsLabel: l10n.t(L10nKey.chatQuoteThinking),
                            onPressed: () => widget.onQuoteIntoComposer!(
                              widget.thinkingText.trim(),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
