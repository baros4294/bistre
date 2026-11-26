import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_graphics/vector_graphics.dart';

import 'bistre_icons.dart' show TapTargetExpander, minTapTarget;
import 'bistre_selection_controls.dart';
import 'bistre_theme.dart';
import 'hover_hint.dart';
import 'press_feedback.dart';

/// 1. `BistreScaffold`: Edge-to-edge inset-safe page shell (Android 15/16 compliant).
class BistreScaffold extends StatelessWidget {
  const BistreScaffold({
    super.key,
    required this.header,
    required this.body,
    required this.footer,
  });

  final Widget header;
  final Widget body;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final bottomAvoidance = insets.bottom > pad.bottom
        ? insets.bottom
        : pad.bottom;

    return ColoredBox(
      color: theme.bgCanvas,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          top: pad.top,
          start: isRtl ? pad.right : pad.left,
          end: isRtl ? pad.left : pad.right,
          bottom: bottomAvoidance,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const FolioDivider(),
            Expanded(child: body),
            footer,
          ],
        ),
      ),
    );
  }
}

enum FolioTone { canvas, surface, elevated }

/// 2. `FolioSurface`: Tonal paper container with subtle 1px hairline border.
class FolioSurface extends StatelessWidget {
  const FolioSurface({
    super.key,
    required this.child,
    this.tone = FolioTone.surface,
    this.padding = const EdgeInsetsDirectional.all(BistreSpacing.s12),
    this.borderRadius = 10,
    this.customBorderRadius,
    this.bordered = true,
    this.boxShadow,
  });

