import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A label and its control: side by side whenever the control's real width fits next to a
/// readable label, otherwise the control drops below the label. Small controls (a switch, a
/// compact picker, a short button) therefore stay on their label's row on a phone and at
/// 200% text; only wide ones (a text field, a long segmented choice) stack. Measured, never
/// guessed from the window width or the text scale.
class LabelControlLayout extends MultiChildRenderObjectWidget {
  LabelControlLayout({
    super.key,
    required Widget label,
    required Widget control,
    this.gap = 16,
    this.stackGap = 8,
    this.minLabelWidth = 120,
    this.forceStacked,
  }) : super(children: <Widget>[label, control]);

  /// Space between the label and the control in a row.
  final double gap;

  /// Space between the label and the control once stacked.
  final double stackGap;

  /// The label keeps at least this much width (times the text scale) before the control
  /// drops below it; a label shorter than that only needs its own width.
  final double minLabelWidth;

  /// When non-null, overrides per-row auto-stacking so a group of sibling rows aligns uniformly.
  final bool? forceStacked;

  @override
  RenderLabelControlLayout createRenderObject(BuildContext context) =>
      RenderLabelControlLayout(
        textDirection: Directionality.of(context),
        textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
        gap: gap,
        stackGap: stackGap,
        minLabelWidth: minLabelWidth,
        forceStacked: forceStacked,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLabelControlLayout renderObject,
  ) {
    renderObject
      ..textDirection = Directionality.of(context)
      ..textScale = MediaQuery.textScalerOf(context).scale(14) / 14
      ..gap = gap
      ..stackGap = stackGap
      ..minLabelWidth = minLabelWidth
      ..forceStacked = forceStacked;
  }
}

class _LabelControlParentData extends ContainerBoxParentData<RenderBox> {}

/// Render object for [LabelControlLayout]; [isStacked] reports the last layout.
class RenderLabelControlLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _LabelControlParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _LabelControlParentData> {
  RenderLabelControlLayout({
    required TextDirection textDirection,
    required double textScale,
    required double gap,
    required double stackGap,
    required double minLabelWidth,
    bool? forceStacked,
  }) : _textDirection = textDirection,
       _textScale = textScale,
       _gap = gap,
       _stackGap = stackGap,
       _minLabelWidth = minLabelWidth,
       _forceStacked = forceStacked;

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  double _textScale;
  set textScale(double v) {
    if (v == _textScale) return;
    _textScale = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _stackGap;
  set stackGap(double v) {
    if (v == _stackGap) return;
    _stackGap = v;
    markNeedsLayout();
  }

  double _minLabelWidth;
  set minLabelWidth(double v) {
    if (v == _minLabelWidth) return;
    _minLabelWidth = v;
    markNeedsLayout();
  }

  bool? _forceStacked;
  set forceStacked(bool? v) {
    if (v == _forceStacked) return;
    _forceStacked = v;
    markNeedsLayout();
  }

  bool _stacked = false;

  /// Whether the last layout put the control below the label.
  bool get isStacked => _stacked;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _LabelControlParentData) {
      child.parentData = _LabelControlParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final kids = getChildrenAsList();
    if (kids.length != 2) return constraints.smallest;
    final [label, control] = kids;
    final maxW = constraints.maxWidth;
    final controlW = math.min(
      control.getMaxIntrinsicWidth(double.infinity),
      maxW,
    );
    final labelNeed = math.min(
      label.getMaxIntrinsicWidth(double.infinity),
      _minLabelWidth * _textScale,
    );
    final stacked = _forceStacked ?? (labelNeed + _gap + controlW > maxW);

    Size measure(RenderBox child, BoxConstraints c) => dry
        ? child.getDryLayout(c)
        : (child..layout(c, parentUsesSize: true)).size;

    final rtl = _textDirection == TextDirection.rtl;
    double x(double start, double w) => rtl ? maxW - start - w : start;

    late final double height;
    if (!stacked) {
      // All the room beside the label: a `Wrap`'s intrinsic width leaves out its spacing,
      // so exactly that width would wrap it onto a second line.
      final controlSize = measure(
        control,
        BoxConstraints(maxWidth: math.max(controlW, maxW - labelNeed - _gap)),
      );
      final labelSize = measure(
        label,
        BoxConstraints(maxWidth: math.max(0, maxW - _gap - controlSize.width)),
      );
      height = math.max(labelSize.height, controlSize.height);
      if (!dry) {
        _place(label, x(0, labelSize.width), (height - labelSize.height) / 2);
        _place(
          control,
          x(maxW - controlSize.width, controlSize.width),
          (height - controlSize.height) / 2,
        );
      }
    } else {
      final labelSize = measure(label, BoxConstraints(maxWidth: maxW));
      final controlSize = measure(control, BoxConstraints(maxWidth: maxW));
      height = labelSize.height + _stackGap + controlSize.height;
      if (!dry) {
        _place(label, x(0, labelSize.width), 0);
        _place(control, x(0, controlSize.width), labelSize.height + _stackGap);
      }
    }
    if (!dry) _stacked = stacked;
    return constraints.constrain(Size(maxW, height));
  }

  void _place(RenderBox child, double dx, double dy) {
    (child.parentData! as _LabelControlParentData).offset = Offset(dx, dy);
  }

  @override
  double computeMinIntrinsicWidth(double height) => getChildrenAsList().fold(
    0,
    (w, c) => math.max(w, c.getMinIntrinsicWidth(height)),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      getChildrenAsList().fold(
        0.0,
        (w, c) => w + c.getMaxIntrinsicWidth(height),
      ) +
      _gap;

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
