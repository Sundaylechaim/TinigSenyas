import 'dart:async';
import 'dart:convert';
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
import '../../models/recognition_graph_frame.dart';

class TfliteRecognitionService implements RecognitionService {
  static const MethodChannel _poseLandmarkerChannel = MethodChannel(
    'tinigsenyas/pose_landmarker',
  );

  final _predictionsController = StreamController<SignResult>.broadcast();
  final _pauseStatusController = StreamController<bool>.broadcast();
  final _landmarkStreamController =
      StreamController<List<List<Offset>>>.broadcast();
  final _graphFrameController =
      StreamController<RecognitionGraphFrame>.broadcast();

  _ModelRunner? _fslModelInterpreter;
  _ModelRunner? _phraseExtensionInterpreter;
  _ModelRunner? _alphabetInterpreter;
  _ModelRunner? _medicalModelInterpreter;
  HandLandmarkerPlugin? _handLandmarker;
  StreamSubscription<List<Hand>>? _handSubscription;
  Completer<List<Hand>>? _pendingHandFrame;
  List<Landmark>? _poseLandmarks;
  DateTime? _poseLandmarksUpdatedAt;
  bool _poseLandmarkerReady = false;
  int _poseFrameCounter = 0;
  int _poseRequestGeneration = 0;
  bool _poseInferenceInFlight = false;
  bool _modelsReloading = false;
  bool _modelInferenceInFlight = false;
  int _recognitionEpoch = 0;
  Future<void>? _reloadModelsTask;
  DateTime? _lastAlphabetInferenceAt;
  DateTime? _lastMedicalInferenceAt;
  RecognitionGraphFrame? _latestGraphFrame;

  List<String> _fslLabels = [];
  List<String> _phraseExtensionLabels = [];
  List<String> _medicalLabels = [];
  List<String> _alphabetLabels = [];
  static const int _medicalClassCount = 35;
  static const int _alphabetClassCount = 28;
  static const int _phraseExtensionClassCount = 100;
  static const int _phraseExtensionSequenceLength = 64;

  RecognitionMode _mode = RecognitionMode.phrases;
  @override
  RecognitionMode get mode => _mode;
  @override
  set mode(RecognitionMode val) {
    if (_mode == val) return;
    _mode = val;
    _recognitionEpoch++;
    _alphaProbHistory.clear();
    _alphaCandidate = null;
    _alphaCandidateCount = 0;
    _alphaEmittedLabel = null;
    _alphaReleaseFrameCount = 0;
    _fslProbHistory.clear();
    _phraseExtensionProbHistory.clear();
    _fslCandidate = null;
    _fslCandidateCount = 0;
    _fslReleaseFrameCount = 0;
    _medProbHistory.clear();
    _medCandidate = null;
    _medCandidateCount = 0;
    _phraseGestureConsumed = false;
    _medicalGestureConsumed = false;
    _sequenceBuffer.clear();
    _lastGestureMotionAt = null;
    _lastAlphabetInferenceAt = null;
    _lastMedicalInferenceAt = null;
    _motionRouteActive = false;
    _autoPhraseRouteActive = false;
    _lastPhraseInferenceAt = null;
  }

  Offset? _lastWrist;
  DateTime? _lastWristTimestamp;
  final List<double> _motionHistory = [];
  int _missingHandFrames = 0;
  int _lastTrackedHandCount = 0;
  bool _motionRouteActive = false;
  bool _autoPhraseRouteActive = false;

  // Exponential Moving Average (EMA) landmark smoothing
  List<(double, double, double)>? _smoothedPrimaryHand;
  List<(double, double, double)>? _smoothedSecondaryHand;
  static const double _handSmoothAlpha = 0.65;
  static const int _trackingGraceFrames = 2;

  // Rolling Softmax Probability Distribution Smoothing
  final List<List<double>> _alphaProbHistory = [];
  final List<List<double>> _fslProbHistory = [];
  final List<List<double>> _phraseExtensionProbHistory = [];
  final List<List<double>> _medProbHistory = [];
  static const int _alphaProbHistorySize = 3;
  static const int _phraseProbHistorySize = 3;
  static const int _alphabetStableInferences = 3;
  static const int _phraseStableInferences = 3;
  static const Duration _alphabetInferenceInterval = Duration(milliseconds: 66);
  static const Duration _phraseInferenceInterval = Duration(milliseconds: 120);
  static const Duration _medicalInferenceInterval = Duration(milliseconds: 160);
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
  String? _alphaCandidate;
  int _alphaCandidateCount = 0;
  String? _alphaEmittedLabel;
  int _alphaReleaseFrameCount = 0;
  String? _fslCandidate;
  int _fslCandidateCount = 0;
  int _fslReleaseFrameCount = 0;
  String? _medCandidate;
  int _medCandidateCount = 0;
  bool _phraseGestureConsumed = false;
  bool _medicalGestureConsumed = false;

