import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:tinigsenyas/models/sign_result.dart';
import 'package:tinigsenyas/services/settings_service.dart';
import 'recognition_service.dart';

class RecognitionProgress {
  final String status;
  final int framesCollected;
  final int sequenceLength;
  final List<List<List<double>>> handLandmarks;
  final int frameWidth;
  final int frameHeight;

  RecognitionProgress({
    required this.status,
    required this.framesCollected,
    required this.sequenceLength,
    required this.handLandmarks,
    required this.frameWidth,
    required this.frameHeight,
  });
}

class BackendRecognitionService implements RecognitionService {
  final String baseUrl;
  final SettingsService? settings;
  final Dio _dio;
  final _predictionsController = StreamController<SignResult>.broadcast();
  final _progressController = StreamController<RecognitionProgress>.broadcast();
  final _pauseStatusController = StreamController<bool>.broadcast();
  Timer? _pollingTimer;
  bool _isInitialized = false;
  bool _isRunning = false;
  bool _isPaused = false;
  RecognitionMode _mode = RecognitionMode.auto;

  @override
  RecognitionMode get mode => _mode;

  @override
  set mode(RecognitionMode value) => _mode = value;

  String? _lastEmittedLabel;
  DateTime _lastEmittedTime = DateTime.fromMillisecondsSinceEpoch(0);

  BackendRecognitionService({
    String? baseUrl,
    this.settings,
    Dio? dio,
  })  : baseUrl = baseUrl ?? settings?.ttsServerUrl ?? 'http://127.0.0.1:5000',
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(milliseconds: 1000),
                receiveTimeout: const Duration(milliseconds: 1000),
              ),
            );

  @override
  bool get isModelReady => _isInitialized;

  @override
  bool get isPaused => _isPaused;

  @override
  Stream<bool>? get pauseStatus => _pauseStatusController.stream;

  Stream<RecognitionProgress> get progress => _progressController.stream;

  @override
  Future<void> initialize() async {
    try {
      final res = await _dio.get('$baseUrl/tts/health');
      _isInitialized = res.statusCode == 200;
    } catch (_) {
      _isInitialized = true;
    }
  }

  @override
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 150), (_) async {
      if (!_isRunning) return;
      await _pollLivePrediction();
    });
  }

  Future<void> processJpegFrame(Uint8List jpegBytes) async {
    try {
      final response = await _dio.post(
        '$baseUrl/api/v1/predict/frame',
        data: FormData.fromMap({
          'frame': MultipartFile.fromBytes(jpegBytes, filename: 'frame.jpg'),
        }),
      );

      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        final landmarksRaw = data['hand_landmarks'] as List?;
        final landmarks = <List<List<double>>>[];
        if (landmarksRaw != null) {
          for (final hand in landmarksRaw) {
            if (hand is List) {
              final pts = <List<double>>[];
              for (final pt in hand) {
                if (pt is List) {
                  pts.add(pt.map((e) => (e as num).toDouble()).toList());
                }
              }
              landmarks.add(pts);
            }
          }
        }

        _progressController.add(
          RecognitionProgress(
            status: data['status'] as String? ?? 'processing',
            framesCollected: data['frames_collected'] as int? ?? 0,
            sequenceLength: data['sequence_length'] as int? ?? 60,
            handLandmarks: landmarks,
            frameWidth: data['frame_width'] as int? ?? 640,
            frameHeight: data['frame_height'] as int? ?? 480,
          ),
        );
      }
    } catch (_) {
      // Ignored
    }
  }

  Future<void> _pollLivePrediction() async {
    try {
      final res = await _dio.get('$baseUrl/api/v1/predict/live');
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data as Map<String, dynamic>;
        final isPaused = data['is_paused'] as bool? ?? false;

        if (isPaused != _isPaused) {
          _isPaused = isPaused;
          _pauseStatusController.add(isPaused);
        }

        if (isPaused) {
          // Open Palm pause active: skip emission to prevent false recognition
          return;
        }

        final confidence = (data['confidence'] as num?)?.toDouble() ?? 0.0;
        final isStable = data['is_stable'] as bool? ?? false;
        final label = data['label'] as String?;

        if (label != null && label.isNotEmpty && isStable && confidence >= 0.50) {
          final now = DateTime.now();
          if (label != _lastEmittedLabel ||
              now.difference(_lastEmittedTime).inMilliseconds > 1500) {
            _lastEmittedLabel = label;
            _lastEmittedTime = now;
            _predictionsController.add(
              SignResult(
                label: label,
                confidence: confidence,
                timestamp: now,
                source: 'st_gcn_model',
              ),
            );
          }
        }
      }
    } catch (_) {
      // Ignore transient errors
    }
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  @override
  Stream<List<List<Offset>>>? get landmarkPointsStream => _progressController.stream.map((p) {
        return p.handLandmarks.map((hand) {
          return hand.map((pt) => Offset(pt.isNotEmpty ? pt[0] : 0.0, pt.length > 1 ? pt[1] : 0.0)).toList();
        }).toList();
      });

  @override
  Future<void> reloadModels() async {
    // Backend service automatically uses server-side updated weights
  }

  @override
  Future<void> processFrame(
    CameraImage image, {
    int? sensorOrientation,
    bool? isFrontCamera,
  }) async {
    // Processed on camera feed
  }

  @override
  Stream<SignResult> get predictions => _predictionsController.stream;

  @override
  void dispose() {
    _isRunning = false;
    _pollingTimer?.cancel();
    _predictionsController.close();
    _progressController.close();
    _pauseStatusController.close();
  }
}
