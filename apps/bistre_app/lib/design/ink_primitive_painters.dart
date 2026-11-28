part of 'ink_primitives.dart';

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
