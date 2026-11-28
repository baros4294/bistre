part of 'folio_shell_screen.dart';

/// Compact header tab counter badge shown on narrow screens (`TopEditorialBar`,
/// Compact tab switcher badge shown when `> 1` tab is open or any
/// background chat is streaming.
class _CompactTabBadge extends StatefulWidget {
  const _CompactTabBadge({
    required this.count,
    required this.backgroundStreaming,
    required this.reduceMotionOverride,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final int count;
  final bool backgroundStreaming;
  final bool reduceMotionOverride;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  State<_CompactTabBadge> createState() => _CompactTabBadgeState();
}

class _CompactTabBadgeState extends State<_CompactTabBadge> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final active = widget.backgroundStreaming;
    return TapTargetExpander(
      minSize: minTapTarget,
      child: HoverHint(
        message: widget.semanticsLabel,
        child: PressFeedback(
          child: Semantics(
            button: true,
            label: widget.semanticsLabel,
            excludeSemantics: true,
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
                    widget.onPressed();
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onPressed,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  child: EaseDecoration(
                    decoration: BoxDecoration(
                      color: active
                          ? theme.accentBrass.withValues(alpha: 0.16)
                          : (_hovered ? theme.hoverTint : theme.bgSurface),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _focused || active
                            ? theme.accentBrass
                            : theme.borderHairline,
                        width: _focused ? 1.8 : 1,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (active) ...[
                            StreamingPulseDot(
                              color: theme.accentBrass,
                              size: 6,
                              reduceMotionOverride: widget.reduceMotionOverride,
                            ),
                            const SizedBox(width: 4),
                          ],
                          InkText(
                            widget.count.toString(),
                            role: InkTextRole.labelStrong,
                            color: active
                                ? theme.accentBrass
                                : theme.inkPrimary,
                          ),
                        ],
                      ),
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
}

class _BootFailedPage extends StatelessWidget {
  const _BootFailedPage({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return ColoredBox(
      color: theme.bgCanvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: InkText(
                  l10n.t(L10nKey.bootFailed),
                  role: InkTextRole.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: BistreSpacing.s16),
              EngravedButton(
                label: l10n.t(L10nKey.bootTryAgain),
                primary: true,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A focusable, labelled header control (title rename, model picker): keyboard Enter/Space
/// activates it, and a 2 px focus ring appears only for keyboard focus.
class _HeaderPressable extends StatefulWidget {
  const _HeaderPressable({
    required this.child,
    required this.semanticsLabel,
    required this.onPressed,
    this.cursor = SystemMouseCursors.click,
  });

  final Widget child;
  final String semanticsLabel;
  final VoidCallback? onPressed;
  final MouseCursor cursor;

  @override
  State<_HeaderPressable> createState() => _HeaderPressableState();
}

class _HeaderPressableState extends State<_HeaderPressable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final onPressed = widget.onPressed;
    return HoverHint(
      message: onPressed != null ? widget.semanticsLabel : '',
      child: Semantics(
        button: onPressed != null,
        label: widget.semanticsLabel,
        child: FocusableActionDetector(
          enabled: onPressed != null,
          mouseCursor: onPressed != null ? widget.cursor : MouseCursor.defer,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onPressed?.call();
                return null;
              },
            ),
          },
          child: PressFeedback(
            pressScale: kRowPressScale,
            hoverScale: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPressed,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: _focused
                      ? Border.all(color: theme.accentBrass, width: 2)
                      : null,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 24),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
