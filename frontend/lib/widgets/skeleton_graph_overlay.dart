import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/recognition_graph_frame.dart';

/// Displays MediaPipe pose plus hand joints on the same cover-cropped camera
/// geometry used by the hand-only overlay.
class SkeletonGraphOverlay extends StatelessWidget {
  const SkeletonGraphOverlay({
    required this.frame,
    required this.frameWidth,
    required this.frameHeight,
    super.key,
  });

  final RecognitionGraphFrame? frame;
  final int frameWidth;
  final int frameHeight;

  @override
  Widget build(BuildContext context) {
    if (frame == null || frameWidth <= 0 || frameHeight <= 0) {
      return const SizedBox.expand();
    }
    return IgnorePointer(
      child: CustomPaint(
        painter: _SkeletonGraphPainter(frame!, frameWidth, frameHeight),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SkeletonGraphPainter extends CustomPainter {
  _SkeletonGraphPainter(this.frame, this.frameWidth, this.frameHeight);
  final RecognitionGraphFrame frame;
  final int frameWidth;
  final int frameHeight;

  static const _poseEdges = <(int, int)>[
    (11, 12),
    (11, 13),
    (13, 15),
    (15, 17),
    (15, 19),
    (15, 21),
    (17, 19),
    (12, 14),
    (14, 16),
    (16, 18),
    (16, 20),
    (16, 22),
    (18, 20),
    (11, 23),
    (12, 24),
    (23, 24),
    (23, 25),
    (25, 27),
    (27, 29),
    (29, 31),
    (27, 31),
    (24, 26),
    (26, 28),
    (28, 30),
    (30, 32),
    (28, 32),
  ];
  static const _handEdges = <(int, int)>[
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

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math
        .max(size.width / frameWidth, size.height / frameHeight)
        .toDouble();
    final ox = (size.width - frameWidth * scale) / 2;
    final oy = (size.height - frameHeight * scale) / 2;
    Offset map(Offset p) =>
        Offset(ox + p.dx * frameWidth * scale, oy + p.dy * frameHeight * scale);
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: .65)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final poseLine = Paint()
      ..color = const Color(0xFF60A5FA)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final handLine = Paint()
      ..color = const Color(0xFF39F5C8)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final node = Paint()..color = const Color(0xFFFFD740);
    if (frame.pose.length >= 33) {
      for (final (a, b) in _poseEdges) {
        final p = map(frame.pose[a]), q = map(frame.pose[b]);
        canvas.drawLine(p, q, shadow);
        canvas.drawLine(p, q, poseLine);
      }
      for (var i = 11; i < 33; i++) {
        canvas.drawCircle(map(frame.pose[i]), 3.5, node);
      }
    }
    for (final hand in frame.hands) {
      if (hand.length < 21) continue;
      for (final (a, b) in _handEdges) {
        final p = map(hand[a]), q = map(hand[b]);
        canvas.drawLine(p, q, shadow);
        canvas.drawLine(p, q, handLine);
      }
      for (final point in hand) {
        canvas.drawCircle(map(point), 3.5, node);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SkeletonGraphPainter old) =>
      frame != old.frame ||
      frameWidth != old.frameWidth ||
      frameHeight != old.frameHeight;
}
