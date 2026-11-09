import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:hand_landmarker/hand_landmarker.dart';
import 'package:tinigsenyas/models/sign_result.dart';
import 'recognition_service.dart';

class TfliteRecognitionService implements RecognitionService {
  final _predictionsController = StreamController<SignResult>.broadcast();
  final _pauseStatusController = StreamController<bool>.broadcast();
  final _landmarkStreamController = StreamController<List<List<Offset>>>.broadcast();

  Interpreter? _fslModelInterpreter;
  Interpreter? _alphabetInterpreter;
  Interpreter? _medicalModelInterpreter;
  HandLandmarkerPlugin? _handLandmarker;
  StreamSubscription<List<Hand>>? _handSubscription;

  List<String> _fslLabels = [];
  List<String> _medicalLabels = [];
  final List<String> _alphabetLabels = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'Ng', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Ñ'
  ];

  RecognitionMode _mode = RecognitionMode.auto;
  @override
  RecognitionMode get mode => _mode;
  @override
  set mode(RecognitionMode val) => _mode = val;

  Offset? _lastWrist;
  final List<double> _motionHistory = [];

  // Exponential Moving Average (EMA) landmark smoothing
  List<(double, double, double)>? _smoothedPrimaryHand;
  List<(double, double, double)>? _smoothedSecondaryHand;
  static const double _handSmoothAlpha = 0.80;

  // Rolling Softmax Probability Distribution Smoothing
  final List<List<double>> _fslProbHistory = [];
  final List<List<double>> _medProbHistory = [];
  static const int _probHistorySize = 5;

  bool _isInitialized = false;
  bool _isRunning = false;
  bool _isPaused = false;
  bool _isProcessingFrame = false;

  // Frame sequence buffer for 60-frame ST-GCN conversational model
  final List<List<List<double>>> _sequenceBuffer = [];
  static const int _targetSequenceLength = 60;
  static const int _totalJoints = 75;

  // Debouncing / Stability state
  String? _lastEmittedLabel;
  DateTime _lastEmittedTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? _alphaCandidate;
  int _alphaCandidateCount = 0;
  String? _fslCandidate;
  int _fslCandidateCount = 0;
  String? _medCandidate;
  int _medCandidateCount = 0;

  // Trajectory tracking for dynamic fingerspelled letter 'J'
  final List<(double, double, bool)> _jTrajectory = [];
  int _jCooldown = 0;

  // Natural Rest Zone state
  bool _manualPaused = false;
  int _restZoneFrameCount = 0;
  static const int _restZoneThreshold = 15; // ~500ms of sustained hands at rest

  @override
  bool get isModelReady => _isInitialized && _alphabetInterpreter != null;

  @override
  bool get isPaused => _isPaused;

  @override
  void setPaused(bool value) {
    _manualPaused = value;
    _isPaused = value;
    _pauseStatusController.add(value);
    if (value) {
      _sequenceBuffer.clear();
      _fslProbHistory.clear();
      _medProbHistory.clear();
      _smoothedPrimaryHand = null;
      _smoothedSecondaryHand = null;
      _alphaCandidate = null;
      _alphaCandidateCount = 0;
      _fslCandidate = null;
      _fslCandidateCount = 0;
      _medCandidate = null;
      _medCandidateCount = 0;
    }
  }

  @override
  Stream<bool>? get pauseStatus => _pauseStatusController.stream;

  @override
  Stream<List<List<Offset>>>? get landmarkPointsStream => _landmarkStreamController.stream;

  @override
  Stream<SignResult> get predictions => _predictionsController.stream;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await reloadModels();

      if (!kIsWeb && Platform.isAndroid) {
        try {
          _handLandmarker = HandLandmarkerPlugin.create(
            numHands: 2,
            minHandDetectionConfidence: 0.5,
            delegate: HandLandmarkerDelegate.gpu,
          );
        } catch (e) {
          debugPrint('[TfliteRecognitionService] GPU delegate failed, trying CPU: $e');
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

      // 1. Load FSL Conversational Labels (103 classes)
      final localLabelsFile = modelsDir != null ? File(p.join(modelsDir.path, 'labels.txt')) : null;
      if (localLabelsFile != null && await localLabelsFile.exists()) {
        final content = await localLabelsFile.readAsString();
        _fslLabels = content.split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else {
        final bundledLabels = await rootBundle.loadString('assets/model/labels.txt');
        _fslLabels = bundledLabels.split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      // 2. Load Alphabet Model (fsl_alphabet.tflite)
      _alphabetInterpreter?.close();
      _alphabetInterpreter = null;
      final localAlphaFile = modelsDir != null ? File(p.join(modelsDir.path, 'fsl_alphabet.tflite')) : null;
      final options = InterpreterOptions()..threads = 2;

      if (localAlphaFile != null && await localAlphaFile.exists()) {
        _alphabetInterpreter = Interpreter.fromFile(localAlphaFile, options: options);
      } else {
        _alphabetInterpreter = await Interpreter.fromAsset('assets/model/fsl_alphabet.tflite', options: options);
      }

      // 3. Load Conversational ST-GCN Model (fsl_model.tflite)
      _fslModelInterpreter?.close();
      _fslModelInterpreter = null;
      final localModelFile = modelsDir != null ? File(p.join(modelsDir.path, 'fsl_model.tflite')) : null;
      final modelOptions = InterpreterOptions()..threads = 4;

      if (localModelFile != null && await localModelFile.exists()) {
        _fslModelInterpreter = Interpreter.fromFile(localModelFile, options: modelOptions);
      } else {
        try {
          _fslModelInterpreter = await Interpreter.fromAsset('assets/model/fsl_model.tflite', options: modelOptions);
        } catch (e) {
          debugPrint('[TfliteRecognitionService] Conversational model load note: $e');
        }
      }

      // 4. Load Medical ST-GCN Model (fsl_medical.tflite) and Labels
      final localMedLabelsFile = modelsDir != null ? File(p.join(modelsDir.path, 'medical_labels.txt')) : null;
      if (localMedLabelsFile != null && await localMedLabelsFile.exists()) {
        final content = await localMedLabelsFile.readAsString();
        _medicalLabels = content.split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else {
        try {
          final bundledLabels = await rootBundle.loadString('assets/model/medical_labels.txt');
          _medicalLabels = bundledLabels.split(RegExp(r'\r?\n')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        } catch (e) {
          debugPrint('[TfliteRecognitionService] Bundled medical labels note: $e');
        }
      }

      _medicalModelInterpreter?.close();
      _medicalModelInterpreter = null;
      final localMedModelFile = modelsDir != null ? File(p.join(modelsDir.path, 'fsl_medical.tflite')) : null;
      if (localMedModelFile != null && await localMedModelFile.exists()) {
        _medicalModelInterpreter = Interpreter.fromFile(localMedModelFile, options: modelOptions);
      } else {
        try {
          _medicalModelInterpreter = await Interpreter.fromAsset('assets/model/fsl_medical.tflite', options: modelOptions);
        } catch (e) {
          debugPrint('[TfliteRecognitionService] Medical model load note: $e');
        }
      }

      debugPrint('[TfliteRecognitionService] Models reloaded successfully. Labels: ${_fslLabels.length}, Alphabet: ${_alphabetLabels.length}, Medical: ${_medicalLabels.length}');
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
        _handleDetectedHands,
        onError: (err) {
          debugPrint('[TfliteRecognitionService] Landmarker stream error: $err');
        },
      );
    }
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _handSubscription?.cancel();
    _handSubscription = null;
    _sequenceBuffer.clear();
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

    if (sensorOrientation != null) _sensorOrientation = sensorOrientation;
    if (isFrontCamera != null) _isFrontCamera = isFrontCamera;

    if (_handLandmarker != null) {
      _isProcessingFrame = true;
      try {
        _handLandmarker!.processFrame(image, _sensorOrientation);
      } catch (e) {
        debugPrint('[TfliteRecognitionService] processFrame error: $e');
      } finally {
        _isProcessingFrame = false;
      }
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

  void _handleDetectedHands(List<Hand> hands) {
    if (!_isRunning) return;

    if (hands.isEmpty) {
      _landmarkStreamController.add([]);
      _alphaCandidateCount = 0;
      _alphaCandidate = null;
      _smoothedPrimaryHand = null;
      _smoothedSecondaryHand = null;
      _fslProbHistory.clear();
      _medProbHistory.clear();
      if (_sequenceBuffer.isNotEmpty && _sequenceBuffer.length > 10) {
        _sequenceBuffer.removeAt(0);
      }

      // Natural Rest Zone: hands lowered out of camera frame
      _restZoneFrameCount++;
      if (_restZoneFrameCount >= _restZoneThreshold) {
        if (!_isPaused && !_manualPaused) {
          _isPaused = true;
          _pauseStatusController.add(true);
        }
        _sequenceBuffer.clear();
      }
      return;
    }

    // 1. Transform raw sensor landmarks to upright screen space
    final transformedHands = hands.map((h) {
      return h.landmarks.map((lm) => _transformLandmark(lm)).toList();
    }).toList();

    // 2. Stream 2D offsets for the live camera skeleton overlay
    final overlayHands = transformedHands.map((h) {
      return h.map((pt) => Offset(pt.$1, pt.$2)).toList();
    }).toList();
    _landmarkStreamController.add(overlayHands);

    final primaryHand = transformedHands.first;
    if (primaryHand.length < 21) return;

    // Apply EMA smoothing to eliminate camera frame micro-jitter
    final smoothedPrimary = _applyEmaSmoothing(primaryHand, _smoothedPrimaryHand);
    _smoothedPrimaryHand = smoothedPrimary;
    final List<(double, double, double)>? smoothedSecondary;
    if (transformedHands.length > 1 && transformedHands[1].length >= 21) {
      smoothedSecondary = _applyEmaSmoothing(transformedHands[1], _smoothedSecondaryHand);
      _smoothedSecondaryHand = smoothedSecondary;
    } else {
      _smoothedSecondaryHand = null;
      smoothedSecondary = null;
    }
    final smoothedHands = [smoothedPrimary, ?smoothedSecondary];

    // 3. Natural Rest Zone Check:
    // Check if hands have dropped below active signing zone (wrist y >= 0.82)
    final bool allHandsRestingLow = transformedHands.every((hand) {
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
        _fslProbHistory.clear();
        _medProbHistory.clear();
        _smoothedPrimaryHand = null;
        _smoothedSecondaryHand = null;
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _fslCandidate = null;
        _fslCandidateCount = 0;
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
    if (_lastWrist != null) {
      final dx = wrist.$1 - _lastWrist!.dx;
      final dy = wrist.$2 - _lastWrist!.dy;
      currentMotion = math.sqrt(dx * dx + dy * dy);
    }
    _lastWrist = Offset(wrist.$1, wrist.$2);
    _motionHistory.add(currentMotion);
    if (_motionHistory.length > 8) _motionHistory.removeAt(0);
    final avgMotion = _motionHistory.reduce((a, b) => a + b) / _motionHistory.length;
    final isHandMoving = avgMotion >= 0.012;

    // 5. Accumulate continuous ST-GCN sequence frame buffer
    _accumulateSequenceFrame(smoothedHands);

    // 6. Dynamic Letter 'J' Kinematic Detector:
    // In FSL, 'J' is traced dynamically in the air using an 'I' handshape (downward stroke + upward hook).
    if (_jCooldown > 0) _jCooldown--;
    if (!_isPaused && smoothedHands.length == 1 && _mode != RecognitionMode.phrases && _mode != RecognitionMode.medical) {
      final isI = _checkIsIHandshape(smoothedPrimary);
      final pinkyTip = smoothedPrimary[20];
      _jTrajectory.add((pinkyTip.$1, pinkyTip.$2, isI));
      if (_jTrajectory.length > 30) _jTrajectory.removeAt(0);

      if (_jCooldown == 0 && _detectJGesture()) {
        _jCooldown = 24; // Debounce ~0.8s
        _jTrajectory.clear();
        _sequenceBuffer.clear();
        _alphaCandidate = 'J';
        _alphaCandidateCount = 2;
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
      _evaluateConversationalSign(avgMotion);
    } else if (_mode == RecognitionMode.medical) {
      _evaluateMedicalSign(avgMotion);
    } else {
      // Auto Mode:
      // FSL Alphabet fingerspelling is strictly 1-handed.
      // If 2 hands are raised in active signing space, route to ST-GCN phrases.
      if (smoothedHands.length >= 2) {
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _evaluateConversationalSign(avgMotion);
      } else if (isHandMoving) {
        // Dynamic single-hand movement: route to ST-GCN conversational phrases
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _evaluateConversationalSign(avgMotion);
      } else {
        // Hand held steady: evaluate Alphabet Fingerspelling (A-Z)
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
    final pinkyExtended = (pinkyTip.$2 < pinkyPip.$2) && (pinkyTip.$2 < pinkyMcp.$2);

    // Other three fingers curled down:
    final indexCurled = indexTip.$2 > (indexPip.$2 - 0.03);
    final middleCurled = middleTip.$2 > (middlePip.$2 - 0.03);
    final ringCurled = ringTip.$2 > (ringPip.$2 - 0.03);

    // Pinky tip noticeably higher on screen than curled fingertips
    final pinkyDominant = (
      pinkyTip.$2 < indexTip.$2 - 0.035 &&
      pinkyTip.$2 < middleTip.$2 - 0.035 &&
      pinkyTip.$2 < ringTip.$2 - 0.035
    );

    return pinkyExtended && indexCurled && middleCurled && ringCurled && pinkyDominant;
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
      final probs = output[0];

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

      // Calibrated gating: confidence >= 0.42 and margin >= 0.03
      final margin = top1Prob - top2Prob;
      if (top1Prob >= 0.42 && margin >= 0.03 && top1Idx < _alphabetLabels.length) {
        final letter = _alphabetLabels[top1Idx];
        if (letter == _alphaCandidate) {
          _alphaCandidateCount++;
        } else {
          _alphaCandidate = letter;
          _alphaCandidateCount = 1;
        }

        // 2 consecutive stable frames for snappy, responsive letters
        if (_alphaCandidateCount >= 2) {
          final now = DateTime.now();
          final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
          final isSameLetter = (letter == _lastEmittedLabel);
          final requiredDelay = isSameLetter ? 1200 : 500;

          if (elapsed > requiredDelay) {
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
        }
      } else {
        _alphaCandidateCount = math.max(0, _alphaCandidateCount - 1);
      }
    } catch (e) {
      debugPrint('[TfliteRecognitionService] Alphabet inference error: $e');
    }
  }

  /// Transforms screen landmarks to unmirrored world coordinates and builds canonical ST-GCN joint frame
  void _accumulateSequenceFrame(List<List<(double, double, double)>> hands) {
    if (hands.isEmpty) return;

    final currentJoints = List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0]);

    // Unmirror X for front camera to match the world space of the training dataset
    (double, double, double) toWorld((double, double, double) pt) {
      final wx = _isFrontCamera ? (1.0 - pt.$1) : pt.$1;
      return (wx, pt.$2, pt.$3);
    }

    // Normalizes point relative to mid-shoulder (0.50, 0.65) and shoulder width (0.22)
    List<double> normJoint((double, double, double) pt) {
      return [
        (pt.$1 - 0.50) / 0.22,
        (pt.$2 - 0.65) / 0.22,
        pt.$3 / 0.22,
      ];
    }

    final worldHands = hands.map((h) => h.map(toWorld).toList()).toList();

    List<(double, double, double)> rightHand;
    List<(double, double, double)>? leftHand;

    if (worldHands.length >= 2) {
      final hand0 = worldHands[0];
      final hand1 = worldHands[1];
      final meanX0 = hand0.map((p) => p.$1).reduce((a, b) => a + b) / hand0.length;
      final meanX1 = hand1.map((p) => p.$1).reduce((a, b) => a + b) / hand1.length;

      // In unmirrored world space, signer's right is on image left (lower x), left is on image right (higher x)
      if (meanX0 < meanX1) {
        rightHand = hand0;
        leftHand = hand1;
      } else {
        rightHand = hand1;
        leftHand = hand0;
      }
    } else {
      rightHand = worldHands[0];
      leftHand = null;
    }

    // Assign Right Hand joints to slot 54..74
    for (int i = 0; i < 21 && i < rightHand.length; i++) {
      currentJoints[54 + i] = normJoint(rightHand[i]);
    }

    // Assign Left Hand joints to slot 33..53 if present
    if (leftHand != null) {
      for (int i = 0; i < 21 && i < leftHand.length; i++) {
        currentJoints[33 + i] = normJoint(leftHand[i]);
      }
    }

    // Synthetic canonical pose landmarks in slots 0..32 matching ST-GCN graph topology:
    currentJoints[0] = [0.0, -0.95, -0.1];  // Head / Nose
    currentJoints[11] = [0.50, 0.0, 0.0];   // Left Shoulder
    currentJoints[12] = [-0.50, 0.0, 0.0];  // Right Shoulder
    currentJoints[23] = [0.40, 1.8, 0.0];   // Left Hip
    currentJoints[24] = [-0.40, 1.8, 0.0];  // Right Hip

    // Connect Right arm chain (Right shoulder 12 -> Right elbow 14 -> Right wrist 16 -> Right hand 54)
    currentJoints[16] = List<double>.from(currentJoints[54]);
    currentJoints[14] = [
      (currentJoints[12][0] + currentJoints[16][0]) / 2.0,
      (currentJoints[12][1] + currentJoints[16][1]) / 2.0,
      (currentJoints[12][2] + currentJoints[16][2]) / 2.0,
    ];

    // Connect Left arm chain (Left shoulder 11 -> Left elbow 13 -> Left wrist 15 -> Left hand 33)
    if (leftHand != null) {
      currentJoints[15] = List<double>.from(currentJoints[33]);
    } else {
      // Resting position when left hand is idle during single-handed sign
      currentJoints[15] = [0.55, 0.90, 0.0];
    }
    currentJoints[13] = [
      (currentJoints[11][0] + currentJoints[15][0]) / 2.0,
      (currentJoints[11][1] + currentJoints[15][1]) / 2.0,
      (currentJoints[11][2] + currentJoints[15][2]) / 2.0,
    ];

    _sequenceBuffer.add(currentJoints);
    if (_sequenceBuffer.length > _targetSequenceLength) {
      _sequenceBuffer.removeAt(0);
    }
  }

  /// Runs 103-class ST-GCN conversational model on continuous sequence buffer
  void _evaluateConversationalSign(double avgMotion) {
    if (_fslModelInterpreter == null || _fslLabels.isEmpty || _isPaused) return;

    // Require at least 24 frames of continuous gesture buffer (~0.8s) and active kinetic movement
    if (_sequenceBuffer.length >= 24 && avgMotion >= 0.005) {
      try {
        final seqInput = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
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

        final margin = top1Prob - top2Prob;
        if ((top1Prob >= 0.55 || (top1Prob >= 0.44 && margin >= 0.05)) && top1Idx < _fslLabels.length) {
          final rawWord = _fslLabels[top1Idx];
          final displayWord = _formatFslPhrase(rawWord);

          if (displayWord == _fslCandidate) {
            _fslCandidateCount++;
          } else {
            _fslCandidate = displayWord;
            _fslCandidateCount = 1;
          }

          // Require 2 consecutive evaluations for responsive and stable recognition
          if (_fslCandidateCount >= 2) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
            final isSameWord = (displayWord == _lastEmittedLabel);
            final requiredDelay = isSameWord ? 2200 : 900;

            if (elapsed > requiredDelay) {
              _lastEmittedLabel = displayWord;
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
          _fslCandidateCount = math.max(0, _fslCandidateCount - 1);
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

  /// Evaluates 60-frame ST-GCN sequence using dedicated 25-class Medical FSL model
  void _evaluateMedicalSign(double avgMotion) {
    if (_medicalModelInterpreter == null || _medicalLabels.isEmpty || _isPaused) return;

    if (_sequenceBuffer.length >= 24 && avgMotion >= 0.005) {
      try {
        final seqInput = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
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

        final margin = top1Prob - top2Prob;
        if ((top1Prob >= 0.55 || (top1Prob >= 0.44 && margin >= 0.05)) && top1Idx < _medicalLabels.length) {
          final rawWord = _medicalLabels[top1Idx];
          final displayWord = _formatMedicalPhrase(rawWord);

          if (displayWord == _medCandidate) {
            _medCandidateCount++;
          } else {
            _medCandidate = displayWord;
            _medCandidateCount = 1;
          }

          if (_medCandidateCount >= 2) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
            final isSameWord = (displayWord == _lastEmittedLabel);
            final requiredDelay = isSameWord ? 2200 : 900;

            if (elapsed > requiredDelay) {
              _lastEmittedLabel = displayWord;
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
          _medCandidateCount = math.max(0, _medCandidateCount - 1);
        }
      } catch (e) {
        debugPrint('[TfliteRecognitionService] Medical ST-GCN inference error: $e');
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
  List<List<List<double>>> _resampleSequence(List<List<List<double>>> sequence, int targetLength) {
    final n = sequence.length;
    if (n == targetLength) return sequence;
    if (n <= 1) {
      return List.generate(
        targetLength,
        (_) => sequence.isEmpty ? List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0]) : sequence.first,
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
    _predictionsController.close();
    _pauseStatusController.close();
    _landmarkStreamController.close();
    _alphabetInterpreter?.close();
    _fslModelInterpreter?.close();
    _medicalModelInterpreter?.close();
  }
}
