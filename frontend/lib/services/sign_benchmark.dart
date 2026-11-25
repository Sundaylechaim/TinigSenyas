/// Lightweight, local-only measurements for the Android sign-recognition UI.
///
/// This intentionally does not identify a device or transmit data. The tester
/// supplies the device/build and conditions in the report so that those details
/// can be checked before results are compared.
class SignBenchmark {
  final List<DateTime> _frameTimes = [];
  final List<BenchmarkSample> _samples = [];
  DateTime? _runStartedAt;
  DateTime? _completionMarkedAt;

  bool get isRunning => _runStartedAt != null;
  bool get awaitingResult => _completionMarkedAt != null;
  int get sampleCount => _samples.length;
  List<BenchmarkSample> get samples => List.unmodifiable(_samples);

  void start(DateTime now) {
    _runStartedAt = now;
    _completionMarkedAt = null;
    _frameTimes.clear();
    _samples.clear();
  }

  void stop() {
    _runStartedAt = null;
    _completionMarkedAt = null;
  }

  void recordCameraFrame(DateTime now) {
    if (!isRunning) return;
    _frameTimes.add(now);
    // Ten seconds is enough for a responsive sustained-FPS readout and keeps
    // the benchmark memory footprint constant during long sessions.
    final cutoff = now.subtract(const Duration(seconds: 10));
    _frameTimes.removeWhere((time) => time.isBefore(cutoff));
  }

  /// Call this at the instant the signer completes the gesture. The next result
  /// that is painted by Flutter is the end point of the latency measurement.
  bool markSignCompletion(DateTime now) {
    if (!isRunning || awaitingResult) return false;
    _completionMarkedAt = now;
    return true;
  }

  void recordDisplayedResult({required String label, required DateTime now}) {
    final completedAt = _completionMarkedAt;
    if (completedAt == null) return;
    _completionMarkedAt = null;
    _samples.add(
      BenchmarkSample(label: label, completedAt: completedAt, displayedAt: now),
    );
  }

  double get sustainedFps {
    if (_frameTimes.length < 2) return 0;
    final elapsedMs =
        _frameTimes.last.difference(_frameTimes.first).inMicroseconds / 1000.0;
    if (elapsedMs <= 0) return 0;
    return (_frameTimes.length - 1) * 1000 / elapsedMs;
  }

  int? get medianLatencyMs => _percentile(0.5);
  int? get p95LatencyMs => _percentile(0.95);

  int? _percentile(double percentile) {
    if (_samples.isEmpty) return null;
    final values = _samples.map((sample) => sample.latencyMs).toList()..sort();
    final index = ((values.length - 1) * percentile).ceil();
    return values[index];
  }

  String localReport({
    required String device,
    required String androidVersion,
    required String conditions,
  }) {
    final buffer = StringBuffer()
      ..writeln('TinigSenyas Android sign-recognition benchmark')
      ..writeln(
        'Device: ${device.trim().isEmpty ? "not recorded" : device.trim()}',
      )
      ..writeln(
        'Android: ${androidVersion.trim().isEmpty ? "not recorded" : androidVersion.trim()}',
      )
      ..writeln(
        'Conditions: ${conditions.trim().isEmpty ? "not recorded" : conditions.trim()}',
      )
      ..writeln('Samples: $sampleCount')
      ..writeln(
        'Sustained camera FPS (last 10 s): ${sustainedFps.toStringAsFixed(1)}',
      )
      ..writeln(
        'Completion-to-displayed-result median: ${medianLatencyMs ?? "n/a"} ms',
      )
      ..writeln(
        'Completion-to-displayed-result p95: ${p95LatencyMs ?? "n/a"} ms',
      )
      ..writeln('Local only: no benchmark data was uploaded.')
      ..writeln('Trials (completion ISO, displayed ISO, label, latency ms):');
    for (final sample in _samples) {
      buffer.writeln(
        '${sample.completedAt.toIso8601String()}, ${sample.displayedAt.toIso8601String()}, ${sample.label}, ${sample.latencyMs}',
      );
    }
    return buffer.toString();
  }
}

class BenchmarkSample {
  const BenchmarkSample({
    required this.label,
    required this.completedAt,
    required this.displayedAt,
  });

  final String label;
  final DateTime completedAt;
  final DateTime displayedAt;
  int get latencyMs => displayedAt.difference(completedAt).inMilliseconds;
}