  // Trajectory tracking for dynamic fingerspelled letter 'J'
  final List<(double, double, bool)> _jTrajectory = [];
  int _jCooldown = 0;

  // Natural Rest Zone state
  bool _manualPaused = false;
  int _restZoneFrameCount = 0;
  static const int _restZoneThreshold = 15; // ~500ms of sustained hands at rest
  DateTime? _lastGestureMotionAt;
  DateTime? _lastPhraseInferenceAt;

  bool _passesPaperConfidenceGate(double top1, double top2) =>
      top1 >= _paperHighConfidence ||
      (top1 >= _paperMinimumConfidence && top1 - top2 >= _paperMinimumMargin);

  bool _passesPhraseExtensionConfidenceGate(double top1, double top2) =>
      top1 >= 0.90 && top1 - top2 >= 0.20;

  bool get _hasRecentGestureActivity =>
      _lastGestureMotionAt != null &&
      DateTime.now().difference(_lastGestureMotionAt!) <= _gestureSettleWindow;

  void _runModelInference(Future<void> Function() inference) {
    if (_modelInferenceInFlight || _modelsReloading) return;
    _modelInferenceInFlight = true;
    unawaited(() async {
      try {
        await inference();
      } catch (error) {
        debugPrint('[TfliteRecognitionService] Model inference failed: $error');
      } finally {
        _modelInferenceInFlight = false;
      }
    }());
  }

