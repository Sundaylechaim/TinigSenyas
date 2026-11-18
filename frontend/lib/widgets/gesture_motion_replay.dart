import 'dart:math' as math;

import 'package:flutter/material.dart';

class GestureMotionReplay extends StatefulWidget {
  const GestureMotionReplay({
    required this.frames,
    this.sourceAspectRatio = 1,
    super.key,
  });

  final List<List<List<Offset>>> frames;
  final double sourceAspectRatio;

  @override
  State<GestureMotionReplay> createState() => _GestureMotionReplayState();
}

class _GestureMotionReplayState extends State<GestureMotionReplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1450),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant GestureMotionReplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frames, widget.frames)) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.frames.isEmpty) return const SizedBox.shrink();

    return Semantics(
      label: 'Animated replay of the signer’s tracked hand movement',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final position = _controller.value * (widget.frames.length - 1);
          final index = position.floor();
          final nextIndex = math.min(index + 1, widget.frames.length - 1);
          return CustomPaint(
            painter: _GestureMotionPainter(
              firstFrame: widget.frames[index],
              secondFrame: widget.frames[nextIndex],
              frameProgress: position - index,
              sourceAspectRatio: widget.sourceAspectRatio,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _GestureMotionPainter extends CustomPainter {
  const _GestureMotionPainter({
    required this.firstFrame,
    required this.secondFrame,
    required this.frameProgress,
    required this.sourceAspectRatio,
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

  final List<List<Offset>> firstFrame;
  final List<List<Offset>> secondFrame;
  final double frameProgress;
  final double sourceAspectRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final ratio = sourceAspectRatio.isFinite && sourceAspectRatio > 0
        ? sourceAspectRatio
        : 1.0;
    final boxRatio = size.width / size.height;
    final drawSize = ratio > boxRatio
        ? Size(size.width, size.width / ratio)
        : Size(size.height * ratio, size.height);
    final origin = Offset(
      (size.width - drawSize.width) / 2,
      (size.height - drawSize.height) / 2,
    );

    Offset mapPoint(Offset point) => Offset(
      origin.dx + point.dx.clamp(0.0, 1.0).toDouble() * drawSize.width,
      origin.dy + point.dy.clamp(0.0, 1.0).toDouble() * drawSize.height,
    );

    final glowPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.24)
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    final linePaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final jointPaint = Paint()..color = const Color(0xFFFFD166);

    final handCount = math.max(firstFrame.length, secondFrame.length);
    for (var handIndex = 0; handIndex < handCount; handIndex++) {
      final first = handIndex < firstFrame.length
          ? firstFrame[handIndex]
          : const <Offset>[];
      final second = handIndex < secondFrame.length
          ? secondFrame[handIndex]
          : first;
      if (first.length != 21 || second.length != 21) continue;

      Offset pointAt(int landmarkIndex) => mapPoint(
        Offset.lerp(
          first[landmarkIndex],
          second[landmarkIndex],
          frameProgress,
        )!,
      );

      for (final (start, end) in _connections) {
        final firstPoint = pointAt(start);
        final secondPoint = pointAt(end);
        canvas.drawLine(firstPoint, secondPoint, glowPaint);
        canvas.drawLine(firstPoint, secondPoint, linePaint);
      }

      for (var index = 0; index < 21; index++) {
        canvas.drawCircle(pointAt(index), index == 0 ? 4.5 : 3.5, jointPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GestureMotionPainter oldDelegate) =>
      firstFrame != oldDelegate.firstFrame ||
      secondFrame != oldDelegate.secondFrame ||
      frameProgress != oldDelegate.frameProgress ||
      sourceAspectRatio != oldDelegate.sourceAspectRatio;
}
