import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import '../providers/recognition_provider.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/database_helper.dart';
import '../models/sign_result.dart';
import '../widgets/camera_preview.dart';
import '../widgets/signing_space_overlay.dart';
import '../widgets/hand_landmark_overlay.dart';
import '../widgets/connectivity_badge.dart';
import '../services/word_prediction_service.dart';
import '../services/settings_service.dart';
import '../services/model_updater.dart';
import '../services/recognition/recognition_service.dart' show RecognitionMode;

const Color _kAppBlue = Color(0xFF0138FF);
const Color _kAppYellow = Color(0xFFFFC801);

class SignToTextScreen extends StatefulWidget {
  const SignToTextScreen({super.key});

  @override
  State<SignToTextScreen> createState() => _SignToTextScreenState();
}

class _SignToTextScreenState extends State<SignToTextScreen> with WidgetsBindingObserver {
  late CameraService _cameraService;
  late TtsService _ttsService;
  SignResult? _currentPrediction;
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
  RecognitionProvider? _recognitionProvider;
  StreamSubscription<SignResult>? _predictionSubscription;
  StreamSubscription<bool>? _pauseSubscription;
  StreamSubscription<CameraImage>? _frameSubscription;
  StreamSubscription<List<List<Offset>>>? _landmarksSubscription;
  List<List<Offset>> _liveLandmarks = [];
  bool _isCheckingModelUpdate = false;
  RecognitionMode _currentMode = RecognitionMode.auto;

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
          _currentMode = RecognitionMode.auto;
          break;
      }
    });
    _recognitionProvider?.setMode(_currentMode);
    final modeLabel = _currentMode == RecognitionMode.phrases
        ? 'Phrases (Kamusta/Hello, Salamat, etc.)'
        : _currentMode == RecognitionMode.alphabet
            ? 'Alphabet (A to Z Letters)'
            : 'Auto (Phrases & Alphabet)';
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
  String? _lastAppendedLetter;
  DateTime _lastLetterTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraService = CameraService();
    _ttsService = context.read<TtsService>();
    _recognitionProvider = context.read<RecognitionProvider>();
    _predictionSubscription = _recognitionProvider!.predictions.listen((
      prediction,
    ) {
      if (mounted) {
        if (_currentPrediction?.label != prediction.label) {
          // Tactile haptic feedback for Deaf / Hard-of-Hearing users
          HapticFeedback.mediumImpact();
        }
        setState(() {
          _currentPrediction = prediction;
        });
        _handlePredictionAssembly(prediction);
      }
    });

    _pauseSubscription = _recognitionProvider?.pauseStatus?.listen((paused) {
      if (mounted && _isPaused != paused) {
        if (paused) {
          // Tactile haptic pulse to notify signer that Open Palm pause & buffer flush triggered
          HapticFeedback.heavyImpact();
        }
        setState(() {
          _isPaused = paused;
          if (paused) {
            _currentPrediction = null;
          }
        });
      }
    });

    _landmarksSubscription = _recognitionProvider?.landmarkPointsStream?.listen((hands) {
      if (mounted) {
        setState(() => _liveLandmarks = hands);
      }
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

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _cameraService.dispose();
      if (mounted) {
        setState(() => _isCameraInitialized = false);
      }
    } else if (state == AppLifecycleState.resumed) {
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
          _cameraError = e.toString();
        });
      }
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch camera: $e')),
        );
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? _kAppBlue : null,
                      ),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check_circle_rounded, color: _kAppBlue)
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
    if (_isProcessingFrame || _recognitionProvider == null) return;
    _isProcessingFrame = true;
    final orientation = _cameraService.selectedCamera?.sensorOrientation;
    final isFrontCamera = _cameraService.selectedCamera?.lensDirection == CameraLensDirection.front;
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
      final remoteManifest = serverUrl.isNotEmpty ? '$serverUrl/api/v1/ota/manifest' : ModelUpdater.defaultRemoteManifestUrl;
      final updater = ModelUpdater(remoteManifestUrl: remoteManifest);
      final updateInfo = await updater.checkForUpdates();
      if (updateInfo.status == UpdateStatus.updateAvailable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('New FSL Model Available (${updateInfo.version}). Tap to install.'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'UPDATE',
              onPressed: () async {
                await for (final progress in updater.downloadUpdate(updateInfo)) {
                  if (progress.status == UpdateStatus.downloading && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Downloading updated model: ${(progress.progress * 100).toInt()}%'),
                        duration: const Duration(milliseconds: 600),
                      ),
                    );
                  } else if (progress.status == UpdateStatus.upToDate && mounted) {
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
              content: Text('Private Mode active: sign is not saved to history.'),
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
    final label = prediction.label.trim();
    // Check if the prediction is a single letter (A-Z or Ñ)
    final isSingleLetter = label.length == 1 &&
        (RegExp(r'^[A-ZÑ]$', caseSensitive: false).hasMatch(label));

    final now = DateTime.now();

    if (isSingleLetter) {
      // Debounce: append new letter if it differs from last letter OR user has held sign for >= 1200ms
      final isNewLetter = label != _lastAppendedLetter;
      final isHeldDuration = now.difference(_lastLetterTime).inMilliseconds >= 1200;

      if (isNewLetter || isHeldDuration) {
        setState(() {
          _activeWordBuffer += label.toUpperCase();
          _lastAppendedLetter = label;
          _lastLetterTime = now;
          _suggestedWords = _wordPredictionService.getPredictions(_activeWordBuffer);
        });
      }
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
      _lastAppendedLetter = null;
    });
  }

  void _backspaceLetter() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_activeWordBuffer.isNotEmpty) {
        _activeWordBuffer = _activeWordBuffer.substring(0, _activeWordBuffer.length - 1);
        _suggestedWords = _wordPredictionService.getPredictions(_activeWordBuffer);
      } else if (_composedSentence.isNotEmpty) {
        final words = _composedSentence.split(' ');
        words.removeLast();
        _composedSentence = words.join(' ');
      }
      _lastAppendedLetter = null;
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
      _lastAppendedLetter = null;
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
        ? (_activeWordBuffer.isNotEmpty ? '$_composedSentence $_activeWordBuffer' : _composedSentence)
        : (_activeWordBuffer.isNotEmpty ? _activeWordBuffer : (_currentPrediction?.label ?? ''));

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
            const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 18),
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
    setState(() {
      _isPaused = !_isPaused;
    });
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isPaused ? '⏸️ Recognition paused' : '▶️ Recognition resumed'),
        duration: const Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _speakComposedSentence() async {
    final textToSpeak = _composedSentence.isNotEmpty
        ? (_activeWordBuffer.isNotEmpty ? '$_composedSentence $_activeWordBuffer' : _composedSentence)
        : (_activeWordBuffer.isNotEmpty ? _activeWordBuffer : (_currentPrediction?.label ?? ''));

    if (textToSpeak.trim().isNotEmpty) {
      HapticFeedback.mediumImpact();
      try {
        await _ttsService.speak(textToSpeak.trim());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Speech synthesis error: $e')),
          );
        }
      }
    }
  }

  @override
  void deactivate() {
    ScaffoldMessenger.of(context).clearSnackBars();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _predictionSubscription?.cancel();
    _pauseSubscription?.cancel();
    _landmarksSubscription?.cancel();
    _frameSubscription?.cancel();
    _cameraService.dispose();
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Sign to Text',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 19,
                letterSpacing: -0.4,
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
          if (kIsWeb)
            IconButton(
              icon: Icon(
                _useBackendFeed ? Icons.sensors_rounded : Icons.videocam_rounded,
                color: _kAppBlue,
              ),
              tooltip: _useBackendFeed ? 'Switch to Browser Direct Camera' : 'Switch to Backend AI Video Stream',
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
          if (!_useBackendFeed && _isCameraInitialized && _cameraService.canSwitchCamera)
            IconButton(
              icon: const Icon(Icons.cameraswitch_rounded),
              tooltip: 'Switch between front and back camera',
              onPressed: () {
                HapticFeedback.selectionClick();
                _showCameraPicker();
              },
            ),
          const ConnectivityBadge(),
          const SizedBox(width: 14),
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
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.settings_rounded),
                        label: const Text(
                          'Open App Settings',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          _checkPermissionAndStart();
                        },
                        child: const Text('I have allowed permission (Check again)'),
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
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.check_circle_outline_rounded),
                        label: const Text(
                          'Allow Camera Access',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
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
    final isPermIssue = _isPermanentlyDenied ||
        (_cameraError != null && _cameraError!.toLowerCase().contains('permission'));
    final isInUseIssue = _cameraError != null &&
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
                        color: (isInUseIssue ? Colors.orange : theme.colorScheme.error)
                            .withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        isInUseIssue
                            ? Icons.videocam_off_rounded
                            : Icons.error_outline_rounded,
                        size: 38,
                        color: isInUseIssue ? Colors.orange : theme.colorScheme.error,
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
                          : (_cameraError ?? 'Unable to connect to camera.'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Troubleshooting Steps:',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            _buildTroubleshootItem('1. Close other background apps using the camera (video calls, camera app).'),
                            _buildTroubleshootItem('2. Verify Camera permission is enabled for TinigSenyas in device Settings.'),
                            _buildTroubleshootItem('3. If the camera remains unresponsive, restart TinigSenyas.'),
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
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
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
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
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
                          child: const Icon(Icons.sensors_off_rounded, color: Colors.orange, size: 34),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Backend AI Server Offline',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'The Python server (server.py) is not running on port 5000. You can switch to your direct browser webcam right now, or launch run_web.ps1.',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                  const Icon(Icons.videocam_off_rounded, size: 48, color: Colors.orange),
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
        const SigningSpaceOverlay(),
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
                children: [
                  _buildFingerspellingWordAssembler(),
                  _buildActionCard(),
                ],
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
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, height: 1.3),
      ),
    );
  }

  Widget _buildCameraView() {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = mediaQuery.padding.top + kToolbarHeight + 8;

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreviewWidget(
          cameraService: _cameraService,
        ),
        Builder(
          builder: (context) {
            final controller = _cameraService.controller;
            final isRotated = !kIsWeb && MediaQuery.of(context).orientation == Orientation.portrait;
            final previewSize = controller?.value.previewSize;
            final pw = isRotated ? (previewSize?.height.toInt() ?? 480) : (previewSize?.width.toInt() ?? 640);
            final ph = isRotated ? (previewSize?.width.toInt() ?? 640) : (previewSize?.height.toInt() ?? 480);
            return HandLandmarkOverlay(
              hands: _liveLandmarks,
              frameWidth: pw,
              frameHeight: ph,
              mirror: false,
            );
          },
        ),
        const SigningSpaceOverlay(),
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
                children: [
                  _buildFingerspellingWordAssembler(),
                  _buildActionCard(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFingerspellingWordAssembler() {
    if (_activeWordBuffer.isEmpty && _composedSentence.isEmpty && _suggestedWords.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF0F172A).withValues(alpha: 0.90)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _kAppBlue.withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top bar: Composed sentence and active letter buffer
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _kAppBlue.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.spellcheck_rounded, color: _kAppBlue, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                          children: [
                            if (_composedSentence.isNotEmpty)
                              TextSpan(
                                text: '$_composedSentence ',
                                style: const TextStyle(fontWeight: FontWeight.w600),
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
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.volume_up_rounded, color: _kAppBlue, size: 20),
                      tooltip: 'Speak sentence',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _speakComposedSentence,
                    ),
                    const SizedBox(width: 8),
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
                        'Suggestions:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                                  avatar: const Icon(Icons.auto_awesome, size: 13, color: _kAppBlue),
                                  label: Text(
                                    word,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
    final hasPrediction = _currentPrediction != null && !isPaused;
    final isReady = _isModelReady || (_recognitionProvider?.isModelReady ?? false);
    final confidence = _currentPrediction?.confidence ?? 0.0;
    final isConfidenceHigh = confidence >= 0.70;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF0C1220).withValues(alpha: 0.90)
                : Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isPaused
                  ? const Color(0xFFFFC801).withValues(alpha: 0.5)
                  : (isDark ? Colors.white.withValues(alpha: 0.20) : Colors.white),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isPaused
                          ? const Color(0xFFD97706).withValues(alpha: 0.18)
                          : hasPrediction
                              ? (isConfidenceHigh
                                  ? const Color(0xFF10B981).withValues(alpha: 0.18)
                                  : _kAppBlue.withValues(alpha: 0.15))
                              : Colors.grey.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPaused
                          ? Icons.pause_circle_filled_rounded
                          : hasPrediction
                              ? (isConfidenceHigh ? Icons.verified_rounded : Icons.check_circle_rounded)
                              : Icons.radar_rounded,
                      color: isPaused
                          ? const Color(0xFFD97706)
                          : hasPrediction
                              ? (isConfidenceHigh ? const Color(0xFF10B981) : _kAppBlue)
                              : Colors.grey,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      label: isPaused
                          ? 'Sign recognition paused. Open palm detected. Lower hand to sign next word.'
                          : hasPrediction
                              ? 'Recognized Filipino sign: ${_currentPrediction!.label}, confidence ${(confidence * 100).toInt()} percent'
                              : isReady
                                  ? 'Camera ready. Position hand gestures in frame to sign.'
                                  : 'Initializing sign recognition model.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isPaused
                                ? '⏸️ Paused (Open Palm)'
                                : hasPrediction
                                    ? _currentPrediction!.label
                                    : isReady
                                        ? 'Position hands to sign...'
                                        : 'Initializing FSL model...',
                            style: TextStyle(
                              fontSize: (isPaused || hasPrediction) ? 20 : 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: (isPaused || hasPrediction) ? 0.4 : 0.0,
                              color: isPaused
                                  ? const Color(0xFFD97706)
                                  : (isDark ? Colors.white : const Color(0xFF0F172A)),
                            ),
                          ),
                          if (isPaused)
                            Text(
                              'Buffer flushed • Ready for next sign',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                              ),
                            )
                          else if (hasPrediction)
                            Text(
                              'Filipino Sign Language',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPaused)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.pause_rounded, size: 14, color: Colors.white),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: isConfidenceHigh
                                ? const Color(0xFF10B981)
                                : (confidence >= 0.60 ? _kAppBlue : _kAppYellow),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isConfidenceHigh ? Icons.verified_rounded : Icons.trending_up_rounded,
                                size: 13,
                                color: (isConfidenceHigh || confidence >= 0.60) ? Colors.white : const Color(0xFF111827),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${(confidence * 100).toInt()}%',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                  color: (isConfidenceHigh || confidence >= 0.60) ? Colors.white : const Color(0xFF111827),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: Icon(
                          isPaused ? Icons.play_circle_fill_rounded : Icons.pause_circle_outline_rounded,
                          color: isPaused ? const Color(0xFF10B981) : (isDark ? Colors.white70 : const Color(0xFF64748B)),
                          size: 24,
                        ),
                        tooltip: isPaused ? 'Resume recognition' : 'Pause recognition',
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                        onPressed: _toggleManualPause,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecognitionStatus() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isReady = _isModelReady || (_recognitionProvider?.isModelReady ?? false);
    final isPaused = _isPaused;
    final isTracking = _liveLandmarks.isNotEmpty && !isPaused;

    final String message;
    final IconData icon;
    final Color iconColor;

    if (_recognitionError != null) {
      message = _recognitionError!;
      icon = Icons.error_outline_rounded;
      iconColor = Colors.white;
    } else if (isPaused) {
      message = '⏸️ Reader Paused • Lower hand to resume';
      icon = Icons.pause_circle_rounded;
      iconColor = Colors.white;
    } else if (isTracking) {
      message = '👋 Hand tracked • Signing active';
      icon = Icons.front_hand_rounded;
      iconColor = const Color(0xFF10B981); // Emerald Green
    } else if (isReady) {
      message = '✨ Ready • Raise hand in front of camera';
      icon = Icons.videocam_rounded;
      iconColor = _kAppBlue;
    } else {
      message = 'Initializing FSL sign engine...';
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
                : isPaused
                    ? const Color(0xFFD97706).withValues(alpha: 0.90)
                    : (isDark ? const Color(0xFF0C1220).withValues(alpha: 0.75) : Colors.white.withValues(alpha: 0.85)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPaused
                  ? const Color(0xFFFFC801).withValues(alpha: 0.6)
                  : isTracking
                      ? const Color(0xFF10B981).withValues(alpha: 0.5)
                      : (isDark ? Colors.white12 : Colors.white60),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: (_recognitionError != null || isPaused) ? Colors.white : iconColor,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: (_recognitionError != null || isPaused)
                        ? Colors.white
                        : (isDark ? Colors.white : const Color(0xFF0F172A)),
                  ),
                ),
              ),
              if (_cameraService.canSwitchCamera) ...[
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'Switch between front and back camera',
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _showCameraPicker();
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: _kAppBlue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _kAppBlue.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cameraswitch_rounded, size: 16, color: _kAppBlue),
                          SizedBox(width: 6),
                          Text(
                            'Switch',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _kAppBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Semantics(
                button: true,
                label: 'Toggle sign recognition mode',
                child: InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _cycleRecognitionMode();
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _kAppBlue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kAppBlue.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _currentMode == RecognitionMode.phrases
                              ? Icons.chat_bubble_outline_rounded
                              : _currentMode == RecognitionMode.alphabet
                                  ? Icons.spellcheck_rounded
                                  : Icons.auto_mode_rounded,
                          size: 15,
                          color: _kAppBlue,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _currentMode == RecognitionMode.phrases
                              ? 'Phrases'
                              : _currentMode == RecognitionMode.alphabet
                                  ? 'A–Z'
                                  : 'Auto',
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGuide() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (context, scrollController) => ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0E1626).withValues(alpha: 0.98)
                      : Colors.white.withValues(alpha: 0.98),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(Icons.menu_book_rounded, color: _kAppBlue, size: 22),
                          const SizedBox(width: 8),
                          const Text(
                            'FSL Reference & Tips',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            tooltip: 'Close guide',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TabBar(
                        indicatorColor: _kAppBlue,
                        indicatorWeight: 3,
                        labelColor: _kAppBlue,
                        unselectedLabelColor: isDark ? Colors.white60 : const Color(0xFF64748B),
                        labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                        tabs: const [
                          Tab(text: 'Phrases'),
                          Tab(text: 'Alphabet A–Z'),
                          Tab(text: 'Accuracy Tips'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: TabBarView(
                          children: [
                            // 1. Phrases Tab (Trained FSL Vocabulary)
                            ListView(
                              controller: scrollController,
                              physics: const BouncingScrollPhysics(),
                              children: const [
                                _GuideItem('KAMUSTA', 'Friendly open-palm wave at cheek/shoulder level with palm facing forward'),
                                _GuideItem('KAMUSTA KA', 'Curved hands with palms up rotate outward toward conversation partner'),
                                _GuideItem('MABUTI', 'Fingertips of dominant flat hand touch chin and move forward and down'),
                                _GuideItem('SALAMAT', 'Flat open hand touches chin/lips then extends gracefully toward receiver'),
                                _GuideItem('WALANG ANUMAN', 'Open flat palm sweeps inward toward chest with a welcoming nod'),
                                _GuideItem('MAGANDANG UMAGA', 'Sign Mabuti (chin forward) then dominant hand rises upward like rising sun'),
                                _GuideItem('MAGANDANG HAPON', 'Sign Mabuti then dominant hand tilts downward at 45° angle over arm'),
                                _GuideItem('MAGANDANG GABI', 'Sign Mabuti then curved hand covers non-dominant wrist like sunset'),
                                _GuideItem('IKINAGAGALAK KITANG MAKILALA', 'Index fingers of both hands approach each other at chest level'),
                                _GuideItem('MAGKITA TAYO BUKAS', 'V-handshape points from eyes outward, then thumb flicks forward at cheek'),
                                _GuideItem('OO', 'Closed fist nods up and down at chest height mimicking a nodding head'),
                                _GuideItem('HINDI', 'Index and middle finger extended together snap sharply to meet the thumb'),
                                _GuideItem('TAMA', 'Dominant index finger edge drops firmly across top of non-dominant index finger'),
                                _GuideItem('MALI', 'Y-handshape (thumb and pinky extended) touches the center of the chin'),
                                _GuideItem('ALAM', 'Fingertips of flat hand tap temple/forehead once with confident nod'),
                                _GuideItem('HINDI ALAM', 'Fingertips touch temple then twist sharply outward with head shake'),
                                _GuideItem('NAIINTINDIHAN', 'Index finger flicks upward from thumb near temple like a light bulb'),
                                _GuideItem('HINDI MAINTINDIHAN', 'Index flick near temple accompanied by furrowed brow and head shake'),
                                _GuideItem('BINGI', 'Index finger touches ear then moves forward to touch near the mouth'),
                                _GuideItem('MAHIRAP MAKARINIG', 'H-handshape taps downward once then twice indicating partial hearing'),
                              ],
                            ),
                            // 2. Alphabet Tab
                            ListView(
                              controller: scrollController,
                              physics: const BouncingScrollPhysics(),
                              children: const [
                                _GuideItem('A', 'Closed fist with thumb resting alongside index finger'),
                                _GuideItem('B', 'Four fingers held upright together, thumb folded flat across palm'),
                                _GuideItem('C', 'Hand curved into a "C" shape facing outward'),
                                _GuideItem('D', 'Index finger points straight up; thumb and other 3 fingers form a circle'),
                                _GuideItem('E', 'All four fingertips curled down resting lightly on thumb tip'),
                                _GuideItem('F', 'Index finger and thumb touch in circle; other 3 fingers extended upward'),
                                _GuideItem('G', 'Index finger and thumb point sideways parallel to each other'),
                                _GuideItem('H', 'Index and middle fingers extended together pointing horizontally'),
                                _GuideItem('I', 'Little finger (pinky) pointed straight up; all other fingers closed in fist'),
                                _GuideItem('J', 'Little finger up, trace the curve of a "J" in the air'),
                                _GuideItem('K', 'Index finger upright, middle tilted forward, thumb placed between them'),
                                _GuideItem('L', 'Thumb and index finger form an "L" shape upright'),
                                _GuideItem('M', 'Thumb tucked under three folded fingers (index, middle, ring)'),
                                _GuideItem('N', 'Thumb tucked under two folded fingers (index and middle)'),
                                _GuideItem('O', 'All fingertips touch thumb tip forming an "O" oval'),
                                _GuideItem('P', 'Same as "K" handshape pointed downwards toward floor'),
                                _GuideItem('Q', 'Same as "G" handshape pointed downwards toward floor'),
                                _GuideItem('R', 'Middle finger crossed over index finger upright'),
                                _GuideItem('S', 'Closed fist with thumb folded tightly across the front of fingers'),
                                _GuideItem('T', 'Thumb inserted between index and middle finger with fist closed'),
                                _GuideItem('U', 'Index and middle fingers held straight up touching together'),
                                _GuideItem('V', 'Index and middle fingers upright spread apart forming a "V"'),
                                _GuideItem('W', 'Index, middle, and ring fingers spread upright forming a "W"'),
                                _GuideItem('X', 'Index finger crooked into a hook; other fingers closed in fist'),
                                _GuideItem('Y', 'Thumb and pinky extended outward like a "shaka" phone sign'),
                                _GuideItem('Z', 'Index finger points and traces a "Z" in the air'),
                              ],
                            ),
                            // 3. Accuracy Tips Tab
                            ListView(
                              controller: scrollController,
                              physics: const BouncingScrollPhysics(),
                              children: const [
                                _GuideTipCard(
                                  icon: Icons.light_mode_rounded,
                                  title: 'Good, Even Lighting',
                                  description: 'Face a light source or window so your hands and face have clear contrast without heavy backlighting or shadows.',
                                ),
                                _GuideTipCard(
                                  icon: Icons.straighten_rounded,
                                  title: 'Optimal Distance (0.5m – 1.0m)',
                                  description: 'Position your phone on a stand or desk at chest level so your head, shoulders, and both hands remain in frame.',
                                ),
                                _GuideTipCard(
                                  icon: Icons.front_hand_rounded,
                                  title: 'Open Palm = Pause Reading',
                                  description: 'Show an open, stationary palm facing the camera to pause word accumulation while thinking or resting.',
                                ),
                                _GuideTipCard(
                                  icon: Icons.toggle_on_rounded,
                                  title: 'Use Mode Switch for High Accuracy',
                                  description: 'Tap "Mode" (top pill) to switch to "A–Z" for precise spelling (names, places) or "Phrases" for conversational signs.',
                                ),
                                _GuideTipCard(
                                  icon: Icons.speed_rounded,
                                  title: 'Deliberate Pacing',
                                  description: 'Hold each static letter for about 1 second to confirm detection before transitioning to the next letter.',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GuideTipCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _GuideTipCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162138) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF233352) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _kAppBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: _kAppBlue, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: isDark ? Colors.white70 : const Color(0xFF475569),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
                  ),
                  child: Center(
                    child: Icon(icon, color: color, size: 26),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _GuideItem extends StatelessWidget {
  final String sign;
  final String description;

  const _GuideItem(this.sign, this.description);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162138) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF233352) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _kAppBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              sign,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: _kAppBlue,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
