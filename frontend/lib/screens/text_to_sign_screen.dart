import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/sign_animation_catalog.dart';
import '../services/tts_service.dart';
import 'settings_screen.dart';

const Color _kSignBlue = Color(0xFF2D5FB8);

class _SignSegment {
  const _SignSegment({
    required this.label,
    required this.isSupported,
    this.hasAnimation = false,
  });

  final String label;
  final bool isSupported;
  final bool hasAnimation;

  String get animationAsset =>
      'assets/sign_animations/${SignAnimationCatalog.slug(label)}.gif';
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9ñ]+'), ' ').trim();

class TextToSignScreen extends StatefulWidget {
  const TextToSignScreen({super.key, this.initialText = ''});

  final String initialText;

  @override
  State<TextToSignScreen> createState() => _TextToSignScreenState();
}

class _TextToSignScreenState extends State<TextToSignScreen> {
  final TextEditingController _textController = TextEditingController();
  List<String> _labels = const [];
  Set<String> _animationSlugs = const {};
  List<_SignSegment> _segments = const [];
  int _currentIndex = 0;
  bool _isLoadingLabels = true;
  bool _isSpeaking = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _textController.text = widget.initialText;
    _loadLabels();
  }

  Future<void> _loadLabels() async {
    try {
      // Both ST-GCN label maps are part of the vocabulary. Loading only the
      // conversational map made medical signs appear unavailable here.
      final labels = await _loadBundledModelLabels();
      if (!mounted) return;
      final initialText = widget.initialText.trim();
      final initialSegments = initialText.isEmpty
          ? const <_SignSegment>[]
          : _resolveText(initialText, labels);
      setState(() {
        _labels = labels;
        _isLoadingLabels = false;
        if (initialSegments.isNotEmpty) {
          _segments = initialSegments;
          _currentIndex = initialSegments.indexWhere(
            (segment) => segment.isSupported,
          );
          _message = null;
        }
      });
      unawaited(_loadAnimationCatalog());
      if (!kIsWeb) unawaited(_refreshOtaLabels());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingLabels = false;
        _message = 'The FSL vocabulary could not be loaded.';
      });
    }
  }

  Future<void> _loadAnimationCatalog() async {
    try {
      final animationSlugs = await SignAnimationCatalog.load();
      if (!mounted) return;
      setState(() {
        _animationSlugs = animationSlugs;
        final text = _textController.text.trim();
        if (text.isNotEmpty) {
          _segments = _resolveText(text, _labels, animationSlugs);
        }
      });
    } catch (_) {
      // Vocabulary lookup remains usable if the optional animation index fails.
    }
  }

  List<String> _parseLabels(String rawLabels) => rawLabels
      .split(RegExp(r'\r?\n'))
      .map((label) => label.trim())
      .where((label) => label.isNotEmpty)
      .toList();

  Future<List<String>> _loadBundledModelLabels() async {
    final maps = await Future.wait([
      rootBundle.loadString('assets/model/labels.txt'),
      rootBundle.loadString('assets/model/medical_labels.txt'),
    ]);
    return _mergeLabels(maps.map(_parseLabels));
  }

  List<String> _mergeLabels(Iterable<List<String>> maps) {
    final seen = <String>{};
    final merged = <String>[];
    for (final map in maps) {
      for (final label in map) {
        if (seen.add(_normalize(label))) merged.add(label);
      }
    }
    return merged;
  }

  Future<void> _refreshOtaLabels() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(p.join(appDir.path, 'models'));
      final files = [
        File(p.join(modelsDir.path, 'labels.txt')),
        File(p.join(modelsDir.path, 'medical_labels.txt')),
      ];
      final rawMaps = <String>[];
      for (final file in files) {
        if (await file.exists()) rawMaps.add(await file.readAsString());
      }
      if (rawMaps.isEmpty) return;
      final labels = _mergeLabels(rawMaps.map(_parseLabels));
      if (!mounted || labels.isEmpty) return;

      setState(() {
        _labels = labels;
        final text = _textController.text.trim();
        if (text.isNotEmpty) {
          _segments = _resolveText(text);
          _currentIndex = _segments.indexWhere(
            (segment) => segment.isSupported,
          );
        }
      });
    } catch (_) {
      // The bundled vocabulary stays available when app storage cannot be read.
    }
  }

  List<_SignSegment> _resolveText(
    String text, [
    List<String>? labels,
    Set<String>? animationSlugs,
  ]) {
    final activeLabels = labels ?? _labels;
    final activeAnimations = animationSlugs ?? _animationSlugs;
    final tokens = _normalize(text).split(RegExp(r'\s+'))
      ..removeWhere((token) => token.isEmpty);
    final labelTokens = <String, List<String>>{
      for (final label in activeLabels) label: _normalize(label).split(' '),
    };
    final longestFirst = activeLabels.toList()
      ..sort(
        (a, b) => labelTokens[b]!.length.compareTo(labelTokens[a]!.length),
      );

    final result = <_SignSegment>[];
    var index = 0;
    while (index < tokens.length) {
      String? match;
      for (final label in longestFirst) {
        final parts = labelTokens[label]!;
        if (index + parts.length > tokens.length) continue;
        var matches = true;
        for (var offset = 0; offset < parts.length; offset++) {
          if (tokens[index + offset] != parts[offset]) {
            matches = false;
            break;
          }
        }
        if (matches) {
          match = label;
          break;
        }
      }

      if (match == null) {
        result.add(_SignSegment(label: tokens[index], isSupported: false));
        index++;
      } else {
        result.add(
          _SignSegment(
            label: match,
            isSupported: true,
            hasAnimation: activeAnimations.contains(
              SignAnimationCatalog.slug(match),
            ),
          ),
        );
        index += labelTokens[match]!.length;
      }
    }
    return result;
  }

  void _preparePreview() {
    FocusScope.of(context).unfocus();
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _segments = const [];
        _message = 'Type a word or phrase to preview its available signs.';
      });
      return;
    }

    final segments = _resolveText(text);
    setState(() {
      _segments = segments;
      _currentIndex = segments.indexWhere((segment) => segment.isSupported);
      _message = null;
    });
  }

  void _useQuickMessage(String message) {
    _textController.value = TextEditingValue(
      text: message,
      selection: TextSelection.collapsed(offset: message.length),
    );
    setState(() {
      _segments = const [];
      _currentIndex = 0;
      _message = null;
    });
  }

  Future<void> _speakTypedMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a message before speaking.')),
      );
      return;
    }

    setState(() => _isSpeaking = true);
    try {
      await context.read<TtsService>().speak(text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not speak this message: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  void _selectSign(int index) {
    if (index < 0 ||
        index >= _segments.length ||
        !_segments[index].isSupported) {
      return;
    }
    setState(() => _currentIndex = index);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mutedColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final currentSign = _currentIndex >= 0 && _currentIndex < _segments.length
        ? _segments[_currentIndex]
        : null;
    final supportedCount = _segments
        .where((segment) => segment.isSupported)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Type & Speak · FSL Signs'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Type a message to speak it aloud or preview available FSL signs',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Use this when camera recognition is difficult. Sign previews are available for words in the FSL vocabulary; other typed words can still be spoken aloud.',
              style: theme.textTheme.bodyMedium?.copyWith(color: mutedColor),
            ),
            const SizedBox(height: 16),
            Text(
              'Quick messages',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('Kailangan ko ng tulong'),
                  onPressed: () => _useQuickMessage('Kailangan ko ng tulong.'),
                ),
                ActionChip(
                  label: const Text('Pakisulat ang sagot'),
                  onPressed: () => _useQuickMessage('Pakisulat ang sagot.'),
                ),
                ActionChip(
                  label: const Text('Salamat po'),
                  onPressed: () => _useQuickMessage('Salamat po.'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Example: Kamusta ka',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                suffixIcon: IconButton(
                  tooltip: 'Clear text',
                  onPressed: () {
                    _textController.clear();
                    setState(() {
                      _segments = const [];
                      _message = null;
                    });
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              onSubmitted: (_) => _preparePreview(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isSpeaking ? null : _speakTypedMessage,
              icon: _isSpeaking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volume_up_rounded),
              label: Text(_isSpeaking ? 'Speaking…' : 'Speak message'),
              style: FilledButton.styleFrom(
                backgroundColor: _kSignBlue,
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _isLoadingLabels ? null : _preparePreview,
              icon: _isLoadingLabels
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sign_language_rounded),
              label: Text(
                _isLoadingLabels
                    ? 'Loading FSL signs…'
                    : 'Preview available FSL signs',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kSignBlue,
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 14),
              Text(_message!, style: TextStyle(color: mutedColor)),
            ],
            if (_segments.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sign sequence',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '$supportedCount/${_segments.length} in vocabulary',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: mutedColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var index = 0; index < _segments.length; index++)
                    ActionChip(
                      avatar: Icon(
                        _segments[index].isSupported
                            ? Icons.check_circle_rounded
                            : Icons.help_outline_rounded,
                        size: 18,
                        color: _segments[index].isSupported
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                      ),
                      label: Text(_segments[index].label),
                      onPressed: _segments[index].isSupported
                          ? () => _selectSign(index)
                          : null,
                      backgroundColor: index == _currentIndex
                          ? _kSignBlue.withValues(alpha: 0.12)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (currentSign != null)
                _buildAnimation(currentSign, isDark, mutedColor),
              if (supportedCount == 0)
                _notice(
                  'No matching signs were found for this text.',
                  isDark,
                  mutedColor,
                ),
              if (supportedCount < _segments.length) ...[
                const SizedBox(height: 10),
                _notice(
                  'Unavailable words are not translated in the animation.',
                  isDark,
                  mutedColor,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAnimation(_SignSegment sign, bool isDark, Color mutedColor) {
    final previousIndex = _previousSupportedIndex();
    final nextIndex = _nextSupportedIndex();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          sign.label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Container(
          height: 260,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111827) : const Color(0xFFE2E8F0),
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: sign.hasAnimation
              ? Image.asset(
                  sign.animationAsset,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      _fslClipUnavailable(sign.label, isDark, mutedColor),
                )
              : _fslClipUnavailable(sign.label, isDark, mutedColor),
        ),
        const SizedBox(height: 8),
        Text(
          sign.hasAnimation
              ? 'FSL sign reference · available offline'
              : 'This word is recognized, but its reviewed FSL video is not in the library yet.',
          textAlign: TextAlign.center,
          style: TextStyle(color: mutedColor, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            OutlinedButton.icon(
              onPressed: previousIndex < 0
                  ? null
                  : () => _selectSign(previousIndex),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              label: const Text('Previous'),
            ),
            Text(
              '${_supportedPosition()}/${_segments.where((item) => item.isSupported).length}',
              style: TextStyle(color: mutedColor),
            ),
            OutlinedButton.icon(
              onPressed: nextIndex < 0 ? null : () => _selectSign(nextIndex),
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.chevron_right_rounded),
              label: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _fslClipUnavailable(String word, bool isDark, Color mutedColor) {
    final foreground = isDark ? Colors.white : const Color(0xFF172033);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sign_language_rounded, size: 42, color: mutedColor),
          const SizedBox(height: 14),
          Text(
            'No FSL video for “$word” yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: foreground,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We only show a sign demonstration when a reviewed FSL clip is available.',
            textAlign: TextAlign.center,
            style: TextStyle(color: mutedColor, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }

  int _previousSupportedIndex() {
    for (var i = _currentIndex - 1; i >= 0; i--) {
      if (_segments[i].isSupported) return i;
    }
    return -1;
  }

  int _nextSupportedIndex() {
    for (var i = _currentIndex + 1; i < _segments.length; i++) {
      if (_segments[i].isSupported) return i;
    }
    return -1;
  }

  int _supportedPosition() => _segments
      .take(_currentIndex + 1)
      .where((segment) => segment.isSupported)
      .length;

  Widget _notice(String text, bool isDark, Color mutedColor) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isDark ? const Color(0xFF1F2937) : const Color(0xFFF1F5F9),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: TextStyle(color: mutedColor)),
  );
}
