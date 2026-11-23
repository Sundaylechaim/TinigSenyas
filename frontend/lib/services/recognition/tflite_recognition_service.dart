import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:tinigsenyas/models/sign_result.dart';
import 'recognition_service.dart';

class TfliteRecognitionService implements RecognitionService {
  static const MethodChannel _poseLandmarkerChannel = MethodChannel(
    'tinigsenyas/pose_landmarker',
  );

  final _predictionsController = StreamController<SignResult>.broadcast();
  final _pauseStatusController = StreamController<bool>.broadcast();
  final _landmarkStreamController =
      StreamController<List<List<Offset>>>.broadcast();

  Interpreter? _fslModelInterpreter;
  Interpreter? _alphabetInterpreter;
  Interpreter? _medicalModelInterpreter;
  HandLandmarkerPlugin? _handLandmarker;
  StreamSubscription<List<Hand>>? _handSubscription;
  Completer<List<Hand>>? _pendingHandFrame;
  List<Landmark>? _poseLandmarks;
  DateTime? _poseLandmarksUpdatedAt;
  bool _poseLandmarkerReady = false;
  int _poseFrameCounter = 0;

  List<String> _fslLabels = [];
  List<String> _medicalLabels = [];
  List<String> _alphabetLabels = [];
  static const int _conversationalClassCount = 103;
  static const int _medicalClassCount = 35;
  static const int _alphabetClassCount = 28;

  RecognitionMode _mode = RecognitionMode.auto;
  @override
  RecognitionMode get mode => _mode;
  @override
  set mode(RecognitionMode val) {
    if (_mode == val) return;
    _mode = val;
    _alphaProbHistory.clear();
    _alphaCandidate = null;
    _alphaCandidateCount = 0;
    _alphaEmittedLabel = null;
    _alphaReleaseFrameCount = 0;
    _fslProbHistory.clear();
    _fslCandidate = null;
    _fslCandidateCount = 0;
    _fslEmittedLabel = null;
    _fslReleaseFrameCount = 0;
    _medProbHistory.clear();
    _medCandidate = null;
    _medCandidateCount = 0;
    _medEmittedLabel = null;
    _sequenceBuffer.clear();
    _lastGestureMotionAt = null;
    _motionRouteActive = false;
  }

  Offset? _lastWrist;
  DateTime? _lastWristTimestamp;
  final List<double> _motionHistory = [];
  int _missingHandFrames = 0;
  int _lastTrackedHandCount = 0;
  bool _motionRouteActive = false;

  // Exponential Moving Average (EMA) landmark smoothing
  List<(double, double, double)>? _smoothedPrimaryHand;
  List<(double, double, double)>? _smoothedSecondaryHand;
  static const double _handSmoothAlpha = 0.65;
  static const int _trackingGraceFrames = 2;

  // Rolling Softmax Probability Distribution Smoothing
  final List<List<double>> _alphaProbHistory = [];
  final List<List<double>> _fslProbHistory = [];
  final List<List<double>> _medProbHistory = [];
  static const int _alphaProbHistorySize = 5;
  static const int _probHistorySize = 5;
  static const double _paperMinimumConfidence = 0.60;
  static const double _paperMinimumMargin = 0.12;
  static const double _paperHighConfidence = 0.75;
  static const Duration _gestureSettleWindow = Duration(milliseconds: 900);

  bool _isInitialized = false;
  bool _isRunning = false;
  bool _isPaused = false;
  bool _isProcessingFrame = false;

  // Frame sequence buffer for 60-frame ST-GCN conversational model
  final List<List<List<double>>> _sequenceBuffer = [];
  static const int _targetSequenceLength = 60;
  static const int _totalJoints = 75;
  (double, double, double) _poseNormalizationCenter = (0.5, 0.5, 0.0);
  double _poseNormalizationScale = 0.20;

  // Debouncing / Stability state
  String? _lastEmittedLabel;
  DateTime _lastEmittedTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? _alphaCandidate;
  int _alphaCandidateCount = 0;
  String? _alphaEmittedLabel;
  int _alphaReleaseFrameCount = 0;
  String? _fslCandidate;
  int _fslCandidateCount = 0;
  String? _fslEmittedLabel;
  int _fslReleaseFrameCount = 0;
  String? _medCandidate;
  int _medCandidateCount = 0;
  String? _medEmittedLabel;

  // Trajectory tracking for dynamic fingerspelled letter 'J'
  final List<(double, double, bool)> _jTrajectory = [];
  int _jCooldown = 0;

  // Natural Rest Zone state
  bool _manualPaused = false;
  int _restZoneFrameCount = 0;
  static const int _restZoneThreshold = 15; // ~500ms of sustained hands at rest
  DateTime? _lastGestureMotionAt;

  bool _passesPaperConfidenceGate(double top1, double top2) =>
      top1 >= _paperHighConfidence ||
      (top1 >= _paperMinimumConfidence && top1 - top2 >= _paperMinimumMargin);

  bool get _hasRecentGestureActivity =>
      _lastGestureMotionAt != null &&
      DateTime.now().difference(_lastGestureMotionAt!) <= _gestureSettleWindow;

  @override
  bool get isModelReady {
    if (!_isInitialized || _handLandmarker == null) return false;
    final alphabetReady =
        _alphabetInterpreter != null &&
        _alphabetLabels.length == _alphabetClassCount;
    final phraseReady =
        _poseLandmarkerReady &&
        _fslModelInterpreter != null &&
        _fslLabels.length == _conversationalClassCount;
    final medicalReady =
        _poseLandmarkerReady &&
        _medicalModelInterpreter != null &&
        _medicalLabels.length == _medicalClassCount;
    return switch (_mode) {
      RecognitionMode.alphabet => alphabetReady,
      RecognitionMode.phrases => phraseReady,
      RecognitionMode.medical => medicalReady,
      RecognitionMode.auto => alphabetReady && phraseReady && medicalReady,
    };
  }

  bool _matchesShape(List<int> actual, List<int> expected) =>
      actual.length == expected.length &&
      List.generate(
        actual.length,
        (index) => actual[index] == expected[index],
      ).every((matches) => matches);

  Future<bool> _canUseLocalModelOverrides(Directory? modelsDir) async {
    if (modelsDir == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final installedVersion = prefs.getString('model_version');
      if (installedVersion == null || installedVersion.trim().isEmpty) {
        return false;
      }

      final bundledVersion = (await rootBundle.loadString(
        'assets/model/version.txt',
      )).trim();
      final bundledParts = bundledVersion
          .replaceAll(RegExp(r'[^0-9.]'), '')
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
      final installedParts = installedVersion
          .replaceAll(RegExp(r'[^0-9.]'), '')
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();

      for (var index = 0; index < 3; index++) {
        final bundled = index < bundledParts.length ? bundledParts[index] : 0;
        final installed = index < installedParts.length
            ? installedParts[index]
            : 0;
        if (bundled > installed) return false;
        if (bundled < installed) return true;
      }
      return true;
    } catch (error) {
      debugPrint(
        '[TfliteRecognitionService] Could not verify local model version: $error',
      );
      return false;
    }
  }