  final Widget child;
  final FolioTone tone;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final BorderRadiusGeometry? customBorderRadius;
  final bool bordered;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final color = switch (tone) {
      FolioTone.canvas => theme.bgCanvas,
      FolioTone.surface => theme.bgSurface,
      FolioTone.elevated => theme.bgElevated,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: customBorderRadius ?? BorderRadius.circular(borderRadius),
        border: bordered ? Border.all(color: theme.borderHairline) : null,
        boxShadow: boxShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

enum InkTextRole {
  titleLarge,
  titleMedium,
  bodyProse,
  bodyCompact,
  labelStrong,
  captionMeta,
  codeBlock,
}

/// 3. `InkText`: Semantic text primitive bound to Sepia Book typography & contrast tokens.
class InkText extends StatelessWidget {
  const InkText(
    this.data, {
    super.key,
    this.role = InkTextRole.bodyProse,
    this.color,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String data;
  final InkTextRole role;
  final Color? color;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final baseColor =
        color ??
        switch (role) {
          InkTextRole.captionMeta => theme.inkMuted,
          InkTextRole.labelStrong => theme.inkSecondary,
          _ => theme.inkPrimary,
        };
    final cfg = theme.typography;
    final style = switch (role) {
      InkTextRole.titleLarge => BistreTypography.titleLarge(
        baseColor,
        config: cfg,
      ),
      InkTextRole.titleMedium => BistreTypography.titleMedium(
        baseColor,
        config: cfg,
      ),
      InkTextRole.bodyProse => BistreTypography.bodyProse(
        baseColor,
        config: cfg,
      ),
      InkTextRole.bodyCompact => BistreTypography.bodyCompact(
        baseColor,
        config: cfg,
      ),
      InkTextRole.labelStrong => BistreTypography.labelStrong(
        baseColor,
        config: cfg,
      ),
      InkTextRole.captionMeta => BistreTypography.captionMeta(
        baseColor,
        config: cfg,
      ),
      InkTextRole.codeBlock => BistreTypography.codeBlock(
        baseColor,
        config: cfg,
      ),
    };

    return Text(
      data,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}

/// 4. `EngravedButton`: Keyboard-focusable, zero-latency primary/secondary action button.
class EngravedButton extends StatefulWidget {
  const EngravedButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.leading,
    this.compact = false,
    this.semanticsLabel,
  });

  final String label;

  /// A fuller name when [label] is shortened (e.g. `Auto` for `Thinking: Auto`): screen
  /// readers announce it and a hover hint shows it.
  final String? semanticsLabel;
  final VoidCallback? onPressed;
  final bool primary;
  final Widget? leading;
  final bool compact;

  @override
  State<EngravedButton> createState() => _EngravedButtonState();
}

class _EngravedButtonState extends State<EngravedButton> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  void _invoke() {
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final enabled = widget.onPressed != null;
    // Disabled buttons stay legible: no fill, but a visible outline and muted ink (never just
    // a faded primary fill).
    final bg = !enabled
        ? theme.bgElevated.withValues(alpha: 0)
        : widget.primary
        ? theme.accentWax
        : theme.bgElevated;
    final fg = !enabled
        ? theme.inkMuted
        : widget.primary
        ? theme.onAccentWax
        : theme.inkPrimary;
    final outline = !enabled
        ? theme.inkMuted.withValues(alpha: 0.5)
        : widget.primary
        ? theme.accentWax
        : theme.borderHairline;
    final minH = widget.compact ? 34.0 : 38.0;

    // Compact controls still take taps across the minimum target (DESIGN.md §7).
    return TapTargetExpander(
      minSize: minTapTarget,
      child: HoverHint(
        message: widget.semanticsLabel ?? '',
        child: PressFeedback(
          enabled: enabled,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.semanticsLabel ?? widget.label,
            child: FocusableActionDetector(
              enabled: enabled,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              // Focus highlight fires only in keyboard (traditional) highlight mode, so the brass ring
              // never appears after a pointer click.
              onShowFocusHighlight: (v) => setState(() => _focused = v),
              onShowHoverHighlight: (v) => setState(() => _hovered = v),
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
              },
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _invoke();
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                onTapDown: enabled
                    ? (_) => setState(() => _pressed = true)
                    : null,
                onTapUp: enabled
                    ? (_) {
                        setState(() => _pressed = false);
                        _invoke();
                      }
                    : null,
                onTapCancel: () => setState(() => _pressed = false),
                child: Opacity(
                  opacity: !enabled
                      ? 1.0
                      : _pressed
                      ? 0.84
                      : _hovered
                      ? 0.93
                      : 1.0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minH, minWidth: 40),
                    child: EaseDecoration(
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _focused ? theme.accentBrass : outline,
                          width: _focused ? 2 : 1,
                        ),
                        boxShadow: enabled && widget.primary
                            ? theme.cardShadow
                            : null,
                      ),
                      child: Padding(
                        padding: EdgeInsetsDirectional.symmetric(
                          horizontal: widget.compact ? 12 : 14,
                          vertical: widget.compact ? 6 : 8,
                        ),
                        child: Center(
                          widthFactor: 1,
                          heightFactor: 1,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.leading != null) ...[
                                // S2: a disabled button's icon takes the muted ink too (a light icon meant
                                // for the filled primary would vanish on the empty disabled face).
                                enabled
                                    ? widget.leading!
                                    : ColorFiltered(
                                        colorFilter: ColorFilter.mode(
                                          fg,
                                          BlendMode.srcIn,
                                        ),
                                        child: widget.leading,
                                      ),
                                if (widget.label.isNotEmpty)
                                  const SizedBox(width: 7),
                              ],
                              if (widget.label.isNotEmpty)
                                Flexible(
                                  child: InkText(
                                    widget.label,
                                    role: InkTextRole.labelStrong,
                                    color: fg,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum WaxSealStatus { ok, warn, error, neutral }

/// 5. `WaxSealBadge`: Status seal conveying meaning by engraved glyph + text (never color alone).
class WaxSealBadge extends StatelessWidget {
  const WaxSealBadge({
    super.key,
    required this.label,
    this.status = WaxSealStatus.ok,
  });

  final String label;
  final WaxSealStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final accent = switch (status) {
      WaxSealStatus.ok => theme.statusOk,
      WaxSealStatus.warn => theme.statusWarn,
      WaxSealStatus.error => theme.statusErr,
      WaxSealStatus.neutral => theme.inkSecondary,
    };

    return Semantics(
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgSurface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: BistreSpacing.s12,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size.square(10),
                painter: _SealGlyphPainter(color: accent, status: status),
              ),
              const SizedBox(width: BistreSpacing.s8),
              Flexible(
                child: InkText(
                  label,
                  role: InkTextRole.captionMeta,
                  color: accent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SealGlyphPainter extends CustomPainter {
  const _SealGlyphPainter({required this.color, required this.status});

  final Color color;
  final WaxSealStatus status;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final center = Offset(size.width / 2, size.height / 2);
    switch (status) {
      case WaxSealStatus.ok:
        canvas.drawCircle(center, size.width * 0.42, paint);
      case WaxSealStatus.warn:
        final path = Path()
          ..moveTo(size.width / 2, 0)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(path, paint);
      case WaxSealStatus.error:
        canvas.drawRect(
          Rect.fromCenter(
            center: center,
            width: size.width * 0.78,
            height: size.height * 0.78,
          ),
          paint,
        );
      case WaxSealStatus.neutral:
        final r = size.width * 0.38;
        final diamond = Path()
          ..moveTo(center.dx, center.dy - r)
          ..lineTo(center.dx + r, center.dy)
          ..lineTo(center.dx, center.dy + r)
          ..lineTo(center.dx - r, center.dy)
          ..close();
        canvas.drawPath(diamond, paint);
    }
  }

  @override
  bool shouldRepaint(_SealGlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.status != status;
}

/// 6. `QuillInput`: Pure `EditableText` composer safe for Vietnamese Telex/VNI & CJK IMEs.
class QuillInput extends StatefulWidget {
  const QuillInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onSubmitted,
    this.onChanged,
    this.maxLines = 5,
    this.minLines = 1,
    this.submitOnEnter = true,
    this.obscureText = false,
    this.frameless = false,
    this.compact = false,
    this.onTapOutside,
    this.semanticsLabel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final VoidCallback onSubmitted;
  final ValueChanged<String>? onChanged;
  final int maxLines;
  final int minLines;
  final bool submitOnEnter;
  final bool obscureText;
  final bool frameless;
  final bool compact;

  /// A pointer down outside the field while it has focus (commit-on-click-away editors).
  final TapRegionCallback? onTapOutside;

  /// The field's accessible name; the placeholder when omitted (U27).
  final String? semanticsLabel;

  @override
  State<QuillInput> createState() => _QuillInputState();
}

class _QuillInputState extends State<QuillInput>
    implements TextSelectionGestureDetectorBuilderDelegate {
  final GlobalKey<EditableTextState> _editableTextKey =
      GlobalKey<EditableTextState>();
  final BistreSelectionControls _selectionControls = BistreSelectionControls();
  late final TextSelectionGestureDetectorBuilder
  _selectionGestureDetectorBuilder = _QuillSelectionGestureDetectorBuilder(
    state: this,
  );
  bool _focused = false;

  @override
  GlobalKey<EditableTextState> get editableTextKey => _editableTextKey;

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => true;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    widget.controller.addListener(_onControllerChange);
  }

  @override
  void didUpdateWidget(QuillInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onFocusChange() {
    if (_focused != widget.focusNode.hasFocus) {
      setState(() => _focused = widget.focusNode.hasFocus);
    }
  }

  void _onControllerChange() {
    // IME composition guard: never programmatically alter text while composing is active.
    setState(() {});
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.submitOnEnter) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    // Never intercept Enter while an IME composition (Vietnamese/CJK) is active.
    if (widget.controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    widget.onSubmitted();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final isEmpty = widget.controller.text.isEmpty;

    final isMultiline = !widget.obscureText && widget.minLines > 1;
    // A-W 2a: a one-line field always submits on Enter (`submitOnEnter` only shapes the
    // multi-line composer, where Enter may also add a line).
    final singleLine = widget.obscureText || widget.maxLines == 1;
    final editorStack = Stack(
      alignment: isMultiline
          ? AlignmentDirectional.topStart
          : AlignmentDirectional.centerStart,
      children: [
        if (isEmpty)
          IgnorePointer(
            // U27: the field carries the name; the drawn placeholder is not read twice.
            child: ExcludeSemantics(
              child: InkText(
                widget.placeholder,
                role: InkTextRole.bodyCompact,
                color: theme.inkMuted,
                maxLines: isMultiline ? widget.maxLines : 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        Semantics(
          label: widget.semanticsLabel ?? widget.placeholder,
          child: EditableText(
            key: _editableTextKey,
            controller: widget.controller,
            focusNode: widget.focusNode,
            style: BistreTypography.bodyProse(
              theme.inkPrimary,
              config: theme.typography,
            ),
            cursorColor: theme.accentWax,
            backgroundCursorColor: theme.bgSurface,
            selectionColor: theme.selectionFill,
            selectionControls: _selectionControls,
            contextMenuBuilder: buildBistreEditableContextMenu,
            rendererIgnoresPointer: true,
            mouseCursor: MouseCursor.defer,
            maxLines: widget.obscureText ? 1 : widget.maxLines,
            minLines: widget.obscureText ? 1 : widget.minLines,
            obscureText: widget.obscureText,
            keyboardType: widget.obscureText
                ? TextInputType.visiblePassword
                : singleLine
                ? TextInputType.text
                : TextInputType.multiline,
            textInputAction: singleLine
                ? TextInputAction.done
                : TextInputAction.newline,
            enableSuggestions: !widget.obscureText,
            autocorrect: !widget.obscureText,
            onChanged: widget.onChanged,
            onSubmitted: singleLine ? (_) => widget.onSubmitted() : null,
            onTapOutside: widget.onTapOutside,
          ),
        ),
      ],
    );

    final fieldSurface = widget.frameless
        ? editorStack
        : DecoratedBox(
            decoration: BoxDecoration(
              color: theme.bgElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused ? theme.accentBrass : theme.borderHairline,
                width: _focused ? 1.8 : 1,
              ),
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.symmetric(
                horizontal: BistreSpacing.s12,
                vertical: widget.compact ? 7 : 10,
              ),
              child: editorStack,
            ),
          );

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: _selectionGestureDetectorBuilder.buildGestureDetector(
          behavior: HitTestBehavior.opaque,
          child: fieldSurface,
        ),
      ),
    );
  }
}

class _QuillSelectionGestureDetectorBuilder
    extends TextSelectionGestureDetectorBuilder {
  _QuillSelectionGestureDetectorBuilder({required _QuillInputState state})
    : _state = state,
      super(delegate: state);

  final _QuillInputState _state;

  @override
  void onSingleTapUp(TapDragUpDetails details) {
    super.onSingleTapUp(details);
    if (!_state.widget.focusNode.hasFocus) {
      _state.widget.focusNode.requestFocus();
    }
  }
}

/// 7. `FolioDivider`: Subtle 1px translucent hairline divider.
class FolioDivider extends StatelessWidget {
  const FolioDivider({super.key, this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return SizedBox(
      width: vertical ? 1 : double.infinity,
      height: vertical ? double.infinity : 1,
      child: ColoredBox(color: theme.borderHairline),
    );
  }
}

/// 8. `InkChip`: Compact toggleable chip with explicit selected state semantics & focus ring.
class InkChip extends StatefulWidget {
  const InkChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.semanticsLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final String? semanticsLabel;

  @override
  State<InkChip> createState() => _InkChipState();
}

class _InkChipState extends State<InkChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    // Compact controls still take taps across the minimum target (DESIGN.md §7).
    return TapTargetExpander(
      minSize: minTapTarget,
      child: PressFeedback(
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: widget.semanticsLabel ?? widget.label,
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.click,
            onShowFocusHighlight: (v) => setState(() => _focused = v),
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onSelected();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              onTap: widget.onSelected,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                child: EaseDecoration(
                  decoration: BoxDecoration(
                    color: widget.selected ? theme.bgElevated : theme.bgSurface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _focused || widget.selected
                          ? theme.accentBrass
                          : theme.borderHairline,
                      width: _focused ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: BistreSpacing.s12,
                      vertical: 6,
                    ),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: InkText(
                        widget.label,
                        role: InkTextRole.captionMeta,
                        color: widget.selected
                            ? theme.inkPrimary
                            : theme.inkSecondary,
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

/// Overlay controller whose [hide] fades the overlay out over `BistreMotion.leaving` before
/// removing it (DESIGN §6: overlays never snap shut). [toggle] and Escape go through [hide];
/// [hideNow] removes it at once. Reduce motion removes it at once too.
class FolioOverlayController extends OverlayPortalController {
  _FolioOverlayFadeState? _fade;

  @override
  void show() {
    _fade?._resetVisible();
    super.show();
  }

  @override
  void hide() {
    final fade = _fade;
    if (fade == null || !isShowing) {
      super.hide();
      return;
    }
    fade._fadeOut(() {
      if (isShowing) super.hide();
    });
  }

  /// Removes the overlay without the exit fade.
  void hideNow() => super.hide();
}

class _FolioOverlayFade extends StatefulWidget {
  const _FolioOverlayFade({required this.controller, required this.child});

  final FolioOverlayController controller;
  final Widget child;

  @override
  State<_FolioOverlayFade> createState() => _FolioOverlayFadeState();
}

class _FolioOverlayFadeState extends State<_FolioOverlayFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    value: 1,
    duration: BistreMotion.leaving,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller._fade = this;
  }

  @override
  void dispose() {
    if (identical(widget.controller._fade, this))
      widget.controller._fade = null;
    _opacity.dispose();
    super.dispose();
  }

  void _resetVisible() {
    _opacity.value = 1;
    if (_closing && mounted) setState(() => _closing = false);
  }

  void _fadeOut(VoidCallback done) {
    if (_closing) return;
    if (BistreMotion.shouldReduceMotion(context)) {
      done();
      return;
    }
    setState(() => _closing = true);
    _opacity.reverse().then((_) {
      if (_closing) done();
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: _closing,
      child: FadeTransition(opacity: _opacity, child: widget.child),
    );
  }
}

/// 9. `FolioOverlay`: `OverlayPortal`-backed modal/popover with Escape dismissal. With a
/// [FolioOverlayController] it fades out on close.
class FolioOverlay extends StatelessWidget {
  const FolioOverlay({
    super.key,
    required this.controller,
    required this.overlayBuilder,
    required this.child,
  });

  final OverlayPortalController controller;
  final WidgetBuilder overlayBuilder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: controller,
      overlayChildBuilder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            controller.hide();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: switch (controller) {
          final FolioOverlayController c => _FolioOverlayFade(
            controller: c,
            child: overlayBuilder(ctx),
          ),
          _ => overlayBuilder(ctx),
        },
      ),
      child: child,
    );
  }
}

/// 10. `EngravedIcon`: Resolution-independent GPU `ui.Picture` renderer for pre-compiled
/// `.vec` (`vector_graphics`) icons. Draws crisp mathematical vector paths directly at
/// native display DPR (avoiding `VectorGraphic`'s default low-res raster cache & bilinear blur)
/// while supporting both monochrome ink tinting and full-color AI lab marks.
class EngravedIcon extends StatefulWidget {
  const EngravedIcon({
    super.key,
    required this.assetPath,
    required this.semanticsLabel,
    this.size = 28,
    this.color,
  });

  final String assetPath;
  final String semanticsLabel;
  final double size;
  final Color? color;

  @override
  State<EngravedIcon> createState() => _EngravedIconState();
}

class _EngravedIconState extends State<EngravedIcon> {
  static final Map<String, PictureInfo> _pictureCache = <String, PictureInfo>{};
  static final Map<String, Future<PictureInfo>> _inFlight =
      <String, Future<PictureInfo>>{};

  PictureInfo? _pictureInfo;
  String? _loadedPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPicture();
  }

  @override
  void didUpdateWidget(EngravedIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetPath != widget.assetPath) {
      _syncPicture();
    }
  }

  void _syncPicture() {
    final path = widget.assetPath;
    if (_loadedPath == path && _pictureInfo != null) return;
    _loadedPath = path;

    final cached = _pictureCache[path];
    if (cached != null) {
      _pictureInfo = cached;
      return;
    }

    unawaited(_loadAndApply(path));
  }

  Future<void> _loadAndApply(String path) async {
    try {
      final info = await _inFlight.putIfAbsent(path, () async {
        try {
          final loaded = await vg.loadPicture(AssetBytesLoader(path), context);
          _pictureCache[path] = loaded;
          return loaded;
        } finally {
          final _ = _inFlight.remove(path);
        }
      });
      if (!mounted || widget.assetPath != path) return;
      setState(() => _pictureInfo = info);
    } on Object {
      final _ = _inFlight.remove(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _pictureCache[widget.assetPath] ?? _pictureInfo;
    final Widget vector = SizedBox.square(
      dimension: widget.size,
      child: info == null
          ? null
          : CustomPaint(
              size: Size.square(widget.size),
              painter: _VectorPicturePainter(
                pictureInfo: info,
                color: widget.color,
              ),
            ),
    );
    if (widget.semanticsLabel.isEmpty) {
      return ExcludeSemantics(child: vector);
    }
    return Semantics(image: true, label: widget.semanticsLabel, child: vector);
  }
}

class _VectorPicturePainter extends CustomPainter {
  const _VectorPicturePainter({required this.pictureInfo, this.color});

  final PictureInfo pictureInfo;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final srcSize = pictureInfo.size;
    if (srcSize.width <= 0 || srcSize.height <= 0 || size.isEmpty) return;

    final fitted = applyBoxFit(BoxFit.contain, srcSize, size);
    final dst = fitted.destination;
    final sx = dst.width / srcSize.width;
    final sy = dst.height / srcSize.height;
    final dx = (size.width - dst.width) / 2.0;
    final dy = (size.height - dst.height) / 2.0;

    canvas.save();
    if (color != null) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..colorFilter = ColorFilter.mode(color!, BlendMode.srcIn),
      );
    }
    canvas
      ..translate(dx, dy)
      ..scale(sx, sy)
      ..drawPicture(pictureInfo.picture);
    if (color != null) {
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VectorPicturePainter oldDelegate) =>
      !identical(oldDelegate.pictureInfo, pictureInfo) ||
      oldDelegate.color != color;
}
