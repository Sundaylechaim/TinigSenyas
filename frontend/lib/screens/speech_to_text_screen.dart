import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../services/tts_service.dart';
import '../services/database_helper.dart';
import '../services/offline_filipino_asr_service.dart';
import '../widgets/connectivity_badge.dart';
import '../services/settings_service.dart';
import 'text_to_sign_screen.dart';

const Color _kAppBlue = Color(0xFF2D5FB8);
const Color _kAppYellow = Color(0xFFF4C95D);

class SpeechToTextScreen extends StatefulWidget {
  const SpeechToTextScreen({super.key});

  @override
  State<SpeechToTextScreen> createState() => _SpeechToTextScreenState();
}

class _SpeechToTextScreenState extends State<SpeechToTextScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final OfflineFilipinoAsrService _offlineAsr = OfflineFilipinoAsrService();
  StreamSubscription<Uint8List>? _recordingSubscription;
  final BytesBuilder _recordingBuffer = BytesBuilder(copy: false);
  Timer? _recordingLimitTimer;
  bool _isListening = false;
  String _currentWords = '';
  final List<String> _messages = [];
  bool _speechAvailable = false;
  String? _speechError;
  bool _isStarting = false;
  bool _isStopping = false;
  bool _isInitializingSpeech = false;
  bool _offlineModelInstalled = false;
  int _modelDownloadProgress = 0;
  static const _maxRecordingDuration = Duration(seconds: 25);

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    if (_isInitializingSpeech) return;
    if (mounted) setState(() => _isInitializingSpeech = true);
    try {
      final installed = !kIsWeb && await _offlineAsr.isInstalled();
      if (!mounted) return;
      setState(() {
        _offlineModelInstalled = installed;
        _speechAvailable = !kIsWeb;
        _speechError = kIsWeb
            ? 'Offline Filipino transcription is available in the mobile app.'
            : null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _speechAvailable = !kIsWeb;
          _speechError =
              'Could not check the offline Filipino speech model: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _isInitializingSpeech = false);
    }
  }

  Future<void> _toggleListen() async {
    if (!_isListening) {
      if (_isStarting || _isStopping) return;

      // CIPA Check: Affirmative two-party consent to record audio communications
      final settings = context.read<SettingsService>();
      if (!settings.hasRecordingConsent) {
        final consentGiven = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.mic, color: _kAppBlue, size: 40),
            title: const Text('Microphone Consent'),
            content: const Text(
              'TinigSenyas records up to 25 seconds and transcribes it with an on-device Filipino speech model. '
              'The model downloads once (about 111 MB) while online. Recorded audio is processed on this phone '
              'and is not uploaded for transcription.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('I Consent'),
              ),
            ],
          ),
        );

        if (consentGiven != true) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Audio recording consent is required.'),
              ),
            );
          }
          return;
        }
        await settings.setRecordingConsent(true);
      }
      if (!_speechAvailable || kIsWeb) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _speechError ?? 'Speech recognition unavailable on this device',
              ),
            ),
          );
        }
        return;
      }

      setState(() {
        _isStarting = true;
        _currentWords = _offlineModelInstalled
            ? 'Preparing offline speech model...'
            : 'Downloading offline speech model...';
        _speechError = null;
      });
      try {
        if (!_offlineModelInstalled) {
          await _offlineAsr.install(
            onProgress: (received, total) {
              if (mounted && total > 0) {
                setState(
                  () => _modelDownloadProgress = (received * 100 ~/ total)
                      .clamp(0, 100),
                );
              }
            },
          );
          _offlineModelInstalled = true;
          _modelDownloadProgress = 100;
        }
        await _offlineAsr.initialize();
        if (!await _recorder.hasPermission()) {
          throw StateError(
            'Microphone permission is required to transcribe speech.',
          );
        }
        _recordingBuffer.clear();
        final audioStream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            echoCancel: true,
            noiseSuppress: true,
          ),
        );
        _recordingSubscription = audioStream.listen(
          _recordingBuffer.add,
          onError: (Object error) {
            if (mounted) {
              setState(
                () => _speechError = 'Microphone capture failed: $error',
              );
            }
            unawaited(_stopListening());
          },
        );
        _recordingLimitTimer = Timer(_maxRecordingDuration, _stopListening);
        setState(() {
          _isListening = true;
          _currentWords = 'Listening offline… (up to 25 seconds)';
        });
      } catch (error) {
        if (mounted) {
          setState(() {
            _speechError =
                'Could not start offline Filipino transcription: $error';
            _currentWords = '';
          });
        }
      } finally {
        if (mounted) setState(() => _isStarting = false);
      }
    } else {
      await _stopListening();
    }
  }

  Future<void> _stopListening() async {
    if (_isStopping) return;
    _recordingLimitTimer?.cancel();
    if (mounted) {
      setState(() {
        _isStopping = true;
        _isListening = false;
        _currentWords = 'Transcribing on this phone...';
      });
    }
    try {
      await _recorder.stop();
      await _recordingSubscription?.cancel();
      _recordingSubscription = null;
      final audio = _recordingBuffer.takeBytes();
      final transcript = await _offlineAsr.transcribe(audio);
      if (!mounted) return;
      setState(() {
        if (transcript.isNotEmpty) {
          _messages.add(transcript);
        } else {
          _speechError =
              'No speech was detected. Please speak clearly and try again.';
        }
        _currentWords = '';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _speechError = 'Could not transcribe the recording offline: $error';
          _currentWords = '';
        });
      }
    } finally {
      if (mounted) setState(() => _isStopping = false);
    }
  }

  Future<void> _speakMessage(String message) async {
    try {
      await context.read<TtsService>().speak(message);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play speech: $error')),
        );
      }
    }
  }

  Future<void> _saveMessage(String message) async {
    final settings = context.read<SettingsService>();
    if (!settings.saveHistoryEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Private Mode active: conversation history is not saved.',
            ),
            duration: Duration(milliseconds: 1200),
          ),
        );
      }
      return;
    }
    try {
      await DatabaseHelper.instance.saveRecognizedGesture(
        message,
        0,
        source: 'speech',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to History!'),
            duration: Duration(milliseconds: 800),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save message: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    _recordingLimitTimer?.cancel();
    unawaited(_recordingSubscription?.cancel());
    unawaited(_recorder.stop().catchError((_) => null));
    unawaited(_recorder.dispose());
    _offlineAsr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF090E1A) : const Color(0xFFF1F5F9);

    return Scaffold(
      backgroundColor: bgColor,
      extendBodyBehindAppBar: true,

      // CONSISTENT FROSTED GLASS APP BAR
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
                'Speech to Text',
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
        actions: const [ConnectivityBadge(), SizedBox(width: 10)],
      ),

      // CONSISTENT AMBIENT BACKGROUND LAYER
      body: Stack(
        children: [
          // Top-Right Ambient Orb (Sun Yellow for speech)
          Positioned(
            top: -50,
            right: -60,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _kAppYellow.withValues(alpha: isDark ? 0.12 : 0.07),
                      _kAppYellow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Bottom-Left Ambient Orb (Blue)
          Positioned(
            bottom: -50,
            left: -60,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _kAppBlue.withValues(alpha: isDark ? 0.14 : 0.07),
                      _kAppBlue.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Main Screen Body
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              child: Column(
                children: [
                  if (_speechError != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _speechError!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          if (!_speechAvailable)
                            TextButton(
                              onPressed: _isInitializingSpeech
                                  ? null
                                  : _initSpeech,
                              child: const Text('Retry'),
                            ),
                        ],
                      ),
                    ),

                  // Frosted Glass Chat Transcript Box
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.white.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.14)
                                  : Colors.white.withValues(alpha: 0.8),
                              width: 1.5,
                            ),
                          ),
                          child: _messages.isEmpty && _currentWords.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 58,
                                        height: 58,
                                        decoration: BoxDecoration(
                                          color: _kAppYellow.withValues(
                                            alpha: 0.2,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.mic_rounded,
                                          color: Color(0xFFB45309),
                                          size: 28,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      Text(
                                        'No speech recorded yet',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Tap the yellow button and speak in Filipino.\nThe transcript appears when you stop.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: isDark
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFF64748B),
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView(
                                  physics: const BouncingScrollPhysics(),
                                  children: [
                                    ..._messages.map(
                                      (msg) => _buildMessageBubble(
                                        msg,
                                        isFinal: true,
                                        isDark: isDark,
                                      ),
                                    ),
                                    if ((_isListening ||
                                            _isStopping ||
                                            _isStarting) &&
                                        _currentWords.isNotEmpty)
                                      _buildMessageBubble(
                                        _currentWords,
                                        isFinal: false,
                                        isDark: isDark,
                                      ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      kIsWeb
                          ? 'Offline Filipino transcription is available in the mobile app.'
                          : _offlineModelInstalled
                          ? 'Offline Filipino model ready · audio stays on this phone'
                          : _modelDownloadProgress > 0
                          ? 'Downloading offline speech model · $_modelDownloadProgress%'
                          : 'First use downloads the offline Filipino model (~111 MB)',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Large Mobile Floating Action Button (Complementary Yellow)
                  SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed:
                          _speechAvailable && !_isStarting && !_isStopping
                          ? _toggleListen
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isListening
                            ? Colors.redAccent
                            : _kAppYellow,
                        foregroundColor: _isListening
                            ? Colors.white
                            : const Color(0xFF111827),
                        elevation: 4,
                        shadowColor:
                            (_isListening ? Colors.redAccent : _kAppYellow)
                                .withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                      ),
                      icon: Icon(
                        _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                        size: 22,
                      ),
                      label: Text(
                        _isStarting
                            ? 'Starting...'
                            : _isStopping
                            ? 'Finishing...'
                            : _isListening
                            ? 'Stop Listening'
                            : 'Tap to Speak',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(
    String message, {
    required bool isFinal,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isFinal
                    ? _kAppBlue
                    : _kAppYellow.withValues(alpha: isDark ? 0.35 : 0.45),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: isFinal
                        ? _kAppBlue.withValues(alpha: 0.25)
                        : _kAppYellow.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: isFinal
                            ? Colors.white
                            : (isDark ? Colors.white : const Color(0xFF111827)),
                        fontSize: 16,
                        fontWeight: isFinal ? FontWeight.w700 : FontWeight.w600,
                        fontStyle: isFinal
                            ? FontStyle.normal
                            : FontStyle.italic,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (isFinal) ...[
                    IconButton(
                      icon: const Icon(
                        Icons.volume_up_rounded,
                        size: 18,
                        color: _kAppYellow,
                      ),
                      onPressed: () => _speakMessage(message),
                      tooltip: 'Speak',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.sign_language_rounded,
                        size: 18,
                        color: _kAppYellow,
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                TextToSignScreen(initialText: message),
                          ),
                        );
                      },
                      tooltip: 'Show available FSL signs',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.bookmark_add_rounded,
                        size: 18,
                        color: _kAppYellow,
                      ),
                      onPressed: () => _saveMessage(message),
                      tooltip: 'Save to History',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