  Future<List<String>> _loadLabels({
    required File? localFile,
    required String assetPath,
    required int expectedCount,
    required String modelName,
  }) async {
    if (localFile != null && await localFile.exists()) {
      try {
        final localLabels = (await localFile.readAsString())
            .split(RegExp(r'\r?\n'))
            .map((label) => label.trim())
            .where((label) => label.isNotEmpty)
            .toList();
        if (localLabels.length == expectedCount) return localLabels;
        debugPrint(
          '[TfliteRecognitionService] Ignoring $modelName labels: '
          'expected $expectedCount, found ${localLabels.length}.',
        );
      } catch (error) {
        debugPrint(
          '[TfliteRecognitionService] Could not read local $modelName labels: $error',
        );
      }
    }

    try {
      final bundledLabels = (await rootBundle.loadString(assetPath))
          .split(RegExp(r'\r?\n'))
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toList();
      if (bundledLabels.length == expectedCount) return bundledLabels;
      debugPrint(
        '[TfliteRecognitionService] Invalid bundled $modelName labels: '
        'expected $expectedCount, found ${bundledLabels.length}.',
      );
    } catch (error) {
      debugPrint(
        '[TfliteRecognitionService] Could not load bundled $modelName labels: $error',
      );
    }
    return const [];
  }

  Future<Interpreter?> _loadValidatedInterpreter({
    required String modelName,
    required File? localFile,
    required String assetPath,
    required List<int> inputShape,
    required List<int> outputShape,
    required InterpreterOptions options,
  }) async {
    final loaders = <Future<Interpreter> Function()>[];
    if (localFile != null && await localFile.exists()) {
      loaders.add(
        () async => Interpreter.fromFile(localFile, options: options),
      );
    }
    loaders.add(() => Interpreter.fromAsset(assetPath, options: options));

    for (final load in loaders) {
      Interpreter? interpreter;
      try {
        interpreter = await load();
        interpreter.allocateTensors();
        final actualInput = interpreter.getInputTensor(0).shape;
        final actualOutput = interpreter.getOutputTensor(0).shape;
        if (!_matchesShape(actualInput, inputShape) ||
            !_matchesShape(actualOutput, outputShape)) {
          throw StateError(
            '$modelName tensor mismatch: input $actualInput, output $actualOutput.',
          );
        }
        debugPrint(
          '[TfliteRecognitionService] $modelName connected: '
          '$actualInput -> $actualOutput.',
        );
        return interpreter;
      } catch (error) {
        interpreter?.close();
        debugPrint(
          '[TfliteRecognitionService] $modelName load failed; trying next source: $error',
        );
      }
    }
    return null;
  }

  @override
  bool get isPaused => _isPaused;

  @override
  void setPaused(bool value) {
    _manualPaused = value;
    _isPaused = value;
    _pauseStatusController.add(value);
    if (value) {
      _resetTrackingState();
    }
  }

  @override
  Stream<bool>? get pauseStatus => _pauseStatusController.stream;

  @override
  Stream<List<List<Offset>>>? get landmarkPointsStream =>
      _landmarkStreamController.stream;

  @override
  Stream<SignResult> get predictions => _predictionsController.stream;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await reloadModels();

