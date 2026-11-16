import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const Color _kSignBlue = Color(0xFF2D5FB8);
const String _kAnimationBaseUrl =
    'https://raw.githubusercontent.com/Sundaylechaim/TinigSenyas/fsl-animations/frontend/assets/sign_animations';

class _SignSegment {
  const _SignSegment({required this.label, required this.isSupported});

  final String label;
  final bool isSupported;

  String get animationUrl => '$_kAnimationBaseUrl/${_slug(label)}.gif';
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9ñ]+'), ' ').trim();

String _slug(String label) => _normalize(label).replaceAll(RegExp(r'\s+'), '_');

class TextToSignScreen extends StatefulWidget {
  const TextToSignScreen({super.key, this.initialText = ''});

  final String initialText;

  @override
  State<TextToSignScreen> createState() => _TextToSignScreenState();
}

class _TextToSignScreenState extends State<TextToSignScreen> {
  final TextEditingController _textController = TextEditingController();
  List<String> _labels = const [];
  List<_SignSegment> _segments = const [];
  int _currentIndex = 0;
  bool _isLoadingLabels = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _textController.text = widget.initialText;
    _loadLabels();
  }

  Future<void> _loadLabels() async {
    try {
      String? rawLabels;
      if (!kIsWeb) {
        try {
          final appDir = await getApplicationDocumentsDirectory();
          final otaLabelsFile = File(p.join(appDir.path, 'models', 'labels.txt'));
          if (await otaLabelsFile.exists()) {
            rawLabels = await otaLabelsFile.readAsString();
          }
        } catch (_) {
          // Ignore unavailable path_provider (e.g. widget tests) and use bundled asset.
        }
      }
      rawLabels ??= await rootBundle.loadString('assets/model/labels.txt');
      final labels = rawLabels
          .split(RegExp(r'\r?\n'))
          .map((label) => label.trim())
          .where((label) => label.isNotEmpty)
          .toList();
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingLabels = false;
        _message = 'The FSL vocabulary could not be loaded.';
      });
    }
  }

  List<_SignSegment> _resolveText(String text, [List<String>? labels]) {
    final activeLabels = labels ?? _labels;
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
        result.add(_SignSegment(label: match, isSupported: true));
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
      appBar: AppBar(title: const Text('Text to FSL Signs')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Type a Filipino word or phrase',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The app shows recorded FSL signs for words in its vocabulary. Unmatched words are marked as unavailable.',
              style: theme.textTheme.bodyMedium?.copyWith(color: mutedColor),
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
              onPressed: _isLoadingLabels ? null : _preparePreview,
              icon: _isLoadingLabels
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sign_language_rounded),
              label: Text(
                _isLoadingLabels ? 'Loading FSL signs…' : 'Preview signs',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kSignBlue,
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
                    '$supportedCount/${_segments.length} supported',
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
          child: Image.network(
            sign.animationUrl,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator());
            },
            errorBuilder: (context, error, stackTrace) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded, size: 40, color: mutedColor),
                  const SizedBox(height: 8),
                  Text(
                    'Sign animation is unavailable. Connect to the internet and try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: mutedColor),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Recorded sign reference · internet required',
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