  @override
  bool get isModelReady {
    if (!_isInitialized || _handLandmarker == null) return false;
    final alphabetReady =
        _alphabetInterpreter != null &&
        _alphabetLabels.length == _alphabetClassCount;
    final phraseReady =
        _poseLandmarkerReady &&
        _fslModelInterpreter != null &&
        _fslLabels.length >= 2;
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
    required int? expectedCount,
    required String modelName,
  }) async {
    if (localFile != null && await localFile.exists()) {
      try {
        final localLabels = (await localFile.readAsString())
            .split(RegExp(r'\r?\n'))
            .map((label) => label.trim())
            .where((label) => label.isNotEmpty)
            .toList();
        if (expectedCount == null
            ? localLabels.length >= 2
            : localLabels.length == expectedCount) {
          return localLabels;
        }
        debugPrint(
          '[TfliteRecognitionService] Ignoring invalid $modelName labels: found ${localLabels.length}.',
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
      if (expectedCount == null
          ? bundledLabels.length >= 2
          : bundledLabels.length == expectedCount) {
        return bundledLabels;
      }
      debugPrint(
        '[TfliteRecognitionService] Invalid bundled $modelName labels: found ${bundledLabels.length}.',
      );
    } catch (error) {
      debugPrint(
        '[TfliteRecognitionService] Could not load bundled $modelName labels: $error',
      );
    }
    return const [];
  }

  Future<List<String>> _loadPhraseExtensionLabels({
    required File? localFile,
  }) async {
    List<String>? parse(String source) {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != _phraseExtensionClassCount) {
        return null;
      }
      final labels = <String>[];
      final keys = <String>{};
      for (var index = 0; index < _phraseExtensionClassCount; index++) {
        final entry = decoded['$index'];
        if (entry is! Map<String, dynamic>) return null;
        final label = (entry['display_label'] as String?)?.trim() ?? '';
        final key = (entry['key'] as String?)?.trim() ?? '';
        if (label.isEmpty || key.isEmpty || !keys.add(key)) return null;
        labels.add(label);
      }
      return labels.toSet().length == _phraseExtensionClassCount
          ? labels
          : null;
    }

    if (localFile != null && await localFile.exists()) {
      try {
        final labels = parse(await localFile.readAsString());
        if (labels != null) return labels;
      } catch (error) {
        debugPrint(
          '[TfliteRecognitionService] Could not load OTA phrase extension labels: $error',
        );
      }
    }
    try {
      final labels = parse(
        await rootBundle.loadString(
          'assets/model/phrase_extension_labels.json',
        ),
      );
      if (labels != null) return labels;
    } catch (error) {
      debugPrint(
        '[TfliteRecognitionService] Could not load bundled phrase extension labels: $error',
      );
    }
    debugPrint(
      '[TfliteRecognitionService] Phrase extension map must contain '
      '100 unique ordered entries; extension model will not be used.',
    );
    return const [];
  }

  Future<_ModelRunner?> _loadValidatedInterpreter({
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
      IsolateInterpreter? worker;
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
        worker = await IsolateInterpreter.create(
          address: interpreter.address,
          debugName: 'TinigSenyas-$modelName',
        );
        return _ModelRunner(interpreter, worker);
      } catch (error) {
        if (worker != null) await worker.close();
        interpreter?.close();
        debugPrint(
          '[TfliteRecognitionService] $modelName load failed; trying next source: $error',
        );
      }
    }
    return null;
  }

  Future<void> _closeModel(_ModelRunner? model) async {
    if (model == null) return;
    try {
      await model.worker.close();
    } finally {
      model.interpreter.close();
    }
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
  Stream<RecognitionGraphFrame>? get graphFrames =>
      _graphFrameController.stream;

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
  Future<void> reloadModels() {
    return _reloadModelsTask ??= _reloadModelsInternal().whenComplete(() {
      _reloadModelsTask = null;
    });
  }

  Future<void> _reloadModelsInternal() async {
    _modelsReloading = true;
    _clearTemporalTrackingData();
    try {
      while (_isProcessingFrame || _modelInferenceInFlight) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
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
        // Phrase-model output width follows the bundled/OTA label file. The
        // interpreter's output tensor is checked against this exact width.
        expectedCount: null,
        modelName: 'conversational',
      );

      final localPhraseExtensionLabels = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'phrase_extension_labels.json'))
          : null;
      _phraseExtensionLabels = await _loadPhraseExtensionLabels(
        localFile: localPhraseExtensionLabels,
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

      final localAlphaFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_alphabet.tflite'))
          : null;
      final loadedAlphabet = await _loadValidatedInterpreter(
        modelName: 'alphabet',
        localFile: localAlphaFile,
        assetPath: 'assets/model/fsl_alphabet.tflite',
        inputShape: const [1, 63],
        outputShape: const [1, _alphabetClassCount],
        options: InterpreterOptions()..threads = 2,
      );
      if (loadedAlphabet != null) {
        final previous = _alphabetInterpreter;
        _alphabetInterpreter = loadedAlphabet;
        await _closeModel(previous);
      }

      final localModelFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_model.tflite'))
          : null;
      final loadedConversational = await _loadValidatedInterpreter(
        modelName: 'conversational ST-GCN',
        localFile: localModelFile,
        assetPath: 'assets/model/fsl_model.tflite',
        inputShape: const [1, 60, 75, 3],
        outputShape: [1, _fslLabels.length],
        options: InterpreterOptions()..threads = 2,
      );
      if (loadedConversational != null) {
        final previous = _fslModelInterpreter;
        _fslModelInterpreter = loadedConversational;
        await _closeModel(previous);
      }

      final localPhraseExtensionModel = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_phrase_extension.tflite'))
          : null;
      final loadedPhraseExtension =
          _phraseExtensionLabels.length == _phraseExtensionClassCount
          ? await _loadValidatedInterpreter(
              modelName: 'FSL phrase extension ST-GCN',
              localFile: localPhraseExtensionModel,
              assetPath: 'assets/model/fsl_phrase_extension.tflite',
              inputShape: const [1, _phraseExtensionSequenceLength, 75, 3],
              outputShape: const [1, _phraseExtensionClassCount],
              options: InterpreterOptions()..threads = 2,
            )
          : null;
      if (loadedPhraseExtension != null) {
        final previous = _phraseExtensionInterpreter;
        _phraseExtensionInterpreter = loadedPhraseExtension;
        await _closeModel(previous);
      } else {
        final previous = _phraseExtensionInterpreter;
        _phraseExtensionInterpreter = null;
        await _closeModel(previous);
        debugPrint(
          '[TfliteRecognitionService] FSL phrase extension unavailable; '
          'the existing phrase model remains active.',
        );
      }

      final localMedModelFile = useLocalOverrides && modelsDir != null
          ? File(p.join(modelsDir.path, 'fsl_medical.tflite'))
          : null;
      final loadedMedical = await _loadValidatedInterpreter(
        modelName: 'medical ST-GCN',
        localFile: localMedModelFile,
        assetPath: 'assets/model/fsl_medical.tflite',
        inputShape: const [1, 60, 75, 3],
        outputShape: [1, _medicalClassCount],
        options: InterpreterOptions()..threads = 2,
      );
      if (loadedMedical != null) {
        final previous = _medicalModelInterpreter;
        _medicalModelInterpreter = loadedMedical;
        await _closeModel(previous);
      }

      debugPrint(
        '[TfliteRecognitionService] Model connection status: '
        'alphabet=${_alphabetInterpreter != null}, '
        'conversational=${_fslModelInterpreter != null}, '
        'phraseExtension=${_phraseExtensionInterpreter != null && _phraseExtensionLabels.length == _phraseExtensionClassCount}, '
        'medical=${_medicalModelInterpreter != null}.',
      );
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Error reloading models: $e');
    } finally {
      _modelsReloading = false;
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
    _poseRequestGeneration++;
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
    if (!_isRunning || !_isInitialized || _modelsReloading) return;
    if (_isProcessingFrame) return;

    final nextSensorOrientation = sensorOrientation ?? _sensorOrientation;
    final nextIsFrontCamera = isFrontCamera ?? _isFrontCamera;
    if (nextSensorOrientation != _sensorOrientation ||
        nextIsFrontCamera != _isFrontCamera) {
      _sensorOrientation = nextSensorOrientation;
      _isFrontCamera = nextIsFrontCamera;
      _poseRequestGeneration++;
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
      // Keep pose inference at one frame in four, but run it independently so
      // a slow pose frame cannot stall hand tracking or block camera updates.
      if (_poseLandmarkerReady && _poseFrameCounter % 4 == 1) {
        _schedulePoseInference(image);
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
        const Duration(milliseconds: 300),
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

  void _schedulePoseInference(CameraImage image) {
    if (_poseInferenceInFlight || image.planes.length < 3) return;

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final frame = _PoseFrame(
      yPlane: Uint8List.fromList(yPlane.bytes),
      uPlane: Uint8List.fromList(uPlane.bytes),
      vPlane: Uint8List.fromList(vPlane.bytes),
      width: image.width,
      height: image.height,
      yRowStride: yPlane.bytesPerRow,
      uvRowStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
      rotation: _sensorOrientation,
    );
    final generation = _poseRequestGeneration;
    _poseInferenceInFlight = true;
    unawaited(() async {
      try {
        final pose = await _detectPoseLandmarks(frame);
        if (_isRunning &&
            generation == _poseRequestGeneration &&
            pose != null) {
          _poseLandmarks = pose;
          _poseLandmarksUpdatedAt = DateTime.now();
        }
      } catch (error) {
        debugPrint('[TfliteRecognitionService] Pose inference failed: $error');
      } finally {
        _poseInferenceInFlight = false;
      }
    }());
  }

  Future<List<Landmark>?> _detectPoseLandmarks(_PoseFrame frame) async {
    try {
      final raw = await _poseLandmarkerChannel
          .invokeMethod<List<dynamic>>('detect', {
            'yPlane': frame.yPlane,
            'uPlane': frame.uPlane,
            'vPlane': frame.vPlane,
            'width': frame.width,
            'height': frame.height,
            'yRowStride': frame.yRowStride,
            'uvRowStride': frame.uvRowStride,
            'uvPixelStride': frame.uvPixelStride,
            'rotation': frame.rotation,
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
    } catch (_) {
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

  void _clearTemporalTrackingData({bool preserveAlphabetEmission = false}) {
    _recognitionEpoch++;
    _sequenceBuffer.clear();
    _poseNormalizationCenter = (0.5, 0.5, 0.0);
    _poseNormalizationScale = 0.20;
    _alphaProbHistory.clear();
    _fslProbHistory.clear();
    _phraseExtensionProbHistory.clear();
    _medProbHistory.clear();
    _motionHistory.clear();
    _smoothedPrimaryHand = null;
    _smoothedSecondaryHand = null;
    _lastWrist = null;
    _lastWristTimestamp = null;
    _motionRouteActive = false;
    _autoPhraseRouteActive = false;
    _alphaCandidate = null;
    _alphaCandidateCount = 0;
    if (!preserveAlphabetEmission) _alphaEmittedLabel = null;
    _alphaReleaseFrameCount = 0;
    _fslCandidate = null;
    _fslCandidateCount = 0;
    _fslReleaseFrameCount = 0;
    _medCandidate = null;
    _medCandidateCount = 0;
    _phraseGestureConsumed = false;
    _medicalGestureConsumed = false;
    _lastGestureMotionAt = null;
    _lastPhraseInferenceAt = null;
    _lastAlphabetInferenceAt = null;
    _lastMedicalInferenceAt = null;
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
      _clearTemporalTrackingData(preserveAlphabetEmission: true);
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
        _clearTemporalTrackingData(preserveAlphabetEmission: true);
        _lastTrackedHandCount = 0;
      }
      if (_missingHandFrames > _trackingGraceFrames) {
        _restZoneFrameCount++;
        if (_restZoneFrameCount >= _restZoneThreshold && !_manualPaused) {
          if (!_isPaused) {
            _isPaused = true;
            _alphaEmittedLabel = null;
            _alphaReleaseFrameCount = 0;
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
      _recognitionEpoch++;
      _sequenceBuffer.clear();
      _alphaProbHistory.clear();
      _fslProbHistory.clear();
      _medProbHistory.clear();
      _motionHistory.clear();
      _lastWrist = null;
      _lastWristTimestamp = null;
      _motionRouteActive = false;
      _autoPhraseRouteActive = false;
      _alphaCandidate = null;
      _alphaCandidateCount = 0;
      _alphaEmittedLabel = null;
      _alphaReleaseFrameCount = 0;
      _fslCandidate = null;
      _fslCandidateCount = 0;
      _fslReleaseFrameCount = 0;
      _medCandidate = null;
      _medCandidateCount = 0;
      _phraseGestureConsumed = false;
      _medicalGestureConsumed = false;
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
          _recognitionEpoch++;
          _phraseGestureConsumed = false;
          _medicalGestureConsumed = false;
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
        _autoPhraseRouteActive = false;
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaEmittedLabel = null;
        _alphaReleaseFrameCount = 0;
        _fslCandidate = null;
        _fslCandidateCount = 0;
        _fslReleaseFrameCount = 0;
        _medCandidate = null;
        _medCandidateCount = 0;
        _lastGestureMotionAt = null;
      }
      return; // Skip inference while hands are resting
    } else {
      // Hands are raised in active signing space:
      _restZoneFrameCount = 0;
      if (_isPaused && !_manualPaused) {
        _isPaused = false;
        _recognitionEpoch++;
        _phraseGestureConsumed = false;
        _medicalGestureConsumed = false;
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

    if (_mode == RecognitionMode.auto) {
      final usePhraseModel = smoothedHands.length >= 2 || _motionRouteActive;
      if (usePhraseModel != _autoPhraseRouteActive) {
        _autoPhraseRouteActive = usePhraseModel;
        _recognitionEpoch++;
        _alphaProbHistory.clear();
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaEmittedLabel = null;
        _fslProbHistory.clear();
        _fslCandidate = null;
        _fslCandidateCount = 0;
        _phraseGestureConsumed = false;
      }
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
        _recognitionEpoch++;
        _jCooldown = 24; // Debounce ~0.8s
        _jTrajectory.clear();
        _sequenceBuffer.clear();
        _alphaProbHistory.clear();
        _alphaCandidate = 'J';
        _alphaCandidateCount = 2;
        _alphaEmittedLabel = 'J';
        _alphaReleaseFrameCount = 0;
        final now = DateTime.now();
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
    final model = _alphabetInterpreter;
    if (model == null || _isPaused || _modelsReloading) return;
    final now = DateTime.now();
    if (_modelInferenceInFlight ||
        (_lastAlphabetInferenceAt != null &&
            now.difference(_lastAlphabetInferenceAt!) <
                _alphabetInferenceInterval)) {
      return;
    }

    final wrist = lms[0];
    // Active signing space check: skip if hand is resting at the very bottom
    if (wrist.$2 > 0.92) return;
    _lastAlphabetInferenceAt = now;
    final epoch = _recognitionEpoch;

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

    _runModelInference(() async {
      await model.run(input, output);
      if (!_isRunning ||
          _isPaused ||
          epoch != _recognitionEpoch ||
          (_mode != RecognitionMode.alphabet &&
              _mode != RecognitionMode.auto)) {
        return;
      }

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

        // Three stable, rate-limited inference results suppress frame flicker
        // without waiting for every camera frame to run the model.
        if (_alphaCandidateCount >= _alphabetStableInferences &&
            letter != _alphaEmittedLabel) {
          final predictionTime = DateTime.now();
          _alphaEmittedLabel = letter;
          _predictionsController.add(
            SignResult(
              label: letter,
              confidence: top1Prob,
              timestamp: predictionTime,
              source: 'fsl_alphabet_model',
            ),
          );
        }
      } else {
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _alphaReleaseFrameCount++;
        // Require a sustained uncertain/released hand before re-arming the
        // same letter. Brief confidence dips no longer append A repeatedly.
        if (_alphaReleaseFrameCount >= 6) {
          _alphaEmittedLabel = null;
          _alphaProbHistory.clear();
        }
      }
    });
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

    final cameraPose = poseLandmarks
        .map(_transformLandmark)
        .map((point) => Offset(point.$1, point.$2))
        .toList(growable: false);
    final cameraHands = hands
        .map(
          (hand) => hand
              .map((point) => Offset(point.$1, point.$2))
              .toList(growable: false),
        )
        .toList(growable: false);

    _sequenceBuffer.add(currentJoints);
    if (_sequenceBuffer.length > _targetSequenceLength) {
      _sequenceBuffer.removeAt(0);
    }
    final previous = _latestGraphFrame;
    final frame = RecognitionGraphFrame(
      capturedAt: DateTime.now(),
      pose: cameraPose,
      hands: cameraHands,
      normalizedJoints: currentJoints
          .map(List<double>.unmodifiable)
          .toList(growable: false),
      sequenceLength: _sequenceBuffer.length,
      modelName: previous?.modelName,
      inferenceLatencyMs: previous?.inferenceLatencyMs,
      scores: previous?.scores ?? const [],
    );
    _latestGraphFrame = frame;
    _graphFrameController.add(frame);
  }

  void _publishGraphInference(
    String modelName,
    int latencyMs,
    List<double> probabilities,
    List<String> labels,
  ) {
    final frame = _latestGraphFrame;
    if (frame == null || probabilities.length != labels.length) return;
    final indices = List<int>.generate(labels.length, (index) => index)
      ..sort((a, b) => probabilities[b].compareTo(probabilities[a]));
    final scores = indices
        .take(3)
        .map((index) => RecognitionScore(labels[index], probabilities[index]))
        .toList(growable: false);
    final updated = frame.withInference(
      modelName: modelName,
      latencyMs: latencyMs,
      scores: scores,
    );
    _latestGraphFrame = updated;
    _graphFrameController.add(updated);
  }

  /// Runs the label-map-sized ST-GCN conversational model on a sequence buffer.
  void _evaluateConversationalSign() {
    final model = _fslModelInterpreter;
    if (model == null ||
        _fslLabels.isEmpty ||
        _isPaused ||
        _modelsReloading ||
        _phraseGestureConsumed ||
        _modelInferenceInFlight ||
        _sequenceBuffer.length < 24 ||
        !_hasRecentGestureActivity) {
      return;
    }

    final now = DateTime.now();
    if (_lastPhraseInferenceAt != null &&
        now.difference(_lastPhraseInferenceAt!) < _phraseInferenceInterval) {
      return;
    }
    _lastPhraseInferenceAt = now;
    final epoch = _recognitionEpoch;
    // Flatten to a typed float buffer before sending to the worker. This avoids
    // thousands of short-lived nested lists on the camera/UI isolate.
    final input = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
    final output = [List<double>.filled(_fslLabels.length, 0.0)];

    _runModelInference(() async {
      final inferenceTimer = Stopwatch()..start();
      await model.run(input, output);
      final routeStillPhrase =
          _mode == RecognitionMode.phrases ||
          (_mode == RecognitionMode.auto &&
              (_lastTrackedHandCount >= 2 || _motionRouteActive));
      if (!_isRunning ||
          _isPaused ||
          _modelsReloading ||
          epoch != _recognitionEpoch ||
          !routeStillPhrase ||
          _phraseGestureConsumed) {
        return;
      }

      final rawProbs = output[0];
      if (rawProbs.length != _fslLabels.length ||
          rawProbs.any((probability) => !probability.isFinite)) {
        debugPrint(
          '[TfliteRecognitionService] Phrase model output count does not match its labels.',
        );
        return;
      }
      _fslProbHistory.add(List<double>.from(rawProbs));
      if (_fslProbHistory.length > _phraseProbHistorySize) {
        _fslProbHistory.removeAt(0);
      }

      final probs = List<double>.filled(_fslLabels.length, 0.0);
      for (final frameProbs in _fslProbHistory) {
        for (var i = 0; i < frameProbs.length; i++) {
          probs[i] += frameProbs[i] / _fslProbHistory.length;
        }
      }

      var selectedLabels = _fslLabels;
      var selectedProbs = probs;
      var selectedModelName = 'ST-GCN · FSL phrases';
      var isExtensionPrediction = false;
      final extensionModel = _phraseExtensionInterpreter;
      if (extensionModel != null &&
          _phraseExtensionLabels.length == _phraseExtensionClassCount) {
        final extensionInput = _resampleSequence(
          _sequenceBuffer,
          _phraseExtensionSequenceLength,
        );
        final extensionOutput = [
          List<double>.filled(_phraseExtensionClassCount, 0.0),
        ];
        try {
          await extensionModel.run(extensionInput, extensionOutput);
        } catch (error) {
          debugPrint(
            '[TfliteRecognitionService] Phrase extension inference failed; '
            'using the existing phrase model: $error',
          );
          _phraseExtensionProbHistory.clear();
          if (identical(_phraseExtensionInterpreter, extensionModel)) {
            _phraseExtensionInterpreter = null;
            await _closeModel(extensionModel);
          }
        }
        final extensionRaw = extensionOutput[0];
        if (extensionRaw.length == _phraseExtensionClassCount &&
            extensionRaw.every((probability) => probability.isFinite)) {
          _phraseExtensionProbHistory.add(List<double>.from(extensionRaw));
          if (_phraseExtensionProbHistory.length > _phraseProbHistorySize) {
            _phraseExtensionProbHistory.removeAt(0);
          }
          final extensionProbs = List<double>.filled(
            _phraseExtensionClassCount,
            0.0,
          );
          for (final frameProbs in _phraseExtensionProbHistory) {
            for (var i = 0; i < frameProbs.length; i++) {
              extensionProbs[i] +=
                  frameProbs[i] / _phraseExtensionProbHistory.length;
            }
          }
          final extensionBest = _topTwo(extensionProbs);
          final extensionLabel = _phraseExtensionLabels[extensionBest.$1];
          final labelAlreadySupported = _fslLabels.any(
            (label) =>
                _normalizePhraseLabel(label) ==
                _normalizePhraseLabel(extensionLabel),
          );
          // Keep current classes on the established model. The new model only
          // contributes labels that the shipped 103-class head cannot emit.
          // A stricter confidence and margin gate limits unvalidated additions.
          if (!labelAlreadySupported &&
              _passesPhraseExtensionConfidenceGate(
                extensionBest.$2,
                extensionBest.$3,
              )) {
            selectedLabels = _phraseExtensionLabels;
            selectedProbs = extensionProbs;
            selectedModelName = 'ST-GCN · FSL phrase extension';
            isExtensionPrediction = true;
          }
        } else {
          debugPrint(
            '[TfliteRecognitionService] Ignoring invalid phrase extension output.',
          );
        }
      }
      inferenceTimer.stop();
      _publishGraphInference(
        selectedModelName,
        inferenceTimer.elapsedMilliseconds,
        selectedProbs,
        selectedLabels,
      );
      final best = _topTwo(selectedProbs);
      final top1Idx = best.$1;
      final top1Prob = best.$2;
      final top2Prob = best.$3;
      final passesConfidence = isExtensionPrediction
          ? _passesPhraseExtensionConfidenceGate(top1Prob, top2Prob)
          : _passesPaperConfidenceGate(top1Prob, top2Prob);

      if (passesConfidence) {
        final displayWord = _formatFslPhrase(selectedLabels[top1Idx]);
        if (displayWord == _fslCandidate) {
          _fslCandidateCount++;
        } else {
          _fslCandidate = displayWord;
          _fslCandidateCount = 1;
        }

        if (_fslCandidateCount >= _phraseStableInferences) {
          final predictionTime = DateTime.now();
          _phraseGestureConsumed = true;
          _predictionsController.add(
            SignResult(
              label: displayWord,
              confidence: top1Prob,
              timestamp: predictionTime,
              source: isExtensionPrediction
                  ? 'st_gcn_phrase_extension'
                  : 'st_gcn_model',
            ),
          );
        }
      } else {
        _fslCandidate = null;
        _fslCandidateCount = 0;
      }
    });
  }

  static String _normalizePhraseLabel(String label) =>
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static (int, double, double) _topTwo(List<double> probabilities) {
    var topIndex = 0;
    var topProbability = double.negativeInfinity;
    var secondProbability = double.negativeInfinity;
    for (var i = 0; i < probabilities.length; i++) {
      final probability = probabilities[i];
      if (probability > topProbability) {
        secondProbability = topProbability;
        topProbability = probability;
        topIndex = i;
      } else if (probability > secondProbability) {
        secondProbability = probability;
      }
    }
    return (topIndex, topProbability, secondProbability);
  }

  /// Formats raw FSL class names to clear, user-friendly labels with English translations
  static String _formatFslPhrase(String sign) {
    switch (sign.trim()) {
      case 'Kamusta':
        return 'Kamusta (Hello)';
      case 'Anxiety':
        return 'Pagkabalisa (Anxiety)';
      case 'Depression':
        return 'Depresyon (Depression)';
      case 'Inflammation':
        return 'Pamamaga (Inflammation)';
      case 'Sneezing':
        return 'Bahing (Sneezing)';
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
    final model = _medicalModelInterpreter;
    if (model == null ||
        _medicalLabels.isEmpty ||
        _isPaused ||
        _modelsReloading ||
        _medicalGestureConsumed ||
        _modelInferenceInFlight ||
        _sequenceBuffer.length < 24 ||
        !_hasRecentGestureActivity) {
      return;
    }

    final now = DateTime.now();
    if (_lastMedicalInferenceAt != null &&
        now.difference(_lastMedicalInferenceAt!) < _medicalInferenceInterval) {
      return;
    }
    _lastMedicalInferenceAt = now;
    final epoch = _recognitionEpoch;
    final input = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
    final output = [List<double>.filled(_medicalLabels.length, 0.0)];

    _runModelInference(() async {
      final inferenceTimer = Stopwatch()..start();
      await model.run(input, output);
      inferenceTimer.stop();
      if (!_isRunning ||
          _isPaused ||
          _modelsReloading ||
          epoch != _recognitionEpoch ||
          _mode != RecognitionMode.medical ||
          _medicalGestureConsumed) {
        return;
      }

      final rawProbs = output[0];
      if (rawProbs.length != _medicalLabels.length) {
        debugPrint(
          '[TfliteRecognitionService] Medical model output count does not match its labels.',
        );
        return;
      }
      _medProbHistory.add(List<double>.from(rawProbs));
      if (_medProbHistory.length > _phraseProbHistorySize) {
        _medProbHistory.removeAt(0);
      }

      final probs = List<double>.filled(_medicalLabels.length, 0.0);
      for (final frameProbs in _medProbHistory) {
        for (var i = 0; i < frameProbs.length; i++) {
          probs[i] += frameProbs[i] / _medProbHistory.length;
        }
      }
      _publishGraphInference(
        'ST-GCN · Medical FSL',
        inferenceTimer.elapsedMilliseconds,
        probs,
        _medicalLabels,
      );

      var top1Idx = 0;
      var top1Prob = probs[0];
      var top2Prob = 0.0;
      for (var i = 1; i < probs.length; i++) {
        if (probs[i] > top1Prob) {
          top2Prob = top1Prob;
          top1Prob = probs[i];
          top1Idx = i;
        } else if (probs[i] > top2Prob) {
          top2Prob = probs[i];
        }
      }

      if (_passesPaperConfidenceGate(top1Prob, top2Prob)) {
        final rawWord = _medicalLabels[top1Idx];
        // Avoid displaying unresolved outputs if a future bundle still has
        // placeholder names in its label map.
        if (RegExp(r'^Medical_\d+$').hasMatch(rawWord)) {
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

        if (_medCandidateCount >= _phraseStableInferences) {
          final predictionTime = DateTime.now();
          _medicalGestureConsumed = true;
          _predictionsController.add(
            SignResult(
              label: displayWord,
              confidence: top1Prob,
              timestamp: predictionTime,
              source: 'fsl_medical_model',
            ),
          );
        }
      } else {
        _medCandidate = null;
        _medCandidateCount = 0;
      }
    });
  }

  /// Formats raw medical signs to bilingual clinical & patient-friendly labels
  static String _formatMedicalPhrase(String sign) {
    const translations = {
      'Alin': 'Which',
      'Allergic': 'Allergy',
      'Ano': 'What',
      'Bahing': 'Sneezing',
      'Doktor': 'Doctor',
      'Edad': 'Age',
      'Ikaw': 'You',
      'Ilan': 'How many',
      'Kailan': 'When',
      'Lagnat': 'Fever',
      'Magkano': 'How much',
      'Nahihilo': 'Dizzy',
      'Nahihirapan Huminga': 'Shortness of breath',
      'Pakiramdam': 'Condition / feeling',
      'Salamat': 'Thank you',
      'Sino': 'Who',
      'Sipon': 'Cold / runny nose',
      'Anxiety': 'Anxiety',
      'Bakit': 'Why',
      'Depresyon': 'Depression',
      'Dumudugo': 'Bleeding',
      'Gamot': 'Medicine',
      'Mahapdi': 'Stinging / painful',
      'Makati': 'Itchy',
      'Masakit': 'Painful',
      'Masakit ang Ulo': 'Headache',
      'Nurse': 'Nurse',
      'Paano': 'How',
      'Paghinga': 'Breathing',
      'Pagod': 'Tired',
      'Pamamaga': 'Swelling',
      'Pangalan': 'Name',
      'Saan': 'Where',
      'Sakit': 'Illness / pain',
      'Tensiyon': 'Blood pressure',
    };
    final clean = sign.trim();
    final translation = translations[clean];
    return translation == null ? clean : '$clean ($translation)';
  }

  /// Linearly resamples buffer to exact 60-frame ST-GCN tensor input with true linear interpolation
  Uint8List _resampleSequence(
    List<List<List<double>>> sequence,
    int targetLength,
  ) {
    final n = sequence.length;
    final values = Float32List(targetLength * _totalJoints * 3);
    if (n == 0) return Uint8List.view(values.buffer);

    for (int i = 0; i < targetLength; i++) {
      final pos = n <= 1 ? 0.0 : i * (n - 1) / (targetLength - 1);
      final lower = pos.floor();
      final upper = pos.ceil();
      final alpha = pos - lower;
      for (var j = 0; j < _totalJoints; j++) {
        final p0 = sequence[lower][j];
        final p1 = sequence[upper][j];
        final offset = (i * _totalJoints + j) * 3;
        values[offset] = (1.0 - alpha) * p0[0] + alpha * p1[0];
        values[offset + 1] = (1.0 - alpha) * p0[1] + alpha * p1[1];
        values[offset + 2] = (1.0 - alpha) * p0[2] + alpha * p1[2];
      }
    }
    return Uint8List.view(values.buffer);
  }

  @override
  void dispose() {
    _isRunning = false;
    _isInitialized = false;
    _recognitionEpoch++;
    _poseRequestGeneration++;
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
    _graphFrameController.close();
    final models = [
      _alphabetInterpreter,
      _fslModelInterpreter,
      _phraseExtensionInterpreter,
      _medicalModelInterpreter,
    ];
    _alphabetInterpreter = null;
    _fslModelInterpreter = null;
    _phraseExtensionInterpreter = null;
    _medicalModelInterpreter = null;
    unawaited(_disposeModels(models));
  }

  Future<void> _disposeModels(List<_ModelRunner?> models) async {
    while (_modelInferenceInFlight) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future.wait<void>(models.map(_closeModel));
  }
}

class _ModelRunner {
  _ModelRunner(this.interpreter, this.worker);

  final Interpreter interpreter;
  final IsolateInterpreter worker;

  Future<void> run(Object input, Object output) => worker.run(input, output);
}

class _PoseFrame {
  const _PoseFrame({
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.rotation,
  });

  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int rotation;
}
