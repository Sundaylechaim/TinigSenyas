import 'dart:math' as math;

import 'package:flutter/material.dart';

class HandLandmarkOverlay extends StatelessWidget {
  const HandLandmarkOverlay({
    required this.hands,
    required this.frameWidth,
    required this.frameHeight,
    required this.mirror,
    super.key,
  });

  final List<List<Offset>> hands;
  final int frameWidth;
  final int frameHeight;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    if (hands.isEmpty || frameWidth <= 0 || frameHeight <= 0) {
      return const SizedBox.expand();
    }

    return IgnorePointer(
      child: CustomPaint(
        painter: _HandLandmarkPainter(
          hands: hands,
          frameWidth: frameWidth,
          frameHeight: frameHeight,
          mirror: mirror,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _HandLandmarkPainter extends CustomPainter {
  const _HandLandmarkPainter({
    required this.hands,
    required this.frameWidth,
    required this.frameHeight,
    required this.mirror,
  });

  static const _connections = <(int, int)>[
    (0, 1),
    (1, 2),
    (2, 3),
    (3, 4),
    (0, 5),
    (5, 6),
    (6, 7),
    (7, 8),
    (5, 9),
    (9, 10),
    (10, 11),
    (11, 12),
    (9, 13),
    (13, 14),
    (14, 15),
    (15, 16),
    (13, 17),
    (17, 18),
    (18, 19),
    (19, 20),
    (0, 17),
  ];

  final List<List<Offset>> hands;
  final int frameWidth;
  final int frameHeight;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameWidth <= 0 || frameHeight <= 0) return;
    final scale = math
        .max(size.width / frameWidth, size.height / frameHeight)
        .toDouble();
    final offsetX = (size.width - frameWidth * scale) / 2;
    final offsetY = (size.height - frameHeight * scale) / 2;

    Offset mapPoint(Offset point) {
      final x = mirror ? frameWidth * (1 - point.dx) : frameWidth * point.dx;
      return Offset(
        offsetX + x * scale,
        offsetY + point.dy * frameHeight * scale,
      );
    }

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.65)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final linePaint = Paint()
      ..color = const Color(0xFF39F5C8)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    final jointShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.7);
    final jointPaint = Paint()..color = const Color(0xFFFFD740);

    for (final hand in hands) {
      if (hand.length != 21) continue;

      for (final (start, end) in _connections) {
        final first = mapPoint(hand[start]);
        final second = mapPoint(hand[end]);
        canvas.drawLine(first, second, shadowPaint);
        canvas.drawLine(first, second, linePaint);
      }

      for (var index = 0; index < hand.length; index++) {
        final point = mapPoint(hand[index]);
        final radius = index == 0 ? 5.5 : 4.0;
        canvas.drawCircle(point, radius + 1.5, jointShadowPaint);
        canvas.drawCircle(point, radius, jointPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandLandmarkPainter oldDelegate) =>
      hands != oldDelegate.hands ||
      frameWidth != oldDelegate.frameWidth ||
      frameHeight != oldDelegate.frameHeight ||
      mirror != oldDelegate.mirror;
}
