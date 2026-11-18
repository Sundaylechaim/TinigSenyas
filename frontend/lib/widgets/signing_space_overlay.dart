import 'package:flutter/material.dart';

class SigningSpaceOverlay extends StatelessWidget {
  final bool showZoneGuides;
  final bool showUpperBodyGuide;
  final bool handsDetected;

  const SigningSpaceOverlay({
    super.key,
    this.showZoneGuides = true,
    this.showUpperBodyGuide = true,
    this.handsDetected = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!showZoneGuides) return const SizedBox.shrink();

    final boundaryColor = handsDetected
        ? const Color(0xFF42D6A4)
        : const Color(0xFFF4C95D);

    return IgnorePointer(
      child: CustomPaint(
        painter: _SigningGuidePainter(
          showUpperBodyGuide: showUpperBodyGuide,
          boundaryColor: boundaryColor,
        ),
      ),
    );
  }
}

class _SigningGuidePainter extends CustomPainter {
  const _SigningGuidePainter({
    required this.showUpperBodyGuide,
    required this.boundaryColor,
  });

  final bool showUpperBodyGuide;
  final Color boundaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = showUpperBodyGuide
        ? Rect.fromLTRB(
            size.width * 0.17,
            size.height * 0.24,
            size.width * 0.83,
            size.height * 0.76,
          )
        : Rect.fromLTRB(
            size.width * 0.12,
            size.height * 0.30,
            size.width * 0.88,
            size.height * 0.70,
          );
    final framePaint = Paint()
      ..color = boundaryColor.withValues(alpha: 0.72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // A light corner frame guides camera placement without drawing over the
    // signer or implying that the model tracks full-body landmarks.
    _drawCornerFrame(canvas, frame, framePaint);
  }

  void _drawCornerFrame(Canvas canvas, Rect rect, Paint paint) {
    const corner = 18.0;
    for (final side in [1.0, -1.0]) {
      final x = side == 1.0 ? rect.left : rect.right;
      final xDirection = side;
      for (final vertical in [1.0, -1.0]) {
        final y = vertical == 1.0 ? rect.top : rect.bottom;
        final yDirection = vertical;
        canvas.drawLine(
          Offset(x, y + corner * yDirection),
          Offset(x, y),
          paint,
        );
        canvas.drawLine(
          Offset(x, y),
          Offset(x + corner * xDirection, y),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SigningGuidePainter oldDelegate) =>
      showUpperBodyGuide != oldDelegate.showUpperBodyGuide ||
      boundaryColor != oldDelegate.boundaryColor;
}
