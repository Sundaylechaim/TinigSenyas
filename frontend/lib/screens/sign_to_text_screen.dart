import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import '../providers/recognition_provider.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/database_helper.dart';
import '../models/sign_result.dart';
import '../widgets/camera_preview.dart';
import '../widgets/prediction_overlay.dart';
import '../widgets/signing_space_overlay.dart';
import '../widgets/connectivity_badge.dart';
import '../services/word_prediction_service.dart';

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
  RecognitionProvider? _recognitionProvider;
  StreamSubscription<SignResult>? _predictionSubscription;
  StreamSubscription<CameraImage>? _frameSubscription;

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

    if (kIsWeb) {
      _useBackendFeed = true;
      _isCheckingPermission = false;
      _hasPermission = true;
      _isCameraInitialized = true;
      _isModelReady = true;
      _recognitionProvider?.initialize().then((_) {
        _recognitionProvider?.start();
        if (mounted) setState(() => _isModelReady = true);
      });
    } else {
      _useBackendFeed = false;
      _checkPermissionAndStart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (!_hasPermission) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _cameraService.dispose();
      if (mounted) {
        setState(() => _isCameraInitialized = false);
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!_useBackendFeed) {
        _initializeCamera();
      }
    }
  }

  Future<void> _checkPermissionAndStart() async {
    setState(() => _isCheckingPermission = true);
    final hasPerm = await _cameraService.hasCameraPermission();
    final isPermDenied = await _cameraService.isPermissionPermanentlyDenied();

    if (mounted) {
      setState(() {
        _hasPermission = hasPerm;
        _isPermanentlyDenied = isPermDenied;
        _isCheckingPermission = false;
      });
    }

    if (hasPerm) {
      await _initializeCamera();
    }
  }

  Future<void> _requestPermissionAndStart() async {
    setState(() => _cameraError = null);
    final granted = await _cameraService.requestCameraPermission();
    final isPermDenied = await _cameraService.isPermissionPermanentlyDenied();

    if (mounted) {
      setState(() {
        _hasPermission = granted;
        _isPermanentlyDenied = isPermDenied;
      });
    }

    if (granted) {
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
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
    _recognitionProvider!
        .processFrame(image)
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

  Future<void> _speakCurrentPrediction() async {
    if (_currentPrediction != null) {
      try {
        await _ttsService.speak(_currentPrediction!.label);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not play speech: $error')),
          );
        }
      }
    }
  }

  Future<void> _saveCurrentPrediction() async {
    if (_currentPrediction != null) {
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
    setState(() {
      _activeWordBuffer = '';
      _composedSentence = '';
      _suggestedWords = [];
      _lastAppendedLetter = null;
    });
  }

  void _speakComposedSentence() async {
    final textToSpeak = _composedSentence.isNotEmpty
        ? (_activeWordBuffer.isNotEmpty ? '$_composedSentence $_activeWordBuffer' : _composedSentence)
        : _activeWordBuffer;

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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _predictionSubscription?.cancel();
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
          IconButton(
            icon: Icon(_useBackendFeed ? Icons.sensors_rounded : Icons.videocam_rounded),
            tooltip: _useBackendFeed ? 'Switch to Browser Direct Camera' : 'Switch to Backend AI Video Stream',
            onPressed: () {
              setState(() {
                _useBackendFeed = !_useBackendFeed;
                if (!_useBackendFeed && !_isCameraInitialized) {
                  _checkPermissionAndStart();
                }
              });
            },
          ),
          if (!_useBackendFeed && _isCameraInitialized && _cameraService.canSwitchCamera)
            IconButton(
              icon: const Icon(Icons.cameraswitch_rounded),
              tooltip: 'Switch Camera',
              onPressed: _showCameraPicker,
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

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
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
                    'TinigSenyas needs your camera permission to recognize hand gestures from left to right and translate Filipino Sign Language (FSL) in real-time.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  _buildFeatureBullet(
                    Icons.pan_tool_rounded,
                    'Recognizes both hands across horizontal signing space',
                  ),
                  const SizedBox(height: 10),
                  _buildFeatureBullet(
                    Icons.cameraswitch_rounded,
                    'Compatible with all cameras: Front, Back & USB Webcams',
                  ),
                  const SizedBox(height: 10),
                  _buildFeatureBullet(
                    Icons.lock_outline_rounded,
                    'Private: Frames are processed locally on your device',
                  ),
                  const SizedBox(height: 28),
                  if (_isPermanentlyDenied) ...[
                    Text(
                      'Camera permission is permanently denied in system settings.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () async => await _cameraService.openSettings(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAppBlue,
                        foregroundColor: Colors.white,
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
                      onPressed: _checkPermissionAndStart,
                      child: const Text('I have allowed permission (Check again)'),
                    ),
                  ] else ...[
                    ElevatedButton.icon(
                      onPressed: _requestPermissionAndStart,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kAppBlue,
                        foregroundColor: Colors.white,
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

    return Center(
      child: SingleChildScrollView(
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
                        ? 'Camera Locked or In Use'
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
                        ? 'Your webcam is currently locked by another application or browser tab. Windows only allows one app to access the camera at a time.'
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
                            'Quick Troubleshooting Steps:',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          _buildTroubleshootItem('1. Close other apps using your webcam (Zoom, Teams, Discord, OBS, or Camera app).'),
                          _buildTroubleshootItem('2. Check if another browser tab or window has camera access enabled.'),
                          _buildTroubleshootItem('3. If you ran a Python test script (validate_hand_tracking.py), press Q or close its terminal.'),
                          _buildTroubleshootItem('4. In Windows Settings > Privacy & security > Camera, ensure Chrome has camera access allowed.'),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (isPermIssue) ...[
                    ElevatedButton.icon(
                      onPressed: () async => await _cameraService.openSettings(),
                      icon: const Icon(Icons.settings_rounded),
                      label: const Text('Open System Settings'),
                    ),
                    const SizedBox(height: 10),
                  ],
                  ElevatedButton.icon(
                    onPressed: _initializeCamera,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAppBlue,
                      foregroundColor: Colors.white,
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
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackendFeedView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (kIsWeb)
          HtmlElementView.fromTagName(
            tagName: 'img',
            onElementCreated: (Object element) {
              final img = element as dynamic;
              img.src = 'http://127.0.0.1:5000/video_feed';
              img.style.width = '100%';
              img.style.height = '100%';
              img.style.objectFit = 'cover';
              img.style.pointerEvents = 'none';
            },
          )
        else
          Image.network(
            'http://127.0.0.1:5000/video_feed',
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
          top: 100,
          left: 16,
          right: 16,
          child: _buildRecognitionStatus(),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFingerspellingWordAssembler(),
              _buildActionCard(),
            ],
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
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreviewWidget(
          cameraService: _cameraService,
          overlay: PredictionOverlay(prediction: _currentPrediction, top: 72),
        ),
        const SigningSpaceOverlay(),
        Positioned(
          top: 100,
          left: 16,
          right: 16,
          child: _buildRecognitionStatus(),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFingerspellingWordAssembler(),
              _buildActionCard(),
            ],
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
    final hasPrediction = _currentPrediction != null;
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
              color: isDark
                  ? Colors.white.withValues(alpha: 0.20)
                  : Colors.white,
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
                      color: hasPrediction
                          ? (isConfidenceHigh
                              ? const Color(0xFF10B981).withValues(alpha: 0.18)
                              : _kAppBlue.withValues(alpha: 0.15))
                          : Colors.grey.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasPrediction
                          ? (isConfidenceHigh ? Icons.verified_rounded : Icons.check_circle_rounded)
                          : Icons.radar_rounded,
                      color: hasPrediction
                          ? (isConfidenceHigh ? const Color(0xFF10B981) : _kAppBlue)
                          : Colors.grey,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      label: hasPrediction
                          ? 'Recognized Filipino sign: ${_currentPrediction!.label}, confidence ${(confidence * 100).toInt()} percent'
                          : isReady
                              ? 'Camera ready. Position hand gestures in frame to sign.'
                              : 'Initializing sign recognition model.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            hasPrediction
                                ? _currentPrediction!.label
                                : isReady
                                    ? 'Position hands to sign...'
                                    : 'Initializing FSL model...',
                            style: TextStyle(
                              fontSize: hasPrediction ? 22 : 15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: hasPrediction ? 0.4 : 0.0,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                          if (hasPrediction)
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
                  if (hasPrediction && isReady)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isConfidenceHigh
                            ? const Color(0xFF10B981)
                            : (confidence >= 0.60 ? _kAppBlue : _kAppYellow),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: (isConfidenceHigh ? const Color(0xFF10B981) : _kAppYellow).withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isConfidenceHigh ? Icons.verified_rounded : Icons.trending_up_rounded,
                            size: 14,
                            color: (isConfidenceHigh || confidence >= 0.60) ? Colors.white : const Color(0xFF111827),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${(confidence * 100).toInt()}%',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                              color: (isConfidenceHigh || confidence >= 0.60) ? Colors.white : const Color(0xFF111827),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (hasPrediction && isReady) ...[
                    _ActionButton(
                      icon: Icons.volume_up_rounded,
                      label: 'Speak',
                      tooltip: 'Pronounce sign in Filipino voice',
                      semanticLabel: 'Speak recognized sign aloud',
                      onPressed: _speakCurrentPrediction,
                      color: _kAppBlue,
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
                      icon: Icons.replay_rounded,
                      label: 'Repeat',
                      tooltip: 'Replay voice translation',
                      semanticLabel: 'Repeat spoken sign',
                      onPressed: _speakCurrentPrediction,
                      color: isDark ? Colors.white70 : const Color(0xFF475569),
                    ),
                  ] else if (!isReady) ...[
                    Expanded(
                      child: Text(
                        'Initializing sign recognition model...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ] else ...[
                    _ActionButton(
                      icon: Icons.menu_book_rounded,
                      label: 'FSL Guide',
                      tooltip: 'Open Filipino Sign Language gesture guide',
                      semanticLabel: 'Open FSL gesture guide',
                      onPressed: _showGuide,
                      color: _kAppBlue,
                    ),
                  ],
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
    final message =
        _recognitionError ??
        (isReady
            ? 'FSL sign recognition is active'
            : 'Initializing FSL sign model...');

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _recognitionError == null
                ? (isDark ? const Color(0xFF0C1220).withValues(alpha: 0.75) : Colors.white.withValues(alpha: 0.85))
                : Colors.redAccent.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white12 : Colors.white60,
            ),
          ),
          child: Row(
            children: [
              Icon(
                _recognitionError == null
                    ? Icons.videocam_rounded
                    : Icons.error_outline_rounded,
                color: _recognitionError == null ? _kAppBlue : Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: _recognitionError == null
                        ? (isDark ? Colors.white : const Color(0xFF0F172A))
                        : Colors.white,
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
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (context, scrollController) => ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0E1626).withValues(alpha: 0.95)
                      : Colors.white.withValues(alpha: 0.95),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
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
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Text(
                          'FSL Signing Guide',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
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
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        physics: const BouncingScrollPhysics(),
                        children: const [
                          _GuideItem('HELLO', 'Wave hand near face with a friendly smile'),
                          _GuideItem('THANK YOU', 'Touch chin with fingers, move hand forward'),
                          _GuideItem('YES', 'Closed fist nodding up and down'),
                          _GuideItem('NO', 'Index and middle finger snap to thumb'),
                          _GuideItem('PLEASE', 'Open flat palm rubbed circular on chest'),
                          _GuideItem('SORRY', 'Closed fist rubbed circular on chest'),
                          _GuideItem('GOOD', 'Thumb up gesture moving outward from chin'),
                          _GuideItem('BAD', 'Thumb down gesture moving outward from chin'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
