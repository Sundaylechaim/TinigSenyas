import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../providers/recognition_provider.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/database_helper.dart';
import '../models/sign_result.dart';
import '../models/recognition_graph_frame.dart';
import '../widgets/camera_preview.dart';
import '../widgets/signing_space_overlay.dart';
import '../widgets/hand_landmark_overlay.dart';
import '../widgets/skeleton_graph_overlay.dart';
import '../widgets/connectivity_badge.dart';
import '../widgets/fsl_guide_sheet.dart';
import '../services/word_prediction_service.dart';
import '../services/settings_service.dart';
import '../services/model_updater.dart';
import '../services/sign_animation_catalog.dart';
import '../services/vocabulary_sync_service.dart';
import '../services/recognition/recognition_service.dart' show RecognitionMode;
import '../services/sign_benchmark.dart';
import '../widgets/gesture_motion_replay.dart';
import 'text_to_sign_screen.dart';

const Color _kAppBlue = Color(0xFF2D5FB8);
const Color _kAppYellow = Color(0xFFF4C95D);

class SignToTextScreen extends StatefulWidget {
  const SignToTextScreen({super.key});

  @override
  State<SignToTextScreen> createState() => _SignToTextScreenState();
}

class _SignToTextScreenState extends State<SignToTextScreen>
    with WidgetsBindingObserver {
  late CameraService _cameraService;
  late TtsService _ttsService;
  SignResult? _currentPrediction;
  SignResult? _lastRecognizedSign;
  bool _isCheckingPermission = true;
  bool _hasPermission = false;
  bool _isPermanentlyDenied = false;
  bool _isCameraInitialized = false;
  bool _isModelReady = false;
  bool _isProcessingFrame = false;
  String? _cameraError;
  String? _recognitionError;
  bool _useBackendFeed = kIsWeb;
  bool _backendFeedError = false;
  bool _isPaused = false;
  bool _isManuallyPaused = false;
  RecognitionProvider? _recognitionProvider;
  StreamSubscription<SignResult>? _predictionSubscription;
  StreamSubscription<bool>? _pauseSubscription;
  StreamSubscription<CameraImage>? _frameSubscription;
  StreamSubscription<List<List<Offset>>>? _landmarksSubscription;
  StreamSubscription<RecognitionGraphFrame>? _graphFramesSubscription;
  List<List<Offset>> _liveLandmarks = [];
  RecognitionGraphFrame? _liveGraphFrame;
  bool _showGraphOverlay = true;
  final List<List<List<Offset>>> _recentLandmarkFrames = [];
  List<List<List<Offset>>> _gestureReplayFrames = const [];
  Set<String> _availableAnimationSlugs = const {};
  Timer? _gestureReplayTimer;
  bool _isCheckingModelUpdate = false;
  RecognitionMode _currentMode = RecognitionMode.phrases;
  final SignBenchmark _benchmark = SignBenchmark();
  final TextEditingController _benchmarkDeviceController =
      TextEditingController();
  final TextEditingController _benchmarkAndroidController =
      TextEditingController();
  final TextEditingController _benchmarkConditionsController =
      TextEditingController();

  bool get _canBenchmarkOnThisDevice =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _showRecognitionPipeline() async {
    final frame = _liveGraphFrame;
    final scores = frame?.scores ?? const <RecognitionScore>[];
    const pending = <(String, String)>[
      ('Paalam', 'Goodbye'),
      ('Pasensya na', 'Sorry'),
      ('Pakiusap', 'Please'),
      ('Tubig', 'Water'),
      ('Kain', 'Eat'),
      ('Tulog', 'Sleep'),
      ('Tulong', 'Help'),
      ('Banyo / CR', 'Restroom'),
      ('Punta', 'Go'),
      ('Gusto', 'Want'),
      ('Ayaw', "Don't want"),
      ('Tapos na', 'Finished'),
      ('Maghintay', 'Wait'),
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refreshSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'ST-GCN recognition pipeline',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show skeleton graph on camera'),
                    subtitle: const Text('Overlay pose and hand landmarks'),
                    value: _showGraphOverlay,
                    onChanged: (value) {
                      setState(() => _showGraphOverlay = value);
                      refreshSheet(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Camera video → MediaPipe Pose (33) + Hands (21 per hand) → shoulder-normalized 75-joint graph → 60-frame temporal window → TFLite ST-GCN → label probabilities.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Inside the ST-GCN, spatial graph convolution follows anatomical edges; temporal convolution links each joint across nine adjacent frames before the class-probability output.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Live graph: ${frame == null ? 'waiting for pose and hand landmarks' : '${frame.pose.length} pose points, ${frame.hands.length} tracked hand(s), ${frame.sequenceLength}/60 frames'}',
                  ),
                  Text(
                    'Model: ${frame?.modelName ?? 'waiting for an ST-GCN inference'}',
                  ),
                  Text(
                    'Inference: ${frame?.inferenceLatencyMs == null ? '—' : '${frame!.inferenceLatencyMs} ms'}',
                  ),
                  if (scores.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Top model probabilities',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final score in scores)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Row(
                          children: [
                            Expanded(child: Text(score.label)),
                            Text(
                              '${(score.probability * 100).toStringAsFixed(1)}%',
                            ),
                          ],
                        ),
                      ),
                  ],
                  const Divider(height: 24),
                  const Text(
                    'Vocabulary that still needs community-reviewed samples and a trained model:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'These are not recognized by the current model yet. Record consented examples and train/evaluate before enabling a label.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: pending
                        .map(
                          (item) =>
                              Chip(label: Text('${item.$1} · ${item.$2}')),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'FSL signs can vary by region and community. Review each sign and gloss with local Deaf FSL signers before adding it to production.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _recordTrainingSample() async {
    final stream = _recognitionProvider?.graphFrames;
    if (kIsWeb || stream == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The local MediaPipe graph recorder is available in the mobile app.',
          ),
        ),
      );
      return;
    }
    final labelController = TextEditingController();
    var consented = false;
    var recording = false;
    var count = 0;
    List<List<List<double>>>? sample;
    StreamSubscription<RecognitionGraphFrame>? capture;
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Record FSL sample'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  onChanged: (_) => refresh(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Sign label',
                    hintText: 'For example: Tubig',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: consented,
                  onChanged: recording
                      ? null
                      : (value) => refresh(() => consented = value ?? false),
                  title: const Text(
                    'I have permission from the signer to save this skeletal sample.',
                  ),
                  subtitle: const Text(
                    'Only normalized landmarks are saved; no video or audio is recorded.',
                  ),
                ),
                if (recording) LinearProgressIndicator(value: count / 60),
                if (recording)
                  Text('Collecting distinct valid frames: $count / 60'),
                if (sample != null)
                  const Text('60-frame sequence captured and ready to save.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: recording
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            if (sample != null)
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Save sample'),
              )
            else
              FilledButton(
                onPressed:
                    recording ||
                        !consented ||
                        labelController.text.trim().isEmpty
                    ? null
                    : () {
                        refresh(() => recording = true);
                        DateTime? lastCaptured;
                        final frames = <List<List<double>>>[];
                        capture = stream.listen((frame) {
                          if (frame.capturedAt == lastCaptured ||
                              frame.normalizedJoints.length != 75 ||
                              frame.sequenceLength < 24) {
                            return;
                          }
                          lastCaptured = frame.capturedAt;
                          frames.add(
                            frame.normalizedJoints
                                .map(List<double>.from)
                                .toList(growable: false),
                          );
                          refresh(() {
                            count = frames.length;
                            if (count >= 60) {
                              sample = frames.take(60).toList(growable: false);
                              recording = false;
                            }
                          });
                          if (frames.length >= 60) unawaited(capture?.cancel());
                        });
                      },
                child: Text(recording ? 'Recording…' : 'Start recording'),
              ),
          ],
        ),
      ),
    );
    await capture?.cancel();
    if (completed == true && sample != null) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final outputDir = Directory(
          '${directory.path}${Platform.pathSeparator}FSLTrainingSamples',
        );
        await outputDir.create(recursive: true);
        final safeLabel = labelController.text
            .trim()
            .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
            .replaceAll(RegExp(r'^_+|_+$'), '');
        final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
          ':',
          '-',
        );
        final file = File(
          '${outputDir.path}${Platform.pathSeparator}${safeLabel}_$stamp.json',
        );
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schema_version': 1,
            'label': labelController.text.trim(),
            'shape': [60, 75, 3],
            'features': sample,
            'coordinate_space':
                'shoulder-centered, shoulder-width normalized xyz; pose[0:33], left_hand[33:54], right_hand[54:75]',
            'consent_confirmed': true,
            'video_or_audio_saved': false,
            'captured_at_utc': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'application/json')],
            subject: 'FSL skeleton sample: ${labelController.text.trim()}',
          ),
        );
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save sample: $error')),
          );
        }
      }
    }
    labelController.dispose();
  }

  void _cycleRecognitionMode() {
    setState(() {
      switch (_currentMode) {
        case RecognitionMode.auto:
          _currentMode = RecognitionMode.phrases;
          break;
        case RecognitionMode.phrases:
          _currentMode = RecognitionMode.alphabet;
          break;
        case RecognitionMode.alphabet:
          _currentMode = RecognitionMode.medical;
          break;
        case RecognitionMode.medical:
          _currentMode = RecognitionMode.auto;
          break;
      }
      // Do not carry repeated or partial alphabet output into a different
      // recognition mode. Keep already-composed messages intact.
      _activeWordBuffer = '';
      _suggestedWords = [];
      _currentPrediction = null;
      _lastRecognizedSign = null;
      _gestureReplayFrames = const [];
    });
    _recognitionProvider?.setMode(_currentMode);
    final modeLabel = _currentMode == RecognitionMode.phrases
        ? 'Known phrases • one trained item per gesture; lower hands between items'
        : _currentMode == RecognitionMode.alphabet
        ? 'A–Z, Ng, Ñ • sign letters one at a time; the assembler builds words'
        : _currentMode == RecognitionMode.medical
        ? 'Medical • sign one health item, hold briefly, then lower your hands'
        : 'Auto • supported signs and steady letters; choose Medical for health signs';
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Mode: $modeLabel'),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Smart Word Assembler & Intent Prediction State
  final WordPredictionService _wordPredictionService = WordPredictionService();
  String _activeWordBuffer = '';
  String _composedSentence = '';
  List<String> _suggestedWords = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraService = CameraService();
    _ttsService = context.read<TtsService>();
    _recognitionProvider = context.read<RecognitionProvider>();
    // The recognition provider outlives this screen; keep the visible mode in
    // sync when navigating away and returning to the camera.
    _currentMode = _recognitionProvider!.mode;
    unawaited(_loadSignAnimationCatalog());
    unawaited(_loadSyncedVocabulary());
    _predictionSubscription = _recognitionProvider!.predictions.listen((
      prediction,
    ) {
      if (mounted && _predictionMatchesMode(prediction)) {
        final labelChanged = _currentPrediction?.label != prediction.label;
        if (labelChanged) {
          // Tactile haptic feedback for Deaf / Hard-of-Hearing users
          HapticFeedback.mediumImpact();
        }
        setState(() {
          _currentPrediction = prediction;
          _lastRecognizedSign = prediction;
        });
        // A post-frame callback makes the timing end at the UI update rather
        // than when the recognition isolate emitted its result.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _benchmark.recordDisplayedResult(
              label: prediction.label,
              now: DateTime.now(),
            );
          }
        });
        if (labelChanged) _scheduleGestureReplay(prediction.label);
        _handlePredictionAssembly(prediction);
      }
    });

    _pauseSubscription = _recognitionProvider?.pauseStatus?.listen((paused) {
      if (mounted && _isPaused != paused) {
        if (paused) {
          // Subtle haptic pulse to notify signer that hands at rest paused recognition
          HapticFeedback.lightImpact();
        }
        setState(() {
          _isPaused = paused;
          if (!paused) _isManuallyPaused = false;
          if (paused) {
            _snapshotGestureReplay();
            _currentPrediction = null;
            _recentLandmarkFrames.clear();
            _liveLandmarks = const [];
            _liveGraphFrame = null;
          }
        });
      }
    });

    _landmarksSubscription = _recognitionProvider?.landmarkPointsStream?.listen(
      (hands) {
        if (mounted) {
          if (_isPaused) {
            setState(() => _liveLandmarks = const []);
            return;
          }
          final frame = hands
              .map((hand) => List<Offset>.unmodifiable(hand))
              .toList(growable: false);
          if (frame.isNotEmpty) {
            _recentLandmarkFrames.add(frame);
            if (_recentLandmarkFrames.length > 42) {
              _recentLandmarkFrames.removeAt(0);
            }
          }
          setState(() => _liveLandmarks = frame);
        }
      },
    );
    _graphFramesSubscription = _recognitionProvider?.graphFrames?.listen((
      frame,
    ) {
      if (!mounted) return;
      setState(() {
        _liveGraphFrame = _isPaused || frame.hands.isEmpty ? null : frame;
      });
    });

    // Check for Google Maps style background model OTA updates if connected
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _checkForOtaModelUpdates();
    });

    if (kIsWeb) {
      _detectWebFeedMode();
    } else {
      _useBackendFeed = false;
      _checkPermissionAndStart();
    }

    _updateWakelock(true);
  }

  Future<void> _loadSyncedVocabulary() async {
    try {
      final database = context.read<DatabaseHelper>();
      final settings = context.read<SettingsService>();
      final predictionService = _wordPredictionService;
      predictionService.addVocabulary(await database.getVocabularyWords());

      final syncedCount = await VocabularySyncService(
        store: database,
      ).syncFrom(settings.ttsServerUrl);
      if (syncedCount > 0) {
        predictionService.addVocabulary(await database.getVocabularyWords());
      }
    } catch (error) {
      debugPrint('[SignToText] Vocabulary cache unavailable: $error');
    }
  }

  Future<void> _loadSignAnimationCatalog() async {
    try {
      final animations = await SignAnimationCatalog.load();
      if (!mounted) return;
      setState(() => _availableAnimationSlugs = animations);
    } catch (error) {
      debugPrint('Could not load FSL animation catalog: $error');
    }
  }

  void _scheduleGestureReplay(String label) {
    _gestureReplayTimer?.cancel();
    _gestureReplayTimer = Timer(const Duration(milliseconds: 320), () {
      if (!mounted || _currentPrediction?.label != label) return;
      setState(_snapshotGestureReplay);
    });
  }

  void _snapshotGestureReplay() {
    final frames = List<List<List<Offset>>>.unmodifiable(_recentLandmarkFrames);
    if (frames.where((frame) => frame.isNotEmpty).length >= 2) {
      _gestureReplayFrames = frames;
    }
  }

  double get _landmarkFrameAspectRatio {
    final previewSize = _cameraService.controller?.value.previewSize;
    if (previewSize == null) return 1;
    final isRotated =
        !kIsWeb && MediaQuery.orientationOf(context) == Orientation.portrait;
    final frameWidth = isRotated ? previewSize.height : previewSize.width;
    final frameHeight = isRotated ? previewSize.width : previewSize.height;
    if (frameHeight <= 0) return 1;
    return frameWidth / frameHeight;
  }

  Future<void> _updateWakelock(bool enable) async {
    try {
      if (enable) {
        final keepAwake = context.read<SettingsService>().keepScreenAwake;
        if (keepAwake) {
          await WakelockPlus.enable();
        } else {
          await WakelockPlus.disable();
        }
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('WakelockPlus error: $e');
    }
  }

  Future<void> _detectWebFeedMode() async {
    setState(() => _isCheckingPermission = true);
    bool backendAvailable = false;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(milliseconds: 1200),
          receiveTimeout: const Duration(milliseconds: 1200),
        ),
      );
      final serverUrl = context.read<SettingsService>().ttsServerUrl;
      final res = await dio.get('$serverUrl/tts/health');
      backendAvailable = res.statusCode == 200;
    } catch (_) {
      backendAvailable = false;
    }

    if (!mounted) return;

    if (backendAvailable) {
      setState(() {
        _useBackendFeed = true;
        _backendFeedError = false;
        _isCheckingPermission = false;
        _hasPermission = true;
        _isCameraInitialized = true;
        _isModelReady = true;
      });
      _recognitionProvider?.initialize().then((_) {
        _recognitionProvider?.start();
        if (mounted) setState(() => _isModelReady = true);
      });
    } else {
      // Backend server is not running on port 5000 -> seamlessly fall back to browser camera
      setState(() {
        _useBackendFeed = false;
        _backendFeedError = false;
      });
      _checkPermissionAndStart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _updateWakelock(false);
      unawaited(_cameraService.dispose());
      if (mounted) {
        setState(() => _isCameraInitialized = false);
      }
    } else if (state == AppLifecycleState.resumed) {
      _updateWakelock(true);
      if (!_useBackendFeed) {
        // Re-check permission and restart camera when returning from settings or background
        _checkPermissionAndStart();
      }
    }
  }

  Future<void> _checkPermissionAndStart() async {
    if (!mounted) return;
    setState(() {
      _isCheckingPermission = true;
      _cameraError = null;
    });

    // 1. Check whether camera permission is already granted
    final hasPerm = await _cameraService.hasCameraPermission();
    if (hasPerm) {
      if (mounted) {
        setState(() {
          _hasPermission = true;
          _isPermanentlyDenied = false;
          _isCheckingPermission = false;
        });
      }
      await _initializeCamera();
      return;
    }

    // 2. If already permanently denied, guide user to system settings
    final isPermDenied = await _cameraService.isPermissionPermanentlyDenied();
    if (isPermDenied) {
      if (mounted) {
        setState(() {
          _hasPermission = false;
          _isPermanentlyDenied = true;
          _isCheckingPermission = false;
        });
      }
      return;
    }

    // 3. Always ask for camera permission before starting the camera
    final granted = await _cameraService.requestCameraPermission();
    final nowPermDenied = await _cameraService.isPermissionPermanentlyDenied();

    if (mounted) {
      setState(() {
        _hasPermission = granted;
        _isPermanentlyDenied = nowPermDenied;
        _isCheckingPermission = false;
      });
    }

    if (granted) {
      await _initializeCamera();
    }
  }

  Future<void> _requestPermissionAndStart() async {
    setState(() {
      _cameraError = null;
      _isCheckingPermission = true;
    });
    final granted = await _cameraService.requestCameraPermission();
    final isPermDenied = await _cameraService.isPermissionPermanentlyDenied();

    if (mounted) {
      setState(() {
        _hasPermission = granted;
        _isPermanentlyDenied = isPermDenied;
        _isCheckingPermission = false;
      });
    }

    if (granted) {
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    // Guard: Guarantee camera permission is granted before touching hardware
    final hasPerm = await _cameraService.hasCameraPermission();
    if (!hasPerm) {
      final granted = await _cameraService.requestCameraPermission();
      if (!granted) {
        final isDenied = await _cameraService.isPermissionPermanentlyDenied();
        if (mounted) {
          setState(() {
            _hasPermission = false;
            _isPermanentlyDenied = isDenied;
            _isCameraInitialized = false;
          });
        }
        return;
      }
    }

    try {
      await _cameraService.initialize(direction: CameraLensDirection.front);
      await _recognitionProvider!.initialize();
      await _recognitionProvider!.start();
      final isReady = _recognitionProvider!.isModelReady;

      _restartFrameStream();

      if (mounted) {
        setState(() {
          _hasPermission = true;
          _isCameraInitialized = true;
          _isModelReady = isReady;
          _cameraError = null;
        });
      }
    } on CameraPermissionPermanentlyDeniedException catch (e) {
      if (mounted) {
        setState(() {
          _hasPermission = false;
          _isPermanentlyDenied = true;
          _cameraError = e.message;
        });
      }
    } on CameraPermissionDeniedException catch (_) {
      if (mounted) {
        setState(() {
          _hasPermission = false;
          _isPermanentlyDenied = false;
          _cameraError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraError = _formatUserFacingCameraError(e);
        });
      }
    }
  }

  static String _formatUserFacingCameraError(Object error) {
    final str = error.toString();
    if (str.contains('releaseFlutterSurfaceTexture') ||
        str.contains('flutterSurfaceProducer') ||
        str.contains('IllegalStateException')) {
      return 'The camera preview was interrupted during setup. Please tap "Retry Camera" below to reconnect.';
    }
    if (str.contains('cameraNotReadable') ||
        str.contains('NotReadableError') ||
        str.contains('in use') ||
        str.contains('hardware error')) {
      return 'The camera is currently in use by another app or blocked by system settings.';
    }
    if (str.contains('permission') || str.contains('CameraAccessDenied')) {
      return 'Camera permission was denied. Please allow camera access in Settings.';
    }
    if (str.contains('No camera') || str.contains('no camera')) {
      return 'No camera detected on this device. Please connect a webcam or enable camera hardware.';
    }
    final clean = str
        .replaceAll(RegExp(r'^Exception:\s*'), '')
        .replaceAll(RegExp(r'^CameraException:\s*'), '')
        .replaceAll(RegExp(r'^PlatformException\([^,]+,\s*'), '')
        .split('\n')
        .first
        .trim();
    if (clean.length > 120 ||
        clean.contains('Stacktrace:') ||
        clean.contains('io.flutter')) {
      return 'Unable to start camera preview. Tap "Retry Camera" to reconnect.';
    }
    return clean;
  }

  void _restartFrameStream() {
    _frameSubscription?.cancel();
    _frameSubscription = _cameraService.frameStream.listen(
      _processFrame,
      onError: (Object error, StackTrace stackTrace) {
        if (mounted) setState(() => _recognitionError = error.toString());
      },
    );
  }

  Future<void> _switchCamera() async {
    try {
      await _cameraService.switchCamera();
      _restartFrameStream();
      if (mounted) {
        final currentCam = _cameraService.selectedCamera;
        final name = currentCam != null
            ? CameraService.getCameraDisplayName(currentCam, 0)
            : 'Camera';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Switched to: $name'),
            duration: const Duration(milliseconds: 900),
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not switch camera: $e')));
      }
    }
  }

  void _showCameraPicker() {
    final cameras = _cameraService.availableCamerasList;
    if (cameras.length <= 2) {
      _switchCamera();
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'Select Camera',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(),
                ...cameras.asMap().entries.map((entry) {
                  final index = entry.key;
                  final cam = entry.value;
                  final isSelected = cam == _cameraService.selectedCamera;
                  return ListTile(
                    leading: Icon(
                      cam.lensDirection == CameraLensDirection.front
                          ? Icons.camera_front_rounded
                          : cam.lensDirection == CameraLensDirection.back
                          ? Icons.camera_rear_rounded
                          : Icons.videocam_rounded,
                      color: isSelected ? _kAppBlue : null,
                    ),
                    title: Text(
                      CameraService.getCameraDisplayName(cam, index),
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected ? _kAppBlue : null,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(
                            Icons.check_circle_rounded,
                            color: _kAppBlue,
                          )
                        : null,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _cameraService.selectCamera(cam);
                      _restartFrameStream();
                      if (mounted) setState(() {});
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _processFrame(CameraImage image) {
    _benchmark.recordCameraFrame(DateTime.now());
    if (_isProcessingFrame || _recognitionProvider == null) return;
    _isProcessingFrame = true;
    final orientation = _cameraService.selectedCamera?.sensorOrientation;
    final isFrontCamera =
        _cameraService.selectedCamera?.lensDirection ==
        CameraLensDirection.front;
    _recognitionProvider!
        .processFrame(
          image,
          sensorOrientation: orientation,
          isFrontCamera: isFrontCamera,
        )
        .then((_) {
          if (mounted && _recognitionError != null) {
            setState(() => _recognitionError = null);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Sign recognition frame failed: $error');
          if (mounted) setState(() => _recognitionError = error.toString());
        })
        .whenComplete(() => _isProcessingFrame = false);
  }

  Future<void> _checkForOtaModelUpdates() async {
    if (_isCheckingModelUpdate) return;
    _isCheckingModelUpdate = true;
    try {
      final serverUrl = context.read<SettingsService>().ttsServerUrl;
      final remoteManifest = serverUrl.isNotEmpty
          ? '$serverUrl/api/v1/ota/manifest'
          : ModelUpdater.defaultRemoteManifestUrl;
      final updater = ModelUpdater(remoteManifestUrl: remoteManifest);
      final updateInfo = await updater.checkForUpdates();
      if (updateInfo.status == UpdateStatus.updateAvailable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'New FSL Model Available (${updateInfo.version}). Tap to install.',
            ),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'UPDATE',
              onPressed: () async {
                await for (final progress in updater.downloadUpdate(
                  updateInfo,
                )) {
                  if (progress.status == UpdateStatus.downloading && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Downloading updated model: ${(progress.progress * 100).toInt()}%',
                        ),
                        duration: const Duration(milliseconds: 600),
                      ),
                    );
                  } else if (progress.status == UpdateStatus.upToDate &&
                      mounted) {
                    await _recognitionProvider?.reloadModels();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('FSL Model updated successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (_) {
      // Ignore background update check failures
    } finally {
      _isCheckingModelUpdate = false;
    }
  }

  Future<void> _saveCurrentPrediction() async {
    if (_currentPrediction != null) {
      final settings = context.read<SettingsService>();
      if (!settings.saveHistoryEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Private Mode active: sign is not saved to history.',
              ),
              duration: Duration(milliseconds: 1200),
            ),
          );
        }
        return;
      }
      try {
        await DatabaseHelper.instance.saveRecognizedGesture(
          _currentPrediction!.label,
          _currentPrediction!.confidence,
          source: 'sign',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved: ${_currentPrediction!.label}'),
              duration: const Duration(milliseconds: 800),
            ),
          );
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save sign: $error')),
          );
        }
      }
    }
  }

  void _handlePredictionAssembly(SignResult prediction) {
    if (_isPaused) return;
    final label = _filipinoPredictionText(prediction.label);
    // "Ng" is one FSL alphabet class and should be committed as one
    // orthographic token, just like the single-character letters.
    final normalizedLetter = label.toUpperCase();
    final isAlphabetToken = RegExp(
      r'^(?:[A-ZÑ]|NG)$',
      caseSensitive: false,
    ).hasMatch(label);

    if (isAlphabetToken) {
      if (_currentMode != RecognitionMode.alphabet &&
          _currentMode != RecognitionMode.auto) {
        return;
      }
      setState(() {
        _activeWordBuffer += normalizedLetter;
        _suggestedWords = _wordPredictionService.getPredictions(
          _activeWordBuffer,
        );
      });
    } else if (label.length > 1 && prediction.confidence >= 0.60) {
      // If a full gesture word is signed (e.g., "Salamat" or "Kamusta"), suggest it directly
      setState(() {
        if (!_suggestedWords.contains(label)) {
          _suggestedWords.insert(0, label);
          if (_suggestedWords.length > 4) {
            _suggestedWords = _suggestedWords.sublist(0, 4);
          }
        }
      });
    }
  }

  bool _predictionMatchesMode(SignResult prediction) {
    switch (prediction.source) {
      case 'fsl_alphabet_model':
      case 'trajectory_j_detector':
        return _currentMode == RecognitionMode.alphabet ||
            _currentMode == RecognitionMode.auto;
      case 'st_gcn_model':
        return _currentMode == RecognitionMode.phrases ||
            _currentMode == RecognitionMode.auto;
      case 'fsl_medical_model':
        return _currentMode == RecognitionMode.medical;
      default:
        return true;
    }
  }

  void _acceptWordSuggestion(String word) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_composedSentence.isEmpty) {
        _composedSentence = word;
      } else {
        _composedSentence += ' $word';
      }
      _activeWordBuffer = '';
      _suggestedWords = [];
    });
  }

  void _backspaceLetter() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_activeWordBuffer.isNotEmpty) {
        _activeWordBuffer = _activeWordBuffer.substring(
          0,
          _activeWordBuffer.length - 1,
        );
        _suggestedWords = _wordPredictionService.getPredictions(
          _activeWordBuffer,
        );
      } else if (_composedSentence.isNotEmpty) {
        final words = _composedSentence.split(' ');
        words.removeLast();
        _composedSentence = words.join(' ');
      }
    });
  }

  void _clearSentence() {
    HapticFeedback.selectionClick();
    final prevWord = _activeWordBuffer;
    final prevSentence = _composedSentence;

    if (prevWord.isEmpty && prevSentence.isEmpty) return;

    setState(() {
      _activeWordBuffer = '';
      _composedSentence = '';
      _suggestedWords = [];
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Sentence cleared'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'UNDO',
          textColor: _kAppYellow,
          onPressed: () {
            setState(() {
              _activeWordBuffer = prevWord;
              _composedSentence = prevSentence;
            });
          },
        ),
      ),
    );
  }

  void _copyToClipboard() {
    HapticFeedback.mediumImpact();
    final text = _composedSentence.isNotEmpty
        ? (_activeWordBuffer.isNotEmpty
              ? '$_composedSentence $_activeWordBuffer'
              : _composedSentence)
        : (_activeWordBuffer.isNotEmpty
              ? _activeWordBuffer
              : _filipinoPredictionText(_currentPrediction?.label ?? ''));

    if (text.trim().isEmpty) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nothing to copy yet. Sign a word or letter first!'),
          duration: Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    Clipboard.setData(ClipboardData(text: text.trim()));
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: Colors.greenAccent,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('Copied "$text" to clipboard!')),
          ],
        ),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _toggleManualPause() {
    HapticFeedback.mediumImpact();
    final newPaused = !_isPaused;
    setState(() {
      _isPaused = newPaused;
      _isManuallyPaused = newPaused;
      if (newPaused) {
        _liveLandmarks = const [];
        _liveGraphFrame = null;
        _recentLandmarkFrames.clear();
      }
    });
    _recognitionProvider?.setPaused(newPaused);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          newPaused ? '⏸️ Recognition paused' : '▶️ Recognition resumed',
        ),
        duration: const Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _speakComposedSentence() async {
    final textToSpeak = _composedSentence.isNotEmpty
        ? (_activeWordBuffer.isNotEmpty
              ? '$_composedSentence $_activeWordBuffer'
              : _composedSentence)
        : (_activeWordBuffer.isNotEmpty
              ? _activeWordBuffer
              : _filipinoPredictionText(_currentPrediction?.label ?? ''));

    if (textToSpeak.trim().isNotEmpty) {
      HapticFeedback.mediumImpact();
      try {
        await _ttsService.speak(textToSpeak.trim());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Speech synthesis error: $e')));
        }
      }
    }
  }

  Future<void> _openTypeAndSpeakFallback() async {
    final initialText = [
      _composedSentence.trim(),
      _activeWordBuffer.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
    final wasPaused = _isPaused;

    if (!wasPaused) {
      setState(() {
        _isPaused = true;
        _liveLandmarks = const [];
        _liveGraphFrame = null;
        _recentLandmarkFrames.clear();
      });
      _recognitionProvider?.setPaused(true);
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TextToSignScreen(initialText: initialText),
      ),
    );

    if (mounted && !wasPaused) {
      setState(() => _isPaused = false);
      _recognitionProvider?.setPaused(false);
    }
  }

  String _filipinoPredictionText(String label) =>
      label.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

  @override
  void deactivate() {
    ScaffoldMessenger.of(context).clearSnackBars();
    super.deactivate();
  }

  @override
  void dispose() {
    _gestureReplayTimer?.cancel();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    _predictionSubscription?.cancel();
    _pauseSubscription?.cancel();
    _landmarksSubscription?.cancel();
    _graphFramesSubscription?.cancel();
    _frameSubscription?.cancel();
    _benchmarkDeviceController.dispose();
    _benchmarkAndroidController.dispose();
    _benchmarkConditionsController.dispose();
    unawaited(_cameraService.dispose());
    final recognitionProvider = _recognitionProvider;
    if (recognitionProvider != null) unawaited(recognitionProvider.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0C1220).withValues(alpha: 0.65)
                    : Colors.white.withValues(alpha: 0.70),
                border: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
        titleSpacing: 8,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Flexible(
              child: Text(
                'Sign to Text',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: _kAppYellow,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics_outlined, color: _kAppBlue),
            tooltip: 'Recognition pipeline and vocabulary status',
            onPressed: _showRecognitionPipeline,
          ),
          if (kIsWeb)
            IconButton(
              icon: Icon(
                _useBackendFeed
                    ? Icons.sensors_rounded
                    : Icons.videocam_rounded,
                color: _kAppBlue,
              ),
              tooltip: _useBackendFeed
                  ? 'Switch to Browser Direct Camera'
                  : 'Switch to Backend AI Video Stream',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() {
                  _useBackendFeed = !_useBackendFeed;
                  _backendFeedError = false;
                  if (!_useBackendFeed && !_isCameraInitialized) {
                    _checkPermissionAndStart();
                  }
                });
              },
            ),
          if (!_useBackendFeed &&
              _isCameraInitialized &&
              _cameraService.canSwitchCamera)
            IconButton(
              icon: const Icon(Icons.cameraswitch_rounded),
              tooltip: 'Switch between front and back camera',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                HapticFeedback.selectionClick();
                _showCameraPicker();
              },
            ),
          if (_canBenchmarkOnThisDevice)
            IconButton(
              icon: Icon(
                _benchmark.isRunning
                    ? Icons.timer_rounded
                    : Icons.timer_outlined,
                color: _benchmark.isRunning ? _kAppBlue : null,
              ),
              tooltip: 'Local Android benchmark',
              visualDensity: VisualDensity.compact,
              onPressed: _showBenchmarkSheet,
            ),
          const SizedBox(width: 4),
          const ConnectivityBadge(),
          const SizedBox(width: 10),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_useBackendFeed) {
      return _buildBackendFeedView();
    }

    if (_isCheckingPermission) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasPermission) {
      return _buildPermissionRequestView();
    }

    if (_cameraError != null) {
      return _buildErrorState();
    }

    if (!_isCameraInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return _buildCameraView();
  }

  Widget _buildPermissionRequestView() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0C1220).withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.80),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kAppBlue.withValues(alpha: 0.12),
                        border: Border.all(
                          color: _kAppBlue.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.videocam_rounded,
                        size: 40,
                        color: _kAppBlue,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Camera Access Required',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'TinigSenyas requires camera access to recognize hand gestures and translate Filipino Sign Language (FSL) in real-time.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 22),
                    _buildFeatureBullet(
                      Icons.pan_tool_rounded,
                      'Recognizes hand gestures across horizontal signing space',
                    ),
                    const SizedBox(height: 10),
                    _buildFeatureBullet(
                      Icons.cameraswitch_rounded,
                      'Supports both Front (Selfie) and Rear mobile cameras',
                    ),
                    const SizedBox(height: 10),
                    _buildFeatureBullet(
                      Icons.lock_outline_rounded,
                      'Private: Video is processed locally on your phone',
                    ),
                    const SizedBox(height: 28),
                    if (_isPermanentlyDenied) ...[
                      Text(
                        'Camera permission is denied in system settings.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: () async {
                          HapticFeedback.mediumImpact();
                          await _cameraService.openSettings();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAppBlue,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.settings_rounded),
                        label: const Text(
                          'Open App Settings',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          _checkPermissionAndStart();
                        },
                        child: const Text(
                          'I have allowed permission (Check again)',
                        ),
                      ),
                    ] else ...[
                      ElevatedButton.icon(
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          _requestPermissionAndStart();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAppBlue,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.check_circle_outline_rounded),
                        label: const Text(
                          'Allow Camera Access',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureBullet(IconData icon, String text) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _kAppYellow.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 16, color: const Color(0xFFD97706)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isPermIssue =
        _isPermanentlyDenied ||
        (_cameraError != null &&
            _cameraError!.toLowerCase().contains('permission'));
    final isInUseIssue =
        _cameraError != null &&
        (_cameraError!.toLowerCase().contains('notreadable') ||
            _cameraError!.toLowerCase().contains('in use') ||
            _cameraError!.toLowerCase().contains('hardware error'));

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0C1220).withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.90),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.black12,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            (isInUseIssue
                                    ? Colors.orange
                                    : theme.colorScheme.error)
                                .withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        isInUseIssue
                            ? Icons.videocam_off_rounded
                            : Icons.error_outline_rounded,
                        size: 38,
                        color: isInUseIssue
                            ? Colors.orange
                            : theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      isInUseIssue
                          ? 'Camera In Use or Unavailable'
                          : isPermIssue
                          ? 'Camera Permission Issue'
                          : 'Camera Error',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isInUseIssue
                          ? 'The camera is currently locked by another application or blocked by system settings.'
                          : (_cameraError != null
                                ? _formatUserFacingCameraError(_cameraError!)
                                : 'Unable to connect to camera.'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (isInUseIssue) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.black.withValues(alpha: 0.3)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isDark
                                ? Colors.white10
                                : Colors.black.withValues(alpha: 0.05),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Troubleshooting Steps:',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _buildTroubleshootItem(
                              '1. Close other background apps using the camera (video calls, camera app).',
                            ),
                            _buildTroubleshootItem(
                              '2. Verify Camera permission is enabled for TinigSenyas in device Settings.',
                            ),
                            _buildTroubleshootItem(
                              '3. If the camera remains unresponsive, restart TinigSenyas.',
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (isPermIssue) ...[
                      ElevatedButton.icon(
                        onPressed: () async {
                          HapticFeedback.mediumImpact();
                          await _cameraService.openSettings();
                        },
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        icon: const Icon(Icons.settings_rounded),
                        label: const Text('Open System Settings'),
                      ),
                      const SizedBox(height: 10),
                    ],
                    ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _checkPermissionAndStart();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAppBlue,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26,
                          vertical: 13,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text(
                        'Retry Camera',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (kIsWeb) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _cameraError = null;
                            _useBackendFeed = true;
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kAppBlue,
                          side: const BorderSide(color: _kAppBlue, width: 1.5),
                          minimumSize: const Size(double.infinity, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.videocam_rounded),
                        label: const Text(
                          'Use Backend AI Video Stream',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackendFeedView() {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top + kToolbarHeight + 8;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_backendFeedError)
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0C1220).withValues(alpha: 0.90)
                          : Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.orange.withValues(alpha: 0.15),
                          ),
                          child: const Icon(
                            Icons.sensors_off_rounded,
                            color: Colors.orange,
                            size: 34,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Backend AI Server Offline',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'The backend is not reachable on port 5000. Try on-device camera mode or check the backend address.',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 22),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _useBackendFeed = false;
                              _backendFeedError = false;
                            });
                            _checkPermissionAndStart();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _kAppBlue,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: const Icon(Icons.videocam_rounded),
                          label: const Text(
                            'Switch to Browser Direct Camera',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _backendFeedError = false);
                            _detectWebFeedMode();
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Retry Backend (Port 5000)'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (kIsWeb)
          Positioned.fill(
            child: HtmlElementView.fromTagName(
              tagName: 'img',
              onElementCreated: (Object element) {
                final img = element as dynamic;
                final serverUrl = context.read<SettingsService>().ttsServerUrl;
                img.src = '$serverUrl/video_feed';
                img.style.position = 'absolute';
                img.style.top = '0';
                img.style.left = '0';
                img.style.width = '100%';
                img.style.height = '100%';
                img.style.objectFit = 'cover';
                img.style.display = 'block';
                img.style.pointerEvents = 'none';
                img.onerror = (dynamic _) {
                  if (mounted && _useBackendFeed) {
                    setState(() => _backendFeedError = true);
                  }
                };
              },
            ),
          )
        else
          Image.network(
            '${context.read<SettingsService>().ttsServerUrl}/video_feed',
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam_off_rounded,
                    size: 48,
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 12),
                  const Text('Backend video feed connecting on port 5000...'),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () => setState(() {}),
                    child: const Text('Retry Feed'),
                  ),
                ],
              ),
            ),
          ),
        SigningSpaceOverlay(
          showUpperBodyGuide: _currentMode != RecognitionMode.alphabet,
          handsDetected: _liveLandmarks.isNotEmpty,
        ),
        Positioned(
          top: topPadding,
          left: 16,
          right: 16,
          child: _buildRecognitionStatus(),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            bottom: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [_buildActionCard()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTroubleshootItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: const TextStyle(fontSize: 12, height: 1.3)),
    );
  }

  Widget _buildCameraView() {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top + kToolbarHeight + 8;
    final graphFrame = _isPaused || _liveGraphFrame?.hands.isEmpty != false
        ? null
        : _liveGraphFrame;
    final visibleHands = _isPaused ? const <List<Offset>>[] : _liveLandmarks;

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreviewWidget(cameraService: _cameraService),
        Builder(
          builder: (context) {
            final controller = _cameraService.controller;
            final isRotated =
                !kIsWeb &&
                MediaQuery.of(context).orientation == Orientation.portrait;
            final previewSize = controller?.value.previewSize;
            final pw = isRotated
                ? (previewSize?.height.toInt() ?? 480)
                : (previewSize?.width.toInt() ?? 640);
            final ph = isRotated
                ? (previewSize?.width.toInt() ?? 640)
                : (previewSize?.height.toInt() ?? 480);
            return _showGraphOverlay
                ? SkeletonGraphOverlay(
                    frame: graphFrame,
                    frameWidth: pw,
                    frameHeight: ph,
                  )
                : HandLandmarkOverlay(
                    hands: visibleHands,
                    frameWidth: pw,
                    frameHeight: ph,
                    mirror: false,
                  );
          },
        ),
        SigningSpaceOverlay(
          showUpperBodyGuide: _currentMode != RecognitionMode.alphabet,
          handsDetected: visibleHands.isNotEmpty,
        ),
        Positioned(
          top: topPadding,
          left: 16,
          right: 16,
          child: _buildRecognitionStatus(),
        ),
        if (_showGraphOverlay && graphFrame != null)
          Positioned(
            top: topPadding + 84,
            left: 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.56),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  child: Text(
                    'Blue: body/arms · Green: hands · Yellow: joints',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            bottom: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [_buildActionCard()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFingerspellingWordAssembler() {
    // The result card already shows a single live letter. Show this editor
    // only when it contains useful assembled text or suggestions.
    if ((_activeWordBuffer.length < 2 && _composedSentence.isEmpty) &&
        _suggestedWords.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF0F172A).withValues(alpha: 0.90)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _kAppBlue.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top bar: composed message and active fingerspelling buffer.
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _kAppBlue.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.spellcheck_rounded,
                        color: _kAppBlue,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                          children: [
                            const TextSpan(
                              text: 'Message: ',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF64748B),
                              ),
                            ),
                            if (_composedSentence.isNotEmpty)
                              TextSpan(
                                text: '$_composedSentence ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (_activeWordBuffer.isNotEmpty)
                              TextSpan(
                                text: _activeWordBuffer,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: _kAppBlue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.backspace_outlined, size: 18),
                      tooltip: 'Backspace',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _backspaceLetter,
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: 'Clear',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _clearSentence,
                    ),
                  ],
                ),

                // Suggested words row (Autocomplete & Intent Predictor)
                if (_suggestedWords.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        'Tap to add:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _suggestedWords.map((word) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  avatar: const Icon(
                                    Icons.auto_awesome,
                                    size: 13,
                                    color: _kAppBlue,
                                  ),
                                  label: Text(
                                    word,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  backgroundColor: isDark
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFFEFF6FF),
                                  side: BorderSide(
                                    color: _kAppBlue.withValues(alpha: 0.3),
                                  ),
                                  onPressed: () => _acceptWordSuggestion(word),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isPaused = _isPaused;
    final isWaitingForHands = isPaused && !_isManuallyPaused;
    final hasPrediction = _currentPrediction != null && !isPaused;
    final isReady =
        _isModelReady || (_recognitionProvider?.isModelReady ?? false);
    final confidence = _currentPrediction?.confidence ?? 0.0;
    final isUncertainPrediction = hasPrediction && confidence < 0.60;
    final animationPrediction = isPaused
        ? _lastRecognizedSign
        : _currentPrediction;
    final hasReplay =
        animationPrediction != null &&
        (_gestureReplayFrames.isNotEmpty ||
            SignAnimationCatalog.assetForLabel(
                  _availableAnimationSlugs,
                  animationPrediction.label,
                ) !=
                null ||
            RegExp(
              r'^(?:[A-ZÑ]|NG)$',
              caseSensitive: false,
            ).hasMatch(animationPrediction.label.trim()));

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF0C1220).withValues(alpha: 0.90)
                : Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isWaitingForHands
                  ? const Color(0xFF0D9488).withValues(alpha: 0.45)
                  : isPaused
                  ? _kAppYellow.withValues(alpha: 0.5)
                  : isUncertainPrediction
                  ? const Color(0xFFD97706).withValues(alpha: 0.45)
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.20)
                        : Colors.white),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: isWaitingForHands
                          ? const Color(0xFF0D9488).withValues(alpha: 0.16)
                          : isPaused
                          ? const Color(0xFFD97706).withValues(alpha: 0.18)
                          : isUncertainPrediction
                          ? const Color(0xFFD97706).withValues(alpha: 0.16)
                          : hasPrediction
                          ? _kAppBlue.withValues(alpha: 0.15)
                          : Colors.grey.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isWaitingForHands
                          ? Icons.front_hand_rounded
                          : isPaused
                          ? Icons.pause_circle_filled_rounded
                          : hasPrediction
                          ? (isUncertainPrediction
                                ? Icons.help_outline_rounded
                                : Icons.sign_language_rounded)
                          : Icons.radar_rounded,
                      color: isWaitingForHands
                          ? const Color(0xFF0D9488)
                          : isPaused
                          ? const Color(0xFFD97706)
                          : hasPrediction
                          ? (isUncertainPrediction
                                ? const Color(0xFFD97706)
                                : _kAppBlue)
                          : Colors.grey,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      label: isWaitingForHands
                          ? 'Show your signing hands in the camera frame. Recognition resumes automatically.'
                          : isPaused
                          ? 'Sign recognition paused. Tap resume to continue.'
                          : hasPrediction
                          ? '${isUncertainPrediction ? 'Possible sign' : 'Sign detected'}: ${_currentPrediction!.label}. Model score ${(confidence * 100).toInt()} percent. Check the result before sharing.'
                          : isReady
                          ? 'Camera ready. Follow the framing guide and sign one item at a time.'
                          : 'Initializing sign recognition model.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isWaitingForHands
                                ? 'Show your signing hands'
                                : isPaused
                                ? 'Recognition paused'
                                : hasPrediction
                                ? (isUncertainPrediction
                                      ? 'Possible: ${_currentPrediction!.label}'
                                      : _currentPrediction!.label)
                                : isReady
                                ? 'Ready to sign'
                                : 'Initializing FSL model...',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: (isPaused || hasPrediction) ? 20 : 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: (isPaused || hasPrediction)
                                  ? 0.4
                                  : 0.0,
                              color: isPaused
                                  ? const Color(0xFFD97706)
                                  : (isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isWaitingForHands)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D9488),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.front_hand_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'WAITING',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 10,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (isPaused)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.pause_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'PAUSED',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (hasPrediction && isReady)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isUncertainPrediction
                                ? _kAppYellow
                                : _kAppBlue,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Semantics(
                            label:
                                'Model score ${(confidence * 100).toInt()} percent. Check this result before sharing.',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isUncertainPrediction
                                      ? Icons.help_outline_rounded
                                      : Icons.analytics_outlined,
                                  size: 13,
                                  color: isUncertainPrediction
                                      ? const Color(0xFF111827)
                                      : Colors.white,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${(confidence * 100).toInt()}% score',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                    color: isUncertainPrediction
                                        ? const Color(0xFF111827)
                                        : Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      if (!isWaitingForHands)
                        IconButton(
                          icon: Icon(
                            isPaused
                                ? Icons.play_circle_fill_rounded
                                : Icons.pause_circle_outline_rounded,
                            color: isPaused
                                ? const Color(0xFF10B981)
                                : (isDark
                                      ? Colors.white70
                                      : const Color(0xFF64748B)),
                            size: 24,
                          ),
                          tooltip: isPaused
                              ? 'Resume recognition'
                              : 'Pause recognition',
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                          onPressed: _toggleManualPause,
                        ),
                    ],
                  ),
                ],
              ),
              if (_activeWordBuffer.isNotEmpty ||
                  _composedSentence.isNotEmpty ||
                  _suggestedWords.isNotEmpty)
                _buildFingerspellingWordAssembler(),
              const SizedBox(height: 5),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.bookmark_add_rounded,
                    label: 'Record',
                    tooltip:
                        'Record a consented skeleton sequence for FSL training',
                    semanticLabel: 'Record an FSL training sample',
                    onPressed: _recordTrainingSample,
                    color: const Color(0xFFDC2626),
                  ),
                  _ActionButton(
                    icon: Icons.volume_up_rounded,
                    label: 'Speak',
                    tooltip: 'Pronounce sign or sentence',
                    semanticLabel: 'Speak sign or sentence aloud',
                    onPressed: _speakComposedSentence,
                    color: _kAppBlue,
                  ),
                  _ActionButton(
                    icon: Icons.copy_rounded,
                    label: 'Copy',
                    tooltip: 'Copy text to clipboard',
                    semanticLabel: 'Copy text to clipboard',
                    onPressed: _copyToClipboard,
                    color: const Color(0xFF0D9488),
                  ),
                  _ActionButton(
                    icon: Icons.bookmark_add_rounded,
                    label: 'Save',
                    tooltip: 'Save sign to history',
                    semanticLabel: 'Save sign to history',
                    onPressed: _saveCurrentPrediction,
                    color: _kAppYellow,
                  ),
                  _ActionButton(
                    icon: Icons.menu_book_rounded,
                    label: 'FSL Guide',
                    tooltip: 'Open FSL gesture guide and alphabet',
                    semanticLabel: 'Open FSL gesture guide',
                    onPressed: _showGuide,
                    color: const Color(0xFF6366F1),
                  ),
                  if (hasReplay)
                    _ActionButton(
                      icon: Icons.play_arrow_rounded,
                      label: 'Replay',
                      tooltip: 'View signing replay',
                      semanticLabel: 'View signing replay',
                      onPressed: () =>
                          _showPredictionReplay(isDark, animationPrediction),
                      color: const Color(0xFF64748B),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openTypeAndSpeakFallback,
                  icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  label: Text(
                    'Type a message instead',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kAppBlue,
                    side: BorderSide(color: _kAppBlue.withValues(alpha: 0.45)),
                    minimumSize: const Size.fromHeight(38),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPredictionAnimation(bool isDark, SignResult prediction) {
    final animationAsset = SignAnimationCatalog.assetForLabel(
      _availableAnimationSlugs,
      prediction.label,
    );
    final hasMotionReplay = _gestureReplayFrames.isNotEmpty;
    final isLetter = RegExp(
      r'^(?:[A-ZÑ]|NG)$',
      caseSensitive: false,
    ).hasMatch(prediction.label.trim());
    if (animationAsset == null && !hasMotionReplay && !isLetter) {
      return const SizedBox.shrink();
    }

    final cardColor = isDark
        ? const Color(0xFF111C31)
        : const Color(0xFFF2F6FC);
    final borderColor = isDark
        ? const Color(0xFF2A4168)
        : const Color(0xFFD7E3F4);

    return Container(
      height: 96,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 96,
              height: 82,
              child: ColoredBox(
                color: isDark ? const Color(0xFF0A1221) : Colors.white,
                child: animationAsset != null
                    ? Image.asset(
                        animationAsset,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.movie_filter_outlined,
                          color: _kAppBlue,
                        ),
                      )
                    : hasMotionReplay
                    ? GestureMotionReplay(
                        frames: _gestureReplayFrames,
                        sourceAspectRatio: _landmarkFrameAspectRatio,
                      )
                    : const Center(
                        child: Icon(
                          Icons.back_hand_outlined,
                          color: _kAppBlue,
                          size: 28,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  animationAsset != null
                      ? 'FSL sign animation'
                      : isLetter
                      ? 'Letter ${prediction.label} · motion replay'
                      : 'Signer motion replay',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF172033),
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  animationAsset != null
                      ? 'Animated reference · works offline'
                      : hasMotionReplay
                      ? 'Replay of the tracked hand motion'
                      : 'Tracking hand motion for replay',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark
                        ? const Color(0xFF9FB1CC)
                        : const Color(0xFF64748B),
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.play_circle_fill_rounded,
            color: _kAppBlue,
            size: 25,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildRecognitionStatus() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isReady =
        _isModelReady || (_recognitionProvider?.isModelReady ?? false);
    final isPaused = _isPaused;
    final isWaitingForHands = isPaused && !_isManuallyPaused;
    final isTracking = _liveLandmarks.isNotEmpty && !isPaused;
    final hasPrediction = _currentPrediction != null && !isPaused;
    final isUncertainPrediction =
        hasPrediction && _currentPrediction!.confidence < 0.60;
    final framingHint = _currentMode == RecognitionMode.alphabet
        ? 'Keep your signing hand centered and fully visible.'
        : 'Place the phone at eye level and step back until your head, chest, and both hands fit in the guide.';
    final signingHint = switch (_currentMode) {
      RecognitionMode.phrases =>
        'Sign one trained phrase as a single gesture, then lower your hands. Continuous sentence translation is not available in this mode.',
      RecognitionMode.alphabet =>
        'Hold one letter steady; lower your hand between letters.',
      RecognitionMode.medical =>
        'Sign one health item, then lower your hands briefly.',
      RecognitionMode.auto =>
        'Sign one supported item at a time, then lower your hands briefly.',
    };

    final String message;
    final String hint;
    final IconData icon;
    final Color iconColor;

    if (_recognitionError != null) {
      message = _recognitionError!;
      hint = 'Check the camera and lighting, then try again.';
      icon = Icons.error_outline_rounded;
      iconColor = Colors.white;
    } else if (isWaitingForHands) {
      message = 'Show your signing hands';
      hint = 'Step back; keep your upper body and signing hands in the guide.';
      icon = Icons.front_hand_rounded;
      iconColor = Colors.white;
    } else if (isPaused) {
      message = 'Recognition paused';
      hint = 'Tap the play button to resume.';
      icon = Icons.pause_circle_rounded;
      iconColor = Colors.white;
    } else if (isUncertainPrediction) {
      message = 'Possible match • Check the result below';
      hint = 'Not right? Sign it again or use the text option below.';
      icon = Icons.help_outline_rounded;
      iconColor = const Color(0xFFD97706);
    } else if (hasPrediction) {
      message = 'Sign detected • Check the result below';
      hint = 'Confirm the label before speaking or sharing it.';
      icon = Icons.sign_language_rounded;
      iconColor = _kAppBlue;
    } else if (isTracking) {
      message = 'Hands in frame';
      hint = signingHint;
      icon = Icons.front_hand_rounded;
      iconColor = const Color(0xFF10B981); // Emerald Green
    } else if (isReady) {
      message = 'Ready to sign';
      hint = framingHint;
      icon = Icons.videocam_rounded;
      iconColor = _kAppBlue;
    } else {
      message = 'Preparing sign recognition…';
      hint = 'Keep the camera open while the model starts.';
      icon = Icons.hourglass_top_rounded;
      iconColor = _kAppYellow;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _recognitionError != null
                ? Colors.redAccent.withValues(alpha: 0.85)
                : isWaitingForHands
                ? const Color(0xFF0D9488).withValues(alpha: 0.92)
                : isPaused
                ? const Color(0xFFD97706).withValues(alpha: 0.90)
                : isUncertainPrediction
                ? (isDark
                      ? const Color(0xFF3B321B).withValues(alpha: 0.94)
                      : const Color(0xFFFFF4CC).withValues(alpha: 0.96))
                : (isDark
                      ? const Color(0xFF0C1220).withValues(alpha: 0.75)
                      : Colors.white.withValues(alpha: 0.85)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isWaitingForHands
                  ? const Color(0xFF0D9488).withValues(alpha: 0.6)
                  : isPaused
                  ? _kAppYellow.withValues(alpha: 0.6)
                  : isUncertainPrediction
                  ? const Color(0xFFD97706).withValues(alpha: 0.55)
                  : isTracking
                  ? const Color(0xFF10B981).withValues(alpha: 0.5)
                  : (isDark ? Colors.white12 : Colors.white60),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    color:
                        (_recognitionError != null || isPaused) &&
                            !isUncertainPrediction
                        ? Colors.white
                        : iconColor,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color:
                                (_recognitionError != null || isPaused) &&
                                    !isUncertainPrediction
                                ? Colors.white
                                : (isDark
                                      ? Colors.white
                                      : const Color(0xFF0F172A)),
                          ),
                        ),
                        if (_recognitionError == null) ...[
                          const SizedBox(height: 3),
                          Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: isPaused
                                  ? Colors.white.withValues(alpha: 0.92)
                                  : isUncertainPrediction
                                  ? (isDark
                                        ? const Color(0xFFE6C86E)
                                        : const Color(0xFF805000))
                                  : isDark
                                  ? Colors.white70
                                  : const Color(0xFF475569),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (_recognitionError == null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (isReady)
                      Expanded(
                        child: Text(
                          kIsWeb ? 'Online recognition' : 'Works offline',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF475569),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    _statusControl(
                      icon: _currentMode == RecognitionMode.phrases
                          ? Icons.chat_bubble_outline_rounded
                          : _currentMode == RecognitionMode.alphabet
                          ? Icons.spellcheck_rounded
                          : _currentMode == RecognitionMode.medical
                          ? Icons.medical_services_rounded
                          : Icons.auto_mode_rounded,
                      label: _currentMode == RecognitionMode.phrases
                          ? 'Known phrases'
                          : _currentMode == RecognitionMode.alphabet
                          ? 'A–Z'
                          : _currentMode == RecognitionMode.medical
                          ? 'Medical'
                          : 'Auto',
                      semanticLabel: 'Toggle sign recognition mode',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _cycleRecognitionMode();
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusControl({
    required IconData icon,
    required String label,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _kAppBlue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kAppBlue.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: _kAppBlue),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _kAppBlue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGuide() {
    showFslGuideSheet(context);
  }

  void _showPredictionReplay(bool isDark, SignResult prediction) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: isDark ? const Color(0xFF0C1220) : Colors.white,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Signing replay',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              _buildPredictionAnimation(isDark, prediction),
            ],
          ),
        ),
      ),
    );
  }

  void _showBenchmarkSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              4,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Android benchmark (local only)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Measures camera frames delivered over the most recent 10 seconds and the time from your completion mark to the next result drawn on screen. Nothing is uploaded.',
                    style: TextStyle(color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _benchmarkDeviceController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Device model / build',
                      hintText: 'e.g., Pixel 7, app 1.0.0+2019',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _benchmarkAndroidController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Android version',
                      hintText: 'e.g., Android 14',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _benchmarkConditionsController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Test conditions',
                      hintText:
                          'lighting, camera, distance, mode, battery/thermal state',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _benchmarkMetric(
                        'Camera FPS',
                        '${_benchmark.sustainedFps.toStringAsFixed(1)} (last 10 s)',
                      ),
                      _benchmarkMetric('Trials', '${_benchmark.sampleCount}'),
                      _benchmarkMetric(
                        'Median',
                        _benchmark.medianLatencyMs == null
                            ? '—'
                            : '${_benchmark.medianLatencyMs} ms',
                      ),
                      _benchmarkMetric(
                        'P95',
                        _benchmark.p95LatencyMs == null
                            ? '—'
                            : '${_benchmark.p95LatencyMs} ms',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!_benchmark.isRunning)
                    FilledButton.icon(
                      onPressed: () {
                        _benchmark.start(DateTime.now());
                        setState(() {});
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Start new local run'),
                    )
                  else ...[
                    FilledButton.icon(
                      onPressed: _benchmark.awaitingResult
                          ? null
                          : () {
                              _benchmark.markSignCompletion(DateTime.now());
                              setSheetState(() {});
                            },
                      icon: const Icon(Icons.flag_rounded),
                      label: Text(
                        _benchmark.awaitingResult
                            ? 'Waiting for displayed result…'
                            : 'Mark sign complete',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: _benchmark.localReport(
                              device: _benchmarkDeviceController.text,
                              androidVersion: _benchmarkAndroidController.text,
                              conditions: _benchmarkConditionsController.text,
                            ),
                          ),
                        );
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                            content: Text('Local benchmark report copied.'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy local report'),
                    ),
                    TextButton(
                      onPressed: () {
                        _benchmark.stop();
                        setState(() {});
                        setSheetState(() {});
                      },
                      child: const Text('Stop benchmark'),
                    ),
                  ],
                  const SizedBox(height: 4),
                  const Text(
                    'For each trial, begin signing, tap “Mark sign complete” at the end of the gesture, then wait for the result. Collect at least 20 trials after the FPS readout has stabilised.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _benchmarkMetric(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: _kAppBlue.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      '$label: $value',
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color color;
  final String? tooltip;
  final String? semanticLabel;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.color,
    this.tooltip,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      tooltip: tooltip ?? label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                onPressed();
              },
              borderRadius: BorderRadius.circular(16),
              child: Tooltip(
                message: tooltip ?? label,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: color.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                  child: Center(child: Icon(icon, color: color, size: 20)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
