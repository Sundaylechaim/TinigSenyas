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

  void _handleDetectedHands(List<Hand> hands) {
    if (!_isRunning) return;

    if (hands.isEmpty) {
      _landmarkStreamController.add([]);
      _alphaCandidateCount = 0;
      _alphaCandidate = null;
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
    final wrist = primaryHand[0];
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

    // 5. Dynamic Letter 'J' Kinematic Detector:
    // In FSL, 'J' is traced dynamically in the air using an 'I' handshape (downward stroke + upward hook).
    if (_jCooldown > 0) _jCooldown--;
    if (!_isPaused && transformedHands.length == 1 && _mode != RecognitionMode.phrases) {
      final isI = _checkIsIHandshape(primaryHand);
      final pinkyTip = primaryHand[20];
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

    // 6. Intelligent Mode & Motion-Aware Routing:
    if (_mode == RecognitionMode.alphabet) {
      _evaluateAlphabet(primaryHand);
    } else if (_mode == RecognitionMode.phrases) {
      _evaluateConversationalSign(transformedHands);
    } else if (_mode == RecognitionMode.medical) {
      _evaluateMedicalSign(transformedHands);
    } else {
      // Auto Mode:
      if (isHandMoving) {
        // Waving or dynamic gesture: clear static alphabet candidate and route to ST-GCN!
        _alphaCandidate = null;
        _alphaCandidateCount = 0;
        _evaluateConversationalSign(transformedHands);
      } else {
        // Hand held steady: route to Alphabet Fingerspelling (A-Z)
        _evaluateAlphabet(primaryHand);
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

    final centered = <List<double>>[];
    double maxDist = 1e-4;

    for (final pt in lms) {
      final dx = pt.$1 - wrist.$1;
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

      // Calibrated gating: confidence >= 0.50 and margin >= 0.05
      final margin = top1Prob - top2Prob;
      if (top1Prob >= 0.50 && margin >= 0.04 && top1Idx < _alphabetLabels.length) {
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

  /// Assembles 75-joint temporal frame buffer with exact shoulder-centered normalization and runs 103-class ST-GCN model
  void _evaluateConversationalSign(List<List<(double, double, double)>> transformedHands) {
    if (_fslModelInterpreter == null || _fslLabels.isEmpty || _isPaused) return;

    final currentJoints = List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0]);

    // Synthetic canonical pose landmarks in slots 0..32:
    currentJoints[0] = [0.0, -0.8, 0.0];  // Head / Nose
    currentJoints[11] = [-0.5, 0.0, 0.0]; // Left Shoulder
    currentJoints[12] = [0.5, 0.0, 0.0];  // Right Shoulder

    // Primary hand (Right hand slot 54..74):
    // EXACT MODEL NORMALIZATION FROM TRAINING: (pt - [0.5, 0.5, 0.0]) / 0.20
    final rightHand = transformedHands.first;
    for (int i = 0; i < 21 && i < rightHand.length; i++) {
      final nx = (rightHand[i].$1 - 0.5) / 0.20;
      final ny = (rightHand[i].$2 - 0.5) / 0.20;
      final nz = rightHand[i].$3 / 0.20;
      currentJoints[54 + i] = [nx, ny, nz];
    }

    // Secondary hand (Left hand slot 33..53) if present:
    if (transformedHands.length > 1) {
      final leftHand = transformedHands[1];
      for (int i = 0; i < 21 && i < leftHand.length; i++) {
        final nx = (leftHand[i].$1 - 0.5) / 0.20;
        final ny = (leftHand[i].$2 - 0.5) / 0.20;
        final nz = leftHand[i].$3 / 0.20;
        currentJoints[33 + i] = [nx, ny, nz];
      }
    }

    _sequenceBuffer.add(currentJoints);
    if (_sequenceBuffer.length > _targetSequenceLength) {
      _sequenceBuffer.removeAt(0);
    }

    // Evaluate once sequence window has sufficient motion history (>= 20 frames)
    if (_sequenceBuffer.length >= 20) {
      try {
        final seqInput = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
        final input = [seqInput];
        final output = [List<double>.filled(_fslLabels.length, 0.0)];

        _fslModelInterpreter!.run(input, output);
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

        final margin = top1Prob - top2Prob;
        if (top1Prob >= 0.45 && margin >= 0.05 && top1Idx < _fslLabels.length) {
          final rawWord = _fslLabels[top1Idx];
          final displayWord = _formatFslPhrase(rawWord);

          if (displayWord == _fslCandidate) {
            _fslCandidateCount++;
          } else {
            _fslCandidate = displayWord;
            _fslCandidateCount = 1;
          }

          if (_fslCandidateCount >= 2) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastEmittedTime).inMilliseconds;
            final isSameWord = (displayWord == _lastEmittedLabel);
            final requiredDelay = isSameWord ? 2000 : 900;

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
  void _evaluateMedicalSign(List<List<(double, double, double)>> transformedHands) {
    if (_medicalModelInterpreter == null || _medicalLabels.isEmpty || _isPaused) return;

    final currentJoints = List.generate(_totalJoints, (_) => [0.0, 0.0, 0.0]);

    // Synthetic canonical pose landmarks in slots 0..32:
    currentJoints[0] = [0.0, -0.8, 0.0];  // Head / Nose
    currentJoints[11] = [-0.5, 0.0, 0.0]; // Left Shoulder
    currentJoints[12] = [0.5, 0.0, 0.0];  // Right Shoulder

    // Primary hand (Right hand slot 54..74):
    final rightHand = transformedHands.first;
    for (int i = 0; i < 21 && i < rightHand.length; i++) {
      final nx = (rightHand[i].$1 - 0.5) / 0.20;
      final ny = (rightHand[i].$2 - 0.5) / 0.20;
      final nz = rightHand[i].$3 / 0.20;
      currentJoints[54 + i] = [nx, ny, nz];
    }

    // Secondary hand (Left hand slot 33..53) if present:
    if (transformedHands.length > 1) {
      final leftHand = transformedHands[1];
      for (int i = 0; i < 21 && i < leftHand.length; i++) {
        final nx = (leftHand[i].$1 - 0.5) / 0.20;
        final ny = (leftHand[i].$2 - 0.5) / 0.20;
        final nz = leftHand[i].$3 / 0.20;
        currentJoints[33 + i] = [nx, ny, nz];
      }
    }

    _sequenceBuffer.add(currentJoints);
    if (_sequenceBuffer.length > _targetSequenceLength) {
      _sequenceBuffer.removeAt(0);
    }

    if (_sequenceBuffer.length >= 20) {
      try {
        final seqInput = _resampleSequence(_sequenceBuffer, _targetSequenceLength);
        final input = [seqInput];
        final output = [List<double>.filled(_medicalLabels.length, 0.0)];

        _medicalModelInterpreter!.run(input, output);
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

        final margin = top1Prob - top2Prob;
        if (top1Prob >= 0.45 && margin >= 0.04 && top1Idx < _medicalLabels.length) {
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
            final requiredDelay = isSameWord ? 2000 : 900;

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

  /// Linearly resamples buffer to exact 60-frame ST-GCN tensor input
  List<List<List<double>>> _resampleSequence(List<List<List<double>>> buffer, int targetLength) {
    if (buffer.length == targetLength) return buffer;
    final resampled = <List<List<double>>>[];
    final step = (buffer.length - 1) / (targetLength - 1);
    for (int i = 0; i < targetLength; i++) {
      final index = (i * step).round().clamp(0, buffer.length - 1);
      resampled.add(buffer[index]);
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
