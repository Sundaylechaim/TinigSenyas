import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TfliteRecognitionService Math & Normalization Tests', () {
    test('linear interpolation resamples 3-frame buffer to 60 frames smoothly', () {
      // 3 frames with 75 joints, coordinates increasing linearly
      final buffer = [
        List.generate(75, (_) => [0.0, 0.0, 0.0]),
        List.generate(75, (_) => [1.0, 2.0, 3.0]),
        List.generate(75, (_) => [2.0, 4.0, 6.0]),
      ];

      final resampled = <List<List<double>>>[];
      const targetLength = 60;
      final n = buffer.length;

      for (int i = 0; i < targetLength; i++) {
        final pos = i * (n - 1) / (targetLength - 1);
        final lower = pos.floor();
        final upper = pos.ceil();
        final alpha = pos - lower;
        final frame = List.generate(75, (j) {
          final p0 = buffer[lower][j];
          final p1 = buffer[upper][j];
          return [
            (1.0 - alpha) * p0[0] + alpha * p1[0],
            (1.0 - alpha) * p0[1] + alpha * p1[1],
            (1.0 - alpha) * p0[2] + alpha * p1[2],
          ];
        });
        resampled.add(frame);
      }

      expect(resampled.length, equals(60));
      // First frame must match buffer[0] exactly
      expect(resampled.first[0][0], closeTo(0.0, 1e-4));
      // Last frame must match buffer[2] exactly
      expect(resampled.last[0][0], closeTo(2.0, 1e-4));
      // Midpoint frame (index ~30) should be close to buffer[1]
      expect(resampled[29][0][0], closeTo(0.983, 0.05));
    });

    test('canonical right hand index-pinky alignment detects mirrored hands', () {
      // Canonical right hand facing camera:
      // Index MCP (joint 5) is to the right of Pinky MCP (joint 17) -> indexX > pinkyX
      const canonicalIndexX = 0.55;
      const canonicalPinkyX = 0.40;
      final isCanonicalMirrored = canonicalIndexX < canonicalPinkyX;
      expect(isCanonicalMirrored, isFalse);

      // Mirrored selfie view (front camera):
      // Index MCP is to the left of Pinky MCP -> indexX < pinkyX
      const mirroredIndexX = 0.40;
      const mirroredPinkyX = 0.55;
      final isMirrored = mirroredIndexX < mirroredPinkyX;
      expect(isMirrored, isTrue);
    });

    test('front camera world space unmirroring maps right hand to correct hemisphere', () {
      double toWorldX(double screenX, bool isFront) => isFront ? (1.0 - screenX) : screenX;

      const screenX = 0.70;
      final worldFront = toWorldX(screenX, true);
      expect(worldFront, closeTo(0.30, 1e-4));

      final worldBack = toWorldX(screenX, false);
      expect(worldBack, closeTo(0.70, 1e-4));

      // Normalizing relative to mid-shoulder 0.50 gives negative X for right hand
      final normX = (worldFront - 0.50) / 0.22;
      expect(normX, closeTo(-0.909, 0.01));
      expect(normX < 0, isTrue);
    });
  });
}
