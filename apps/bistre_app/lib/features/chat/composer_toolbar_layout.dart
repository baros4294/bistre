import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Composer toolbar layout: `leading`, then `gauge` and `trailing` at the end, in one row
/// whenever their real widths fit (any locale, any text size); otherwise two rows (leading +
/// gauge, then trailing at the end). Measured, never guessed from the text scale.
class ComposerToolbarLayout extends MultiChildRenderObjectWidget {
  ComposerToolbarLayout({
    super.key,
    required Widget leading,
    required Widget gauge,
    required Widget trailing,
    this.forceTwoRows = false,
    this.onMeasured,
    this.gap = 8,
    this.rowGap = 8,
  }) : super(children: <Widget>[leading, gauge, trailing]);

  /// Two rows regardless of width (phones while a reply streams: Stop / Queue / Steer).
  final bool forceTwoRows;

  /// Reports the width one row needs and the width it had, after each layout (never during
  /// a dry layout).
  final void Function(double need, double width)? onMeasured;
  final double gap;
  final double rowGap;

  @override
  RenderComposerToolbarLayout createRenderObject(BuildContext context) =>
      RenderComposerToolbarLayout(
        textDirection: Directionality.of(context),
        forceTwoRows: forceTwoRows,
        onMeasured: onMeasured,
        gap: gap,
        rowGap: rowGap,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderComposerToolbarLayout renderObject,
  ) {
    renderObject
      ..textDirection = Directionality.of(context)
      ..forceTwoRows = forceTwoRows
      ..onMeasured = onMeasured
      ..gap = gap
      ..rowGap = rowGap;
  }
}

class _ToolbarParentData extends ContainerBoxParentData<RenderBox> {}

/// Render object for [ComposerToolbarLayout]; [isOneRow] reports the last layout.
class RenderComposerToolbarLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ToolbarParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ToolbarParentData> {
  RenderComposerToolbarLayout({
    required TextDirection textDirection,
    required bool forceTwoRows,
    this.onMeasured,
    required double gap,
    required double rowGap,
  }) : _textDirection = textDirection,
       _forceTwoRows = forceTwoRows,
       _gap = gap,
       _rowGap = rowGap;

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  bool _forceTwoRows;
  set forceTwoRows(bool v) {
    if (v == _forceTwoRows) return;
    _forceTwoRows = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _rowGap;
  set rowGap(double v) {
    if (v == _rowGap) return;
    _rowGap = v;
    markNeedsLayout();
  }

  void Function(double need, double width)? onMeasured;

  bool _oneRow = true;

  /// Whether the last layout fit everything in one row.
  bool get isOneRow => _oneRow;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ToolbarParentData) {
      child.parentData = _ToolbarParentData();
    }
  }

  List<RenderBox> get _kids => getChildrenAsList();

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final kids = _kids;
    if (kids.length != 3) return constraints.smallest;
    final [leading, gauge, trailing] = kids;
    final maxW = constraints.maxWidth;
    final need =
        leading.getMaxIntrinsicWidth(double.infinity) +
        _gap +
        gauge.getMaxIntrinsicWidth(double.infinity) +
        _gap +
        trailing.getMaxIntrinsicWidth(double.infinity);
    final oneRow = !_forceTwoRows && need <= maxW;
    final loose = BoxConstraints(maxWidth: maxW);

    Size measure(RenderBox child, BoxConstraints c) => dry
        ? child.getDryLayout(c)
        : (child..layout(c, parentUsesSize: true)).size;

    final gaugeSize = measure(gauge, loose);
    final trailingSize = measure(trailing, loose);
    final leadingMax = oneRow
        ? maxW - _gap - gaugeSize.width - _gap - trailingSize.width
        : maxW - _gap - gaugeSize.width;
    final leadingSize = measure(
      leading,
      BoxConstraints(maxWidth: math.max(0, leadingMax)),
    );

    final rtl = _textDirection == TextDirection.rtl;
    // Start-edge x for a box of width [w] at logical start offset [start].
    double x(double start, double w) => rtl ? maxW - start - w : start;

    late final double height;
    if (oneRow) {
      height = [
        leadingSize.height,
        gaugeSize.height,
        trailingSize.height,
      ].reduce(math.max);
      if (!dry) {
        _place(
          leading,
          x(0, leadingSize.width),
          (height - leadingSize.height) / 2,
        );
        final trailingStart = maxW - trailingSize.width;
        _place(
          trailing,
          x(trailingStart, trailingSize.width),
          (height - trailingSize.height) / 2,
        );
        final gaugeStart = trailingStart - _gap - gaugeSize.width;
        _place(
          gauge,
          x(gaugeStart, gaugeSize.width),
          (height - gaugeSize.height) / 2,
        );
      }
    } else {
      final first = math.max(leadingSize.height, gaugeSize.height);
      height = first + _rowGap + trailingSize.height;
      if (!dry) {
        _place(
          leading,
          x(0, leadingSize.width),
          (first - leadingSize.height) / 2,
        );
        _place(
          gauge,
          x(maxW - gaugeSize.width, gaugeSize.width),
          (first - gaugeSize.height) / 2,
        );
        _place(
          trailing,
          x(maxW - trailingSize.width, trailingSize.width),
          first + _rowGap,
        );
      }
    }
    if (!dry) {
      _oneRow = oneRow;
      onMeasured?.call(need, maxW);
    }
    return constraints.constrain(Size(maxW, height));
  }

  void _place(RenderBox child, double dx, double dy) {
    (child.parentData! as _ToolbarParentData).offset = Offset(dx, dy);
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _kids.fold(0, (w, c) => math.max(w, c.getMinIntrinsicWidth(height)));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _kids.fold(0.0, (w, c) => w + c.getMaxIntrinsicWidth(height)) + 2 * _gap;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
