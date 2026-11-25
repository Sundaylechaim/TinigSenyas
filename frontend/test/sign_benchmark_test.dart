import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/services/sign_benchmark.dart';

void main() {
  test(
    'records the next displayed result after completion and reports percentiles',
    () {
      final benchmark = SignBenchmark();
      final start = DateTime(2026, 1, 1, 12);
      benchmark.start(start);

      for (var i = 0; i < 11; i++) {
        benchmark.recordCameraFrame(start.add(Duration(seconds: i)));
      }
      benchmark.markSignCompletion(start.add(const Duration(seconds: 12)));
      benchmark.recordDisplayedResult(
        label: 'Hello',
        now: start.add(const Duration(milliseconds: 12120)),
      );

      expect(benchmark.sampleCount, 1);
      expect(benchmark.samples.single.latencyMs, 120);
      expect(benchmark.medianLatencyMs, 120);
      expect(benchmark.p95LatencyMs, 120);
      expect(benchmark.sustainedFps, closeTo(1, 0.01));
      expect(
        benchmark.localReport(
          device: 'Pixel test',
          androidVersion: 'Android 14',
          conditions: 'indoor',
        ),
        contains('Local only: no benchmark data was uploaded.'),
      );
    },
  );

  test('keeps only a ten-second camera frame window', () {
    final benchmark = SignBenchmark();
    final start = DateTime(2026, 1, 1);
    benchmark.start(start);
    benchmark.recordCameraFrame(start);
    benchmark.recordCameraFrame(start.add(const Duration(seconds: 11)));

    expect(benchmark.sustainedFps, 0);
  });
}
