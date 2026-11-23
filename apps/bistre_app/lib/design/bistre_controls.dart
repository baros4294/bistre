import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bistre_decorations.dart';
import 'bistre_theme.dart';
import 'ink_primitives.dart';

/// Pure `package:flutter/widgets.dart` continuous slider with keyboard support,
/// RTL-aware fill, visible brass focus ring, and zero layout animations.
class BistreSlider extends StatefulWidget {
  const BistreSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.semanticsLabel,
    this.step = 1.0,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String semanticsLabel;

  @override
  State<BistreSlider> createState() => _BistreSliderState();
}

class _BistreSliderState extends State<BistreSlider> {
  bool _focused = false;
  bool _hovered = false;
  bool _dragging = false;

  double _snap(double raw) {
    final clamped = raw.clamp(widget.min, widget.max);
    if (widget.step <= 0) return clamped;
    final steps = ((clamped - widget.min) / widget.step).round();
    return (widget.min + steps * widget.step).clamp(widget.min, widget.max);
  }

  void _updateFromLocalOffset(double dx, double width, bool isRtl) {
    if (width <= 0) return;
    final rawFrac = (dx / width).clamp(0.0, 1.0);
    final frac = isRtl ? (1.0 - rawFrac) : rawFrac;
    final next = _snap(widget.min + frac * (widget.max - widget.min));
    if ((next - widget.value).abs() > 1e-6) {
      widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final span = (widget.max - widget.min).abs();
    final fraction = span > 0
        ? ((widget.value - widget.min) / span).clamp(0.0, 1.0)
        : 0.0;

    return Semantics(
      slider: true,
      label: widget.semanticsLabel,
      value: widget.value.toStringAsFixed(widget.step < 1 ? 2 : 0),
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowRight): _SliderStepIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _SliderStepIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _SliderStepIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowDown): _SliderStepIntent(-1),
        },
        actions: <Type, Action<Intent>>{
          _SliderStepIntent: CallbackAction<_SliderStepIntent>(
            onInvoke: (intent) {
              final dir = isRtl ? -intent.delta : intent.delta;
              final next = _snap(widget.value + dir * widget.step);
              widget.onChanged(next);
              widget.onChangeEnd?.call(next);
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackW = constraints.maxWidth;
              const thumbSize = 16.0;
              final usableW = (trackW - thumbSize).clamp(0.0, double.infinity);
              final visualFrac = isRtl ? (1.0 - fraction) : fraction;
              final thumbOffset = visualFrac * usableW;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  _updateFromLocalOffset(d.localPosition.dx, trackW, isRtl);
                  widget.onChangeEnd?.call(widget.value);
                },
                onHorizontalDragStart: (d) {
                  setState(() => _dragging = true);
                  _updateFromLocalOffset(d.localPosition.dx, trackW, isRtl);
                },
                onHorizontalDragUpdate: (d) =>
                    _updateFromLocalOffset(d.localPosition.dx, trackW, isRtl),
                onHorizontalDragEnd: (_) {
                  setState(() => _dragging = false);
                  widget.onChangeEnd?.call(widget.value);
                },
                child: SizedBox(
                  height: 30,
                  width: trackW,
                  child: Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: [
                      SizedBox(
                        height: 4,
                        width: trackW,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.bgSurface,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: theme.borderHairline,
                              width: 0.5,
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor: fraction,
                          child: SizedBox(
                            height: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.accentBrass,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Transform.translate(
                        offset: Offset(thumbOffset, 0),
                        child: SizedBox.square(
                          dimension: thumbSize,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.bgElevated,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _focused || _dragging || _hovered
                                    ? theme.accentBrass
                                    : theme.inkSecondary,
                                width: _focused || _dragging ? 2.2 : 1.6,
                              ),
                              boxShadow: theme.cardShadow,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SliderStepIntent extends Intent {
  const _SliderStepIntent(this.delta);
  final int delta;
}

/// Pure-Widgets tactile toggle switch using GPU `Transform.translate` (zero layout animations).
class BistreSwitch extends StatefulWidget {
  const BistreSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticsLabel,
    this.reduceMotionOverride = false,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticsLabel;
  final bool reduceMotionOverride;

  @override
  State<BistreSwitch> createState() => _BistreSwitchState();
}

class _BistreSwitchState extends State<BistreSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, value: widget.value ? 1.0 : 0.0);
  }

  @override
  void didUpdateWidget(BistreSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final dur = BistreMotion.overlayDuration(
        context,
        reduceMotionOverride: widget.reduceMotionOverride,
      );
      _ctrl.duration = dur;
      if (dur == Duration.zero) {
        _ctrl.value = widget.value ? 1.0 : 0.0;
      } else {
        unawaited(widget.value ? _ctrl.forward() : _ctrl.reverse());
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Semantics(
      toggled: widget.value,
      button: true,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onChanged(!widget.value);
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onChanged(!widget.value),
            child: SizedBox(
              width: 42,
              height: 24,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.value ? theme.accentWax : theme.bgSurface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _focused
                        ? theme.accentBrass
                        : (widget.value
                              ? theme.accentWax
                              : theme.borderHairline),
                    width: _focused ? 2 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.all(2),
                  child: AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, child) {
                      final t = BistreMotion.easeOut.transform(_ctrl.value);
                      final dx = (isRtl ? -1.0 : 1.0) * (t * 18.0);
                      return Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Transform.translate(
                          offset: Offset(dx, 0),
                          child: child,
                        ),
                      );
                    },
                    child: SizedBox.square(
                      dimension: 18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.value
                              ? theme.onAccentWax
                              : theme.bgElevated,
                          shape: BoxShape.circle,
                          boxShadow: theme.cardShadow,
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

/// Compact segmented control strictly for 2–3 short mutually exclusive choices.
class BistreSegmentedOption<T> {
  const BistreSegmentedOption({
    required this.value,
    required this.label,
    this.leading,
  });

  final T value;
  final String label;
  final Widget? leading;
}

class BistreSegmentedControl<T> extends StatelessWidget {
  const BistreSegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.expand = false,
  });

  final List<BistreSegmentedOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.bgSurface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: theme.borderHairline),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(3),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              if (expand)
                Expanded(
                  child: _SegmentTile<T>(
                    option: options[i],
                    selected: options[i].value == selected,
                    onTap: () => onSelected(options[i].value),
                  ),
                )
              else
                // Loose flex: segments keep their natural width but may shrink (with ellipsis)
                // instead of overflowing on phones at large text.
                Flexible(
                  child: _SegmentTile<T>(
                    option: options[i],
                    selected: options[i].value == selected,
                    onTap: () => onSelected(options[i].value),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SegmentTile<T> extends StatefulWidget {
  const _SegmentTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final BistreSegmentedOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentTile<T>> createState() => _SegmentTileState<T>();
}

class _SegmentTileState<T> extends State<_SegmentTile<T>> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.option.label,
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
              widget.onTap();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.selected
                    ? theme.bgElevated
                    : (_hovered ? theme.hoverTint : null),
                borderRadius: BorderRadius.circular(6),
                border: _focused
                    ? Border.all(color: theme.accentBrass, width: 1.5)
                    : null,
                boxShadow: widget.selected ? theme.cardShadow : null,
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.option.leading != null) ...[
                      widget.option.leading!,
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: InkText(
                        widget.option.label,
                        role: InkTextRole.captionMeta,
                        color: widget.selected
                            ? theme.inkPrimary
                            : theme.inkSecondary,
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
  }
}

/// Spacious vertical settings card & section header enforcing consistent Studio Atelier rhythm.
class BistreSettingsSection extends StatelessWidget {
  const BistreSettingsSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkText(title, role: InkTextRole.titleMedium),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 3),
          InkText(
            subtitle!,
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
        ],
        const SizedBox(height: BistreSpacing.s12),
        FolioSurface(
          tone: FolioTone.elevated,
          padding: EdgeInsetsDirectional.zero,
          borderRadius: 12,
          boxShadow: theme.cardShadow,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const FolioDivider(),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Clean standardized row inside a `BistreSettingsSection`.
class BistreSettingRow extends StatelessWidget {
  const BistreSettingRow({
    super.key,
    required this.label,
    this.description,
    this.trailing,
    this.bottom,
  });

  final String label;
  final String? description;
  final Widget? trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: BistreSpacing.s16,
        vertical: 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Adaptive: `label | control` side by side on wide layouts, stacked
          // `label / full-width control` on phones and at large text.
          LayoutBuilder(
            builder: (context, constraints) {
              final labels = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkText(
                    label,
                    role: InkTextRole.bodyCompact,
                    color: theme.inkPrimary,
                  ),
                  if (description != null && description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    InkText(
                      description!,
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ],
                ],
              );
              final stacked =
                  trailing != null &&
                  constraints.maxWidth / textScaleOf(context) < 480;
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    labels,
                    const SizedBox(height: BistreSpacing.s8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: trailing,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: labels),
                  if (trailing != null) ...[
                    const SizedBox(width: BistreSpacing.s16),
                    trailing!,
                  ],
                ],
              );
            },
          ),
          if (bottom != null) ...[
            const SizedBox(height: BistreSpacing.s12),
            bottom!,
          ],
        ],
      ),
    );
  }
}