      if (!kIsWeb && Platform.isAndroid) {
        try {
          _poseLandmarkerReady =
              await _poseLandmarkerChannel.invokeMethod<bool>('initialize') ??
              false;
        } catch (e) {
          _poseLandmarkerReady = false;
          debugPrint(
            '[TfliteRecognitionService] Pose Landmarker unavailable: $e',
          );
        }

        try {
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.5,
            delegate: HandLandmarkerDelegate.gpu,
          );
        } catch (e) {
          debugPrint(
            '[TfliteRecognitionService] GPU delegate failed, trying CPU: $e',
          );
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.5,
            delegate: HandLandmarkerDelegate.cpu,
          );
        }
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Initialization error: $e');
      _isInitialized = true; // allow retry
    }
  }

  /// Hot-reloads models from local storage (Google Maps style OTA update) or bundled assets
  @override
  Future<void> reloadModels() async {
    try {
      Directory? modelsDir;
      if (!kIsWeb) {
        final appDir = await getApplicationDocumentsDirectory();
        modelsDir = Directory(p.join(appDir.path, 'models'));
      }
      final useLocalOverrides = await _canUseLocalModelOverrides(modelsDir);
      if (modelsDir != null && !useLocalOverrides) {
        debugPrint(
          '[TfliteRecognitionService] Ignoring local model overrides because '
          'they do not have a version at least as new as the bundled models.',
        );
      }

      // Each model is loaded and shape-checked independently. If an OTA model
      // is incompatible, fall back to the bundled model instead of silently
      // leaving a selected recognition mode disconnected.
      final localLabelsFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'labels.txt'))
          : null;
      _fslLabels = await _loadLabels(
        localFile: localLabelsFile,
        assetPath: 'assets/model/labels.txt',
        expectedCount: _conversationalClassCount,
        modelName: 'conversational',
      );

      final localMedLabelsFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'medical_labels.txt'))
          : null;
      _medicalLabels = await _loadLabels(
        localFile: localMedLabelsFile,
        assetPath: 'assets/model/medical_labels.txt',
        expectedCount: _medicalClassCount,
        modelName: 'medical',
      );

      final localAlphabetLabelsFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'alphabet_labels.txt'))
          : null;
      _alphabetLabels = await _loadLabels(
        localFile: localAlphabetLabelsFile,
        assetPath: 'assets/model/alphabet_labels.txt',
        expectedCount: _alphabetClassCount,
        modelName: 'alphabet',
      );

      _alphabetInterpreter?.close();
      _alphabetInterpreter = null;
      final localAlphaFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_alphabet.tflite'))
          : null;
      _alphabetInterpreter = await _loadValidatedInterpreter(
        modelName: 'alphabet',
        localFile: localAlphaFile,
        assetPath: 'assets/model/fsl_alphabet.tflite',
        inputShape: const [1, 63],
        outputShape: const [1, _alphabetClassCount],
        options: InterpreterOptions()..threads = 2,
      );

      _fslModelInterpreter?.close();
      _fslModelInterpreter = null;
      final localModelFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_model.tflite'))
          : null;
      _fslModelInterpreter = await _loadValidatedInterpreter(
        modelName: 'conversational ST-GCN',
        localFile: localModelFile,
        assetPath: 'assets/model/fsl_model.tflite',
        inputShape: const [1, 60, 75, 3],
        outputShape: [1, _conversationalClassCount],
        options: InterpreterOptions()..threads = 4,
      );

      _medicalModelInterpreter?.close();
      _medicalModelInterpreter = null;
      final localMedModelFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_medical.tflite'))
          : null;
      _medicalModelInterpreter = await _loadValidatedInterpreter(
        modelName: 'medical ST-GCN',
        localFile: localMedModelFile,
        assetPath: 'assets/model/fsl_medical.tflite',
        inputShape: const [1, 60, 75, 3],
        outputShape: [1, _medicalClassCount],
        options: InterpreterOptions()..threads = 4,
      );

      debugPrint(
        '[TfliteRecognitionService] Model connection status: '
        'alphabet=${_alphabetInterpreter != null}, '
        'conversational=${_fslModelInterpreter != null}, '
        'medical=${_medicalModelInterpreter != null}.',
      );
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Error reloading models: $e');
    }
  }

  @override
  Future<void> start() async {
    if (!_isInitialized) {
      await initialize();
    }
    _isRunning = true;
    _handSubscription?.cancel();
    if (_handLandmarker != null) {
      _handSubscription = _handLandmarker!.landmarkStream.listen(
        (hands) {
          final pending = _pendingHandFrame;
          if (pending != null && !pending.isCompleted) {
            pending.complete(hands);
          }
        },
        onError: (err) {
          debugPrint(
            '[TfliteRecognitionService] Landmarker stream error: $err',
          );
          final pending = _pendingHandFrame;
          if (pending != null && !pending.isCompleted) {
            pending.complete(const []);
          }
        },
      );
    }
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _handSubscription?.cancel();
    _handSubscription = null;
    _pendingHandFrame = null;
    _poseLandmarks = null;
    _poseLandmarksUpdatedAt = null;
    _poseFrameCounter = 0;
    _resetTrackingState();
  }

  int _sensorOrientation = 90;
  bool _isFrontCamera = true;

  @override
  Future<void> processFrame(
    CameraImage image, {
    int? sensorOrientation,
    bool? isFrontCamera,
  }) async {
    if (!_isRunning || !_isInitialized) return;
    if (_isProcessingFrame) return;

    final nextSensorOrientation = sensorOrientation ?? _sensorOrientation;
    final nextIsFrontCamera = isFrontCamera ?? _isFrontCamera;
    if (nextSensorOrientation != _sensorOrientation ||
        nextIsFrontCamera != _isFrontCamera) {
      _sensorOrientation = nextSensorOrientation;
      _isFrontCamera = nextIsFrontCamera;
      _poseLandmarks = null;
      _poseLandmarksUpdatedAt = null;
      _poseFrameCounter = 0;
      _clearTemporalTrackingData();
      _lastTrackedHandCount = 0;
      _missingHandFrames = 0;
      _restZoneFrameCount = 0;
    }

    final handLandmarker = _handLandmarker;
    if (handLandmarker == null) return;

    _isProcessingFrame = true;
    try {
      _poseFrameCounter++;
      if (_poseLandmarkerReady && _poseFrameCounter % 4 == 1) {
        final detectedPose = await _detectPoseLandmarks(image);
        _poseLandmarks = detectedPose;
        _poseLandmarksUpdatedAt = detectedPose == null ? null : DateTime.now();
      } else if (_poseLandmarksUpdatedAt != null &&
          DateTime.now().difference(_poseLandmarksUpdatedAt!) >
              const Duration(milliseconds: 600)) {
        _poseLandmarks = null;
        _poseLandmarksUpdatedAt = null;
      }

      final pending = Completer<List<Hand>>();
      _pendingHandFrame = pending;
      handLandmarker.processFrame(image, _sensorOrientation);
      final hands = await pending.future.timeout(
        const Duration(milliseconds: 700),
        onTimeout: () {
          debugPrint(
            '[TfliteRecognitionService] Hand Landmarker frame timed out.',
          );
          return const <Hand>[];
        },
      );
      if (identical(_pendingHandFrame, pending)) _pendingHandFrame = null;
      _handleDetectedHands(hands, poseLandmarks: _poseLandmarks);
    } catch (e) {
      debugPrint('[TfliteRecognitionService] processFrame error: $e');
    } finally {
      _pendingHandFrame = null;
      _isProcessingFrame = false;
    }
  }

  Future<List<Landmark>?> _detectPoseLandmarks(CameraImage image) async {
    if (image.planes.length < 3) return null;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    try {
      final raw = await _poseLandmarkerChannel
          .invokeMethod<List<dynamic>>('detect', {
            'yPlane': yPlane.bytes,
            'uPlane': uPlane.bytes,
            'vPlane': vPlane.bytes,
            'width': image.width,
            'height': image.height,
            'yRowStride': yPlane.bytesPerRow,
            'uvRowStride': uPlane.bytesPerRow,
            'uvPixelStride': uPlane.bytesPerPixel ?? 1,
            'rotation': _sensorOrientation,
            'timestampMs': DateTime.now().millisecondsSinceEpoch,
          });
      if (raw == null || raw.length != 33) return null;
      final pose = <Landmark>[];
      for (final point in raw) {
        if (point is! Map) return null;
        final x = (point['x'] as num?)?.toDouble();
        final y = (point['y'] as num?)?.toDouble();
        final z = (point['z'] as num?)?.toDouble();
        if (x == null ||
            y == null ||
            z == null ||
            !x.isFinite ||
            !y.isFinite ||
            !z.isFinite) {
          return null;
        }
        pose.add(Landmark(x, y, z));
      }
      return pose;
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Pose inference failed: $e');
      return null;
    }
  }

  /// Transforms raw unrotated sensor coordinates from MediaPipe into canonical upright portrait screen coordinates [0..1]
  (double x, double y, double z) _transformLandmark(Landmark lm) {
    double nx;
    double ny;

    if (_sensorOrientation == 270) {
      if (_isFrontCamera) {
        nx = 1.0 - lm.y;
        ny = 1.0 - lm.x;
      } else {
        nx = lm.y;
        ny = 1.0 - lm.x;
      }
    } else if (_sensorOrientation == 90) {
      if (_isFrontCamera) {
        nx = lm.y;
        ny = lm.x;
      } else {
        nx = 1.0 - lm.y;
        ny = lm.x;
      }
    } else if (_sensorOrientation == 180) {
      nx = _isFrontCamera ? lm.x : 1.0 - lm.x;
      ny = 1.0 - lm.y;
    } else {
      // 0 degrees (desktop / standard webcam)
      nx = _isFrontCamera ? 1.0 - lm.x : lm.x;
      ny = lm.y;
    }

    return (nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0), lm.z);
  }

  /// Applies exponential moving average (EMA) smoothing across consecutive video frames
  List<(double, double, double)> _applyEmaSmoothing(
    List<(double, double, double)> current,
    List<(double, double, double)>? previous,
  ) {
    if (previous == null || previous.length != current.length) {
      return List<(double, double, double)>.from(current);
    }
    final result = <(double, double, double)>[];
    for (int i = 0; i < current.length; i++) {
      final cx = current[i].$1;
      final cy = current[i].$2;
      final cz = current[i].$3;
      final px = previous[i].$1;
      final py = previous[i].$2;
      final pz = previous[i].$3;
      result.add((
        _handSmoothAlpha * cx + (1.0 - _handSmoothAlpha) * px,
        _handSmoothAlpha * cy + (1.0 - _handSmoothAlpha) * py,
        _handSmoothAlpha * cz + (1.0 - _handSmoothAlpha) * pz,
      ));
    }
    return result;
  }

  double _wristDistance(
    List<(double, double, double)> first,
    List<(double, double, double)> second,
  ) {
    if (first.isEmpty || second.isEmpty) return double.infinity;
    final dx = first[0].$1 - second[0].$1;
    final dy = first[0].$2 - second[0].$2;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Match detections to the previous frame by wrist position. The installed
  /// MediaPipe plugin does not expose handedness or tracking IDs.
  List<List<(double, double, double)>> _orderHandsForTracking(
    List<List<(double, double, double)>> hands,
  ) {
    if (hands.length < 2) return hands;
    final ordered = List<List<(double, double, double)>>.from(hands);
    final previousPrimary = _smoothedPrimaryHand;
    final previousSecondary = _smoothedSecondaryHand;

    if (previousPrimary != null && previousSecondary != null) {
      final direct =
          _wristDistance(ordered[0], previousPrimary) +
          _wristDistance(ordered[1], previousSecondary);
      final crossed =
          _wristDistance(ordered[1], previousPrimary) +
          _wristDistance(ordered[0], previousSecondary);
      return crossed < direct ? [ordered[1], ordered[0]] : ordered;
    }

    if (previousPrimary != null &&
        _wristDistance(ordered[1], previousPrimary) <
            _wristDistance(ordered[0], previousPrimary)) {
      return [ordered[1], ordered[0]];
    }

    ordered.sort((a, b) => a[0].$1.compareTo(b[0].$1));
    return ordered;
  }

  void _clearTemporalTrackingData() {
    _sequenceBuffer.clear();
    _poseNormalizationCenter = (0.5, 0.5, 0.0);
    _poseNormalizationScale = 0.20;
    _alphaProbHistory.clear();
    _fslProbHistory.clear();
    _medProbHistory.clear();
    _motionHistory.clear();
    _smoothedPrimaryHand = null;
    _smoothedSecondaryHand = null;
    _lastWrist = null;
    _lastWristTimestamp = null;
    _motionRouteActive = false;
    _alphaCandidate = null;
    _alphaCandidateCount = 0;
    _alphaEmittedLabel = null;
    _alphaReleaseFrameCount = 0;
    _fslCandidate = null;
    _fslCandidateCount = 0;
    _fslEmittedLabel = null;
    _fslReleaseFrameCount = 0;
    _medCandidate = null;
    _medCandidateCount = 0;
    _medEmittedLabel = null;
    _lastGestureMotionAt = null;
    _jTrajectory.clear();
  }

  void _resetTrackingState() {
    _clearTemporalTrackingData();
    _lastTrackedHandCount = 0;
    _missingHandFrames = 0;
    _restZoneFrameCount = 0;
  }

  void _handleDetectedHands(
    List<Hand> hands, {
    required List<Landmark>? poseLandmarks,
  }) {
    if (!_isRunning) return;

    final now = DateTime.now();
    if (_lastWristTimestamp != null &&
        now.difference(_lastWristTimestamp!) >
            const Duration(milliseconds: 250)) {
      // Avoid blending a reacquired hand into a stale position or sequence.
      _clearTemporalTrackingData();
      _lastTrackedHandCount = 0;
      _missingHandFrames = 0;
      _restZoneFrameCount = 0;
    }

    // 1. Transform valid detections and keep left/right track order stable.
    final transformedHands = _orderHandsForTracking(
      hands
          .where((hand) => hand.landmarks.length >= 21)
          .map((hand) => hand.landmarks.map(_transformLandmark).toList())
          .toList(),
    );

    if (transformedHands.isEmpty) {
      _missingHandFrames++;
      if (_missingHandFrames == _trackingGraceFrames + 1) {
        _landmarkStreamController.add([]);
        _clearTemporalTrackingData();
        _lastTrackedHandCount = 0;
      }
      if (_missingHandFrames > _trackingGraceFrames) {
        _restZoneFrameCount++;
        if (_restZoneFrameCount >= _restZoneThreshold && !_manualPaused) {
          if (!_isPaused) {
            _isPaused = true;
            _pauseStatusController.add(true);
          }
        }
      }
      return;
    }

    _missingHandFrames = 0;

    // A one/two-hand transition changes the input topology. Start a fresh
    // temporal window instead of mixing those different inputs together.
    if (_lastTrackedHandCount != 0 &&
        _lastTrackedHandCount != transformedHands.length) {
      _sequenceBuffer.clear();
      _alphaProbHistory.clear();
      _fslProbHistory.clear();
      _medProbHistory.clear();
      _motionHistory.clear();
      _lastWrist = null;
      _lastWristTimestamp = null;
      _motionRouteActive = false;
      _alphaCandidate = null;
      _alphaCandidateCount = 0;
      _alphaEmittedLabel = null;
      _alphaReleaseFrameCount = 0;
      _fslCandidate = null;
      _fslCandidateCount = 0;
      _fslEmittedLabel = null;
      _fslReleaseFrameCount = 0;
      _medCandidate = null;
      _medCandidateCount = 0;
      _medEmittedLabel = null;
    }
    _lastTrackedHandCount = transformedHands.length;

    // Apply EMA smoothing to eliminate camera frame micro-jitter
    var previousForPrimary = _smoothedPrimaryHand;
    if (transformedHands.length == 1 &&
        previousForPrimary != null &&
        _smoothedSecondaryHand != null &&
        _wristDistance(transformedHands.first, _smoothedSecondaryHand!) <
            _wristDistance(transformedHands.first, previousForPrimary)) {
      previousForPrimary = _smoothedSecondaryHand;
    }
    final smoothedPrimary = _applyEmaSmoothing(
      transformedHands.first,
      previousForPrimary,
    );
    _smoothedPrimaryHand = smoothedPrimary;
    final List<(double, double, double)>? smoothedSecondary;
    if (transformedHands.length > 1 && transformedHands[1].length >= 21) {
      smoothedSecondary = _applyEmaSmoothing(
        transformedHands[1],
        _smoothedSecondaryHand,
      );
      _smoothedSecondaryHand = smoothedSecondary;
    } else {
      _smoothedSecondaryHand = null;
      smoothedSecondary = null;
    }
    final smoothedHands = [smoothedPrimary, ?smoothedSecondary];

    // Show the same filtered coordinates used for inference, reducing visual
    // jitter in the user's live hand-tracking overlay.
    _landmarkStreamController.add(
      smoothedHands
          .map((hand) => hand.map((pt) => Offset(pt.$1, pt.$2)).toList())
          .toList(),
    );

    // 3. Natural Rest Zone Check:
    // Check if hands have dropped below active signing zone (wrist y >= 0.82)
    final bool allHandsRestingLow = smoothedHands.every((hand) {
      if (hand.isEmpty) return true;
      final wristY = hand[0].$2;
      return wristY >= 0.82;
    });

    if (allHandsRestingLow) {
      _restZoneFrameCount++;
      if (_restZoneFrameCount >= _restZoneThreshold) {
        if (!_isPaused && !_manualPaused) {
          _isPaused = true;
          _pauseStatusController.add(true);
        }
        _sequenceBuffer.clear();
        _alphaProbHistory.clear();
        _fslProbHistory.clear();
        _medProbHistory.clear();
        _smoothedPrimaryHand = null;
        _smoothedSecondaryHand = null;
        _motionHistory.clear();
        _lastWrist = null;
        _lastWristTimestamp = null;
        _motionRouteActive = false;
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaEmittedLabel = null;
        _alphaReleaseFrameCount = 0;
        _fslCandidate = null;
        _fslCandidateCount = 0;
        _fslEmittedLabel = null;
        _fslReleaseFrameCount = 0;
        _medCandidate = null;
        _medCandidateCount = 0;
        _medEmittedLabel = null;
        _lastGestureMotionAt = null;
      }
      return; // Skip inference while hands are resting
    } else {
      // Hands are raised in active signing space:
      _restZoneFrameCount = 0;
      if (_isPaused && !_manualPaused) {
        _isPaused = false;
        _pauseStatusController.add(false);
      }
    }

    if (_isPaused) {
      return;
    }

    // 4. Compute Kinetic Hand Motion
    final wrist = smoothedPrimary[0];
    double currentMotion = 0.0;
    if (_lastWrist != null && _lastWristTimestamp != null) {
      final dx = wrist.$1 - _lastWrist!.dx;
      final dy = wrist.$2 - _lastWrist!.dy;
      final elapsedSeconds =
          now.difference(_lastWristTimestamp!).inMicroseconds / 1000000.0;
      if (elapsedSeconds > 0 && elapsedSeconds <= 0.25) {
        // Normalize to a 30 fps-equivalent displacement so device frame rate
        // does not determine whether the motion router selects alphabet or ST-GCN.
        currentMotion = (math.sqrt(dx * dx + dy * dy) / (30 * elapsedSeconds))
            .clamp(0.0, 0.15)
            .toDouble();
      } else if (elapsedSeconds > 0.25) {
        _motionHistory.clear();
        _sequenceBuffer.clear();
        _fslProbHistory.clear();
        _medProbHistory.clear();
        _lastGestureMotionAt = now;
      }
    } else {
      // A newly raised hand starts a fresh gesture window even when the sign
      // itself is primarily a held posture.
      _lastGestureMotionAt = now;
    }
    _lastWrist = Offset(wrist.$1, wrist.$2);
    _lastWristTimestamp = now;
    _motionHistory.add(currentMotion);
    if (_motionHistory.length > 8) _motionHistory.removeAt(0);
    final avgMotion =
        _motionHistory.reduce((a, b) => a + b) / _motionHistory.length;
    if (avgMotion >= 0.005 || _sequenceBuffer.length < 24) {
      _lastGestureMotionAt = now;
    }
    if (avgMotion <= 0.009) {
      _fslReleaseFrameCount++;
      if (_fslReleaseFrameCount >= 6) {
        _fslCandidate = null;
        _fslCandidateCount = 0;
        _fslProbHistory.clear();
      }
    } else {
      _fslReleaseFrameCount = 0;
    }
    if (avgMotion >= 0.015) {
      _motionRouteActive = true;
    }

    // 5. Accumulate a model-compatible body and hand sequence. The ST-GCN
    // was trained with all 33 MediaPipe pose landmarks plus both hand slots.
    if (poseLandmarks != null && poseLandmarks.length == 33) {
      _accumulateSequenceFrame(smoothedHands, poseLandmarks);
    } else {
      _sequenceBuffer.clear();
      _fslProbHistory.clear();
      _medProbHistory.clear();
      _fslCandidate = null;
      _fslCandidateCount = 0;
      _medCandidate = null;
      _medCandidateCount = 0;
    }

    // 6. Dynamic Letter 'J' Kinematic Detector:
    // In FSL, 'J' is traced dynamically in the air using an 'I' handshape (downward stroke + upward hook).
    if (_jCooldown > 0) _jCooldown--;
    if (!_isPaused &&
        smoothedHands.length == 1 &&
        _mode != RecognitionMode.phrases &&
        _mode != RecognitionMode.medical) {
      final isI = _checkIsIHandshape(smoothedPrimary);
      final pinkyTip = smoothedPrimary[20];
      _jTrajectory.add((pinkyTip.$1, pinkyTip.$2, isI));
      if (_jTrajectory.length > 30) _jTrajectory.removeAt(0);

      if (_jCooldown == 0 && _alphaEmittedLabel != 'J' && _detectJGesture()) {
        _jCooldown = 24; // Debounce ~0.8s
        _jTrajectory.clear();
        _sequenceBuffer.clear();
        _alphaProbHistory.clear();
        _alphaCandidate = 'J';
        _alphaCandidateCount = 2;
        _alphaEmittedLabel = 'J';
        _alphaReleaseFrameCount = 0;
        final now = DateTime.now();
        _lastEmittedLabel = 'J';
        _lastEmittedTime = now;
        _predictionsController.add(
          SignResult(
            label: 'J',
            confidence: 0.94,
            timestamp: now,
            source: 'trajectory_j_detector',
          ),
        );
        return;
      }
    } else {
      _jTrajectory.clear();
    }

    // 7. Intelligent Mode & Motion-Aware Routing:
    if (_mode == RecognitionMode.alphabet) {
      _evaluateAlphabet(smoothedPrimary);
    } else if (_mode == RecognitionMode.phrases) {
      _evaluateConversationalSign();
    } else if (_mode == RecognitionMode.medical) {
      _evaluateMedicalSign();
    } else {
      // Auto Mode:
      // FSL Alphabet fingerspelling is strictly 1-handed.
      // If 2 hands are raised in active signing space, route to ST-GCN phrases.
      if (smoothedHands.length >= 2) {
        _alphaProbHistory.clear();
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaReleaseFrameCount = 0;
        _evaluateConversationalSign();
      } else if (_motionRouteActive) {
        // Dynamic single-hand movement: route to ST-GCN conversational phrases
        _alphaProbHistory.clear();
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaReleaseFrameCount = 0;
        _evaluateConversationalSign();
      } else {
        // Hand held steady: evaluate Alphabet Fingerspelling (A-Z)
        _fslProbHistory.clear();
        _fslCandidate = null;
        _fslCandidateCount = 0;
        _evaluateAlphabet(smoothedPrimary);
      }
    }
  }

  /// Checks if hand is held in the 'I' posture (pinky extended upright, other 3 fingers curled)
  bool _checkIsIHandshape(List<(double, double, double)> lms) {
    if (lms.length < 21) return false;
    final pinkyTip = lms[20];
    final pinkyPip = lms[18];
    final pinkyMcp = lms[17];

    final indexTip = lms[8];
    final indexPip = lms[6];
    final middleTip = lms[12];
    final middlePip = lms[10];
    final ringTip = lms[16];
    final ringPip = lms[14];

    // In upright screen coordinates (0.0 top, 1.0 bottom):
    // Pinky extended: tip is higher on screen (lower y) than PIP and MCP
    final pinkyExtended =
        (pinkyTip.$2 < pinkyPip.$2) && (pinkyTip.$2 < pinkyMcp.$2);

    // Other three fingers curled down:
    final indexCurled = indexTip.$2 > (indexPip.$2 - 0.03);
    final middleCurled = middleTip.$2 > (middlePip.$2 - 0.03);
    final ringCurled = ringTip.$2 > (ringPip.$2 - 0.03);

    // Pinky tip noticeably higher on screen than curled fingertips
    final pinkyDominant =
        (pinkyTip.$2 < indexTip.$2 - 0.035 &&
        pinkyTip.$2 < middleTip.$2 - 0.035 &&
        pinkyTip.$2 < ringTip.$2 - 0.035);

    return pinkyExtended &&
        indexCurled &&
        middleCurled &&
        ringCurled &&
        pinkyDominant;
  }

  /// Kinematic recognizer for the letter 'J'
  /// Traces downward stroke followed by an upward hook curve while in 'I' handshape
  bool _detectJGesture() {
    final n = _jTrajectory.length;
    if (n < 8) return false;

    for (int winLen = 8; winLen <= math.min(n, 28); winLen++) {
      final points = _jTrajectory.sublist(n - winLen);
      final iCount = points.where((p) => p.$3).length;
      if (iCount < (winLen * 0.28).toInt()) continue;

      final yVals = points.map((p) => p.$2).toList();
      final xVals = points.map((p) => p.$1).toList();

      final firstThird = math.max(2, winLen ~/ 3);
      double yStart = yVals[0];
      for (int i = 0; i < firstThird; i++) {
        if (yVals[i] < yStart) yStart = yVals[i];
      }

      double yMax = yVals[0];
      int idxMax = 0;
      for (int i = 0; i < winLen; i++) {
        if (yVals[i] > yMax) {
          yMax = yVals[i];
          idxMax = i;
        }
      }

      // Lowest point of hook must not be at the very beginning or the very end
      if (idxMax < winLen ~/ 3 || idxMax >= winLen - 1) continue;

      double yEnd = yVals[idxMax];
      for (int i = idxMax; i < winLen; i++) {
        if (yVals[i] < yEnd) yEnd = yVals[i];
      }

      final downDrop = yMax - yStart;
      final upHook = yMax - yEnd;

      double minX = xVals[0], maxX = xVals[0];
      for (final x in xVals) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      final xSpan = maxX - minX;

      // Drop >= 0.035, Hook recovery >= 0.015, Lateral arc >= 0.015
      if (downDrop >= 0.035 && upHook >= 0.015 && xSpan >= 0.015) {
        return true;
      }
    }
    return false;
  }

  /// Normalizes 21 3D hand coordinates (centered at wrist, scaled by max radius) and runs fsl_alphabet.tflite
  void _evaluateAlphabet(List<(double, double, double)> lms) {
    if (_alphabetInterpreter == null || _isPaused) return;

    final wrist = lms[0];
    // Active signing space check: skip if hand is resting at the very bottom
    if (wrist.$2 > 0.92) return;

    // Canonical Right-Hand Alignment:
    // In fsl_alphabet.tflite training data (canonical right hand palm facing camera):
    // Index MCP (joint 5) has a greater x-coordinate than Pinky MCP (joint 17): dx_5 > dx_17.
    // Thumb (joint 4) extends toward positive dx.
    // In front camera selfie view (horizontally mirrored preview) or with a left hand:
    // Index MCP is to the left of Pinky MCP (lms[5].$1 < lms[17].$1).
    // We detect this and mirror dx across 0 to guarantee canonical right-hand alignment!
    final bool isMirrored = lms.length >= 18 && lms[5].$1 < lms[17].$1;

    final centered = <List<double>>[];
    double maxDist = 1e-4;

    for (final pt in lms) {
      final rawDx = pt.$1 - wrist.$1;
      final dx = isMirrored ? -rawDx : rawDx;
      final dy = pt.$2 - wrist.$2;
      final dz = pt.$3 - wrist.$3;
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist > maxDist) maxDist = dist;
      centered.add([dx, dy, dz]);
    }

    final flat63 = <double>[];
    for (final pt in centered) {
      flat63.add(pt[0] / maxDist);
      flat63.add(pt[1] / maxDist);
      flat63.add(pt[2] / maxDist);
    }

    final input = [flat63];
    final output = [List<double>.filled(_alphabetLabels.length, 0.0)];

    try {
      _alphabetInterpreter!.run(input, output);
      final rawProbs = output[0];
      if (rawProbs.length != _alphabetLabels.length) {
        debugPrint(
          '[TfliteRecognitionService] Alphabet model output count does not match its labels.',
        );
        return;
      }

      _alphaProbHistory.add(List<double>.from(rawProbs));
      if (_alphaProbHistory.length > _alphaProbHistorySize) {
        _alphaProbHistory.removeAt(0);
      }
      final probs = List<double>.filled(_alphabetLabels.length, 0.0);
      for (final frameProbs in _alphaProbHistory) {
        for (var i = 0; i < frameProbs.length; i++) {
          probs[i] += frameProbs[i] / _alphaProbHistory.length;
        }
      }

      int top1Idx = 0;
      double top1Prob = probs[0];
      double top2Prob = 0.0;

      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > top1Prob) {
          top2Prob = top1Prob;
          top1Prob = probs[i];
          top1Idx = i;
        } else if (probs[i] > top2Prob) {
          top2Prob = probs[i];
        }
      }

      // Match Chapter 3's two-tier confidence gate before committing any sign.
      // A brief low-confidence transition also lets users deliberately repeat
      // the same static letter without auto-repeating held signs.
      if (_passesPaperConfidenceGate(top1Prob, top2Prob) &&
          top1Idx < _alphabetLabels.length) {
        _alphaReleaseFrameCount = 0;
        final letter = _alphabetLabels[top1Idx];
        if (letter == _alphaCandidate) {
          _alphaCandidateCount++;
        } else {
          _alphaCandidate = letter;
          _alphaCandidateCount = 1;
        }

        // Five stable frames filter brief class flicker while keeping input
        // responsive at normal camera frame rates.
        if (_alphaCandidateCount >= 5 && letter != _alphaEmittedLabel) {
          final now = DateTime.now();
          _alphaEmittedLabel = letter;
          _lastEmittedLabel = letter;
          _lastEmittedTime = now;
          _predictionsController.add(
            SignResult(
              label: letter,
              confidence: top1Prob,
              timestamp: now,
              source: 'fsl_alphabet_model',
            ),
          );
        }
      } else {
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaReleaseFrameCount++;
        if (_alphaReleaseFrameCount >= 8) {
          _alphaEmittedLabel = null;
        }
      }
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Alphabet inference error: $e');
    }
  }

  /// Builds the exact 75-joint input layout used by ST-GCN training:
  /// 33 pose landmarks, 21 left-hand landmarks, and 21 right-hand landmarks.
  void _accumulateSequenceFrame(
    List<List<(double, double, double)>> hands,
    List<Landmark> poseLandmarks,
  ) {
    if (hands.isEmpty || poseLandmarks.length != 33) return;

    (double, double, double) toWorld((double, double, double) point) =>
        (_isFrontCamera ? 1.0 - point.$1 : point.$1, point.$2, point.$3);

    final pose = poseLandmarks.map(_transformLandmark).map(toWorld).toList();
    final leftShoulder = pose[11];
    final rightShoulder = pose[12];
    final midShoulder = (
      (leftShoulder.$1 + rightShoulder.$1) / 2.0,
      (leftShoulder.$2 + rightShoulder.$2) / 2.0,
      (leftShoulder.$3 + rightShoulder.$3) / 2.0,
    );
    final shoulderDx = leftShoulder.$1 - rightShoulder.$1;
    final shoulderDy = leftShoulder.$2 - rightShoulder.$2;
    final shoulderDz = leftShoulder.$3 - rightShoulder.$3;
    final measuredShoulderWidth = math.sqrt(
      shoulderDx * shoulderDx +
          shoulderDy * shoulderDy +
          shoulderDz * shoulderDz,
    );
    if (measuredShoulderWidth > 0.05) {
      _poseNormalizationCenter = midShoulder;
      _poseNormalizationScale = measuredShoulderWidth;
    }

    List<double> normalize((double, double, double) point) => [
      (point.$1 - _poseNormalizationCenter.$1) / _poseNormalizationScale,
      (point.$2 - _poseNormalizationCenter.$2) / _poseNormalizationScale,
      (point.$3 - _poseNormalizationCenter.$3) / _poseNormalizationScale,
    ];

    final currentJoints = List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0]);
    for (int i = 0; i < pose.length; i++) {
      currentJoints[i] = normalize(pose[i]);
    }

    final worldHands = hands.map((hand) => hand.map(toWorld).toList()).toList();
    List<(double, double, double)> rightHand;
    List<(double, double, double)>? leftHand;
    if (worldHands.length >= 2) {
      final hand0 = worldHands[0];
      final hand1 = worldHands[1];
      final meanX0 =
          hand0.map((point) => point.$1).reduce((a, b) => a + b) / hand0.length;
      final meanX1 =
          hand1.map((point) => point.$1).reduce((a, b) => a + b) / hand1.length;
      if (meanX0 < meanX1) {
        rightHand = hand0;
        leftHand = hand1;
      } else {
        rightHand = hand1;
        leftHand = hand0;
      }
    } else {
      rightHand = worldHands.first;
      leftHand = null;
    }

    for (int i = 0; i < 21 && i < rightHand.length; i++) {
      currentJoints[54 + i] = normalize(rightHand[i]);
    }
    if (leftHand != null) {
      for (int i = 0; i < 21 && i < leftHand.length; i++) {
        currentJoints[33 + i] = normalize(leftHand[i]);
      }
    }

    _sequenceBuffer.add(currentJoints);
    if (_sequenceBuffer.length > _targetSequenceLength) {
      _sequenceBuffer.removeAt(0);
    }
  }

  /// Runs 103-class ST-GCN conversational model on continuous sequence buffer
  void _evaluateConversationalSign() {
    if (_fslModelInterpreter == null || _fslLabels.isEmpty || _isPaused) return;

    // Keep evaluating through the deliberate end hold so the classifier sees
    // the completed sign and can settle before the signer lowers their hands.
    if (_sequenceBuffer.length >= 24 && _hasRecentGestureActivity) {
      try {
        final seqInput = _resampleSequence(
          _sequenceBuffer,
          _targetSequenceLength,
        );
        final input = [seqInput];
        final output = [List<double>.filled(_fslLabels.length, 0.0)];

        _fslModelInterpreter!.run(input, output);
        final rawProbs = output[0];

        // Rolling probability distribution smoothing (eliminates single-frame noise)
        _fslProbHistory.add(rawProbs);
        if (_fslProbHistory.length > _probHistorySize) {
          _fslProbHistory.removeAt(0);
        }

        final probs = List<double>.filled(_fslLabels.length, 0.0);
        for (final p in _fslProbHistory) {
          for (int i = 0; i < p.length; i++) {
            probs[i] += p[i] / _fslProbHistory.length;
          }
        }

        int top1Idx = 0;
        double top1Prob = probs[0];
        double top2Prob = 0.0;

        for (int i = 1; i < probs.length; i++) {
          if (probs[i] > top1Prob) {
            top2Prob = top1Prob;
            top1Prob = probs[i];
            top1Idx = i;
          } else if (probs[i] > top2Prob) {
            top2Prob = probs[i];
          }
        }

        if (_passesPaperConfidenceGate(top1Prob, top2Prob) &&
            top1Idx < _fslLabels.length) {
          final rawWord = _fslLabels[top1Idx];
          final displayWord = _formatFslPhrase(rawWord);

          if (displayWord == _fslCandidate) {
            _fslCandidateCount++;
          } else {
            _fslCandidate = displayWord;
            _fslCandidateCount = 1;
          }

          // Commit only after the same phrase remains the leading class for
          // several evaluations, preventing transition frames from flashing
          // different words into the transcript.
          if (_fslCandidateCount >= 4 && displayWord != _fslEmittedLabel) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
            final requiredDelay = 700;

            if (elapsed > requiredDelay) {
              _lastEmittedLabel = displayWord;
              _fslEmittedLabel = displayWord;
              _lastEmittedTime = now;
              _predictionsController.add(
                SignResult(
                  label: displayWord,
                  confidence: top1Prob,
                  timestamp: now,
                  source: 'st_gcn_model',
                ),
              );
            }
          }
        } else {
          _fslCandidate = null;
          _fslCandidateCount = 0;
        }
      } catch (e) {
        debugPrint('[TfliteRecognitionService] ST-GCN inference error: $e');
      }
    }
  }

  /// Formats raw FSL class names to clear, user-friendly labels with English translations
  static String _formatFslPhrase(String sign) {
    switch (sign.trim()) {
      case 'Kamusta':
        return 'Kamusta (Hello)';
      case 'Kamusta ka':
        return 'Kamusta ka (How are you)';
      case 'Salamat':
        return 'Salamat (Thank you)';
      case 'Walang anuman':
        return 'Walang anuman (You\'re welcome)';
      case 'Magandang Umaga':
        return 'Magandang Umaga (Good morning)';
      case 'Magandang Hapon':
        return 'Magandang Hapon (Good afternoon)';
      case 'Magandang Gabi':
        return 'Magandang Gabi (Good evening)';
      case 'Magkita tayo bukas':
        return 'Magkita tayo bukas (See you tomorrow)';
      case 'Ikinagagalak kitang makilala':
        return 'Ikinagagalak kitang makilala (Nice to meet you)';
      case 'Oo':
        return 'Oo (Yes)';
      case 'Hindi':
        return 'Hindi (No)';
      case 'Hindi alam':
        return 'Hindi alam (Don\'t know)';
      case 'Hindi maintindihan':
        return 'Hindi maintindihan (Don\'t understand)';
      case 'Naiintindihan':
        return 'Naiintindihan (Understood)';
      case 'Ingat':
        return 'Ingat (Take care)';
      default:
        return sign;
    }
  }

  /// Evaluates 60-frame ST-GCN sequence using the dedicated 35-class Medical FSL model.
  void _evaluateMedicalSign() {
    if (_medicalModelInterpreter == null ||
        _medicalLabels.isEmpty ||
        _isPaused) {
      return;
    }

    if (_sequenceBuffer.length >= 24 && _hasRecentGestureActivity) {
      try {
        final seqInput = _resampleSequence(
          _sequenceBuffer,
          _targetSequenceLength,
        );
        final input = [seqInput];
        final output = [List<double>.filled(_medicalLabels.length, 0.0)];

        _medicalModelInterpreter!.run(input, output);
        final rawProbs = output[0];

        // Rolling probability distribution smoothing
        _medProbHistory.add(rawProbs);
        if (_medProbHistory.length > _probHistorySize) {
          _medProbHistory.removeAt(0);
        }

        final probs = List<double>.filled(_medicalLabels.length, 0.0);
        for (final p in _medProbHistory) {
          for (int i = 0; i < p.length; i++) {
            probs[i] += p[i] / _medProbHistory.length;
          }
        }

        int top1Idx = 0;
        double top1Prob = probs[0];
        double top2Prob = 0.0;

        for (int i = 1; i < probs.length; i++) {
          if (probs[i] > top1Prob) {
            top2Prob = top1Prob;
            top1Prob = probs[i];
            top1Idx = i;
          } else if (probs[i] > top2Prob) {
            top2Prob = probs[i];
          }
        }

        if (_passesPaperConfidenceGate(top1Prob, top2Prob) &&
            top1Idx < _medicalLabels.length) {
          final rawWord = _medicalLabels[top1Idx];
          // The training metadata currently names outputs 18–25 with
          // placeholders. Keep those model outputs from being presented as
          // if they were real FSL medical signs until verified labels exist.
          if (RegExp(r'^Medical_\d+$').hasMatch(rawWord)) {
            debugPrint(
              '[TfliteRecognitionService] Medical model predicted an unmapped class; '
              'suppressing output until its FSL label is verified.',
            );
            _medCandidate = null;
            _medCandidateCount = 0;
            return;
          }
          final displayWord = _formatMedicalPhrase(rawWord);

          if (displayWord == _medCandidate) {
            _medCandidateCount++;
          } else {
            _medCandidate = displayWord;
            _medCandidateCount = 1;
          }

          if (_medCandidateCount >= 4 && displayWord != _medEmittedLabel) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
            final isSameWord = (displayWord == _lastEmittedLabel);
            final requiredDelay = isSameWord ? 2200 : 900;

            if (elapsed > requiredDelay) {
              _lastEmittedLabel = displayWord;
              _medEmittedLabel = displayWord;
              _lastEmittedTime = now;
              _predictionsController.add(
                SignResult(
                  label: displayWord,
                  confidence: top1Prob,
                  timestamp: now,
                  source: 'fsl_medical_model',
                ),
              );
            }
          }
        } else {
          _medCandidate = null;
          _medCandidateCount = 0;
        }
      } catch (e) {
        debugPrint(
          '[TfliteRecognitionService] Medical ST-GCN inference error: $e',
        );
      }
    }
  }

  /// Formats raw medical signs to bilingual clinical & patient-friendly labels
  static String _formatMedicalPhrase(String sign) {
    switch (sign.trim()) {
      case 'Alin':
        return 'Alin (Which)';
      case 'Allergic':
        return 'Allergic (Allergy)';
      case 'Ano':
        return 'Ano (What)';
      case 'Bahing':
        return 'Bahing (Sneezing)';
      case 'Doktor':
        return 'Doktor (Doctor)';
      case 'Edad':
        return 'Edad (Age)';
      case 'Ikaw':
        return 'Ikaw (You)';
      case 'Ilan':
        return 'Ilan (How many)';
      case 'Kailan':
        return 'Kailan (When)';
      case 'Lagnat':
        return 'Lagnat (Fever)';
      case 'Magkano':
        return 'Magkano (How much)';
      case 'Nahihilo':
        return 'Nahihilo (Dizzy)';
      case 'Nahihirapan Huminga':
        return 'Nahihirapan Huminga (Shortness of breath)';
      case 'Pakiramdam':
        return 'Pakiramdam (Condition / Feeling)';
      case 'Salamat':
        return 'Salamat (Thank you)';
      case 'Sino':
        return 'Sino (Who)';
      case 'Sipon':
        return 'Sipon (Cold / Runny nose)';
      default:
        return sign;
    }
  }

  /// Linearly resamples buffer to exact 60-frame ST-GCN tensor input with true linear interpolation
  List<List<List<double>>> _resampleSequence(
    List<List<List<double>>> sequence,
    int targetLength,
  ) {
    final n = sequence.length;
    if (n == targetLength) return sequence;
    if (n <= 1) {
      return List.generate(
        targetLength,
        (_) => sequence.isEmpty
            ? List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0])
            : sequence.first,
      );
    }
    final resampled = <List<List<double>>>[];
    for (int i = 0; i < targetLength; i++) {
      final pos = i * (n - 1) / (targetLength - 1);
      final lower = pos.floor();
      final upper = pos.ceil();
      final alpha = pos - lower;
      final frame = List.generate(_totalJoints, (j) {
        final p0 = sequence[lower][j];
        final p1 = sequence[upper][j];
        return [
          (1.0 - alpha) * p0[0] + alpha * p1[0],
          (1.0 - alpha) * p0[1] + alpha * p1[1],
          (1.0 - alpha) * p0[2] + alpha * p1[2],
        ];
      });
      resampled.add(frame);
    }
    return resampled;
  }

  @override
  void dispose() {
    _isRunning = false;
    _isInitialized = false;
    _handSubscription?.cancel();
    _pendingHandFrame = null;
    if (_poseLandmarkerReady) {
      unawaited(
        _poseLandmarkerChannel.invokeMethod<void>('close').catchError((_) {}),
      );
      _poseLandmarkerReady = false;
    }
    _predictionsController.close();
    _pauseStatusController.close();
    _landmarkStreamController.close();
    _alphabetInterpreter?.close();
    _fslModelInterpreter?.close();
    _medicalModelInterpreter?.close();
  }
}
