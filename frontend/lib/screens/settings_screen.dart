import 'dart:ui';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../providers/theme_provider.dart';
import '../services/settings_service.dart';
import '../services/database_helper.dart';
import '../services/tts_service.dart';
import '../widgets/connectivity_badge.dart';
import 'landing_page_screen.dart';
import '../services/model_updater.dart';
import '../widgets/model_update_dialog.dart';


const Color _kAppBlue = Color(0xFF0138FF);
const Color _kAppYellow = Color(0xFFFFC801);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsService _settingsService;
  double _textScale = 1.0;
  double _ttsRate = 0.5;
  String _ttsLanguage = 'fil-PH';
  String _ttsSource = 'automatic';
  String _ttsOnlineVoice = 'fil-PH-BlessicaNeural';
  String _ttsOfflineEnglishVoice = 'af_maple';
  String _ttsServerUrl = '';
  String _modelVersion = 'Not installed';
  List<Map<String, String>> _ttsVoices = [];
  Map<String, String>? _selectedTtsVoice;
  bool _isLoadingVoices = true;
  bool _offlineEnglishVoiceInstalled = false;
  bool _isInstallingOfflineEnglishVoice = false;
  double? _offlineVoiceDownloadProgress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
    });
    _settingsService = context.read<SettingsService>();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _textScale = _settingsService.textScaleFactor;
    _ttsRate = _settingsService.ttsRate;
    _ttsLanguage = _settingsService.ttsLanguage;
    _ttsSource = _settingsService.ttsSource;
    _ttsOnlineVoice = _settingsService.ttsOnlineVoice;
    _ttsOfflineEnglishVoice = _settingsService.ttsOfflineEnglishVoice;
    _ttsServerUrl = _settingsService.ttsServerUrl;
    _modelVersion = _settingsService.modelVersion;

    try {
      final ttsService = context.read<TtsService>();
      _ttsVoices = await ttsService.getAvailableVoices();
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        _offlineEnglishVoiceInstalled = await ttsService
            .isOfflineEnglishVoiceInstalled();
      }
      _selectedTtsVoice = _settingsService.ttsVoice;
      if (_selectedTtsVoice != null &&
          (!_ttsVoices.any(
                (voice) => _voiceKey(voice) == _voiceKey(_selectedTtsVoice!),
              ) ||
              !_voiceMatchesLanguage(_selectedTtsVoice!))) {
        _selectedTtsVoice = null;
        await _settingsService.setTtsVoice(null);
      }
    } catch (error) {
      if (mounted) _showError('Could not load available voices: $error');
    } finally {
      _isLoadingVoices = false;
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final languageVoices = _ttsVoices
        .where((voice) => TtsService.voiceSupportsLanguage(voice, _ttsLanguage))
        .toList();
    final hasLanguageVoice = languageVoices.isNotEmpty;

    final isDark = themeProvider.themeMode == ThemeMode.dark ||
        (themeProvider.themeMode == ThemeMode.system &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);
    final bgColor = isDark ? const Color(0xFF090E1A) : const Color(0xFFF1F5F9);

    return Scaffold(
      backgroundColor: bgColor,
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
              'Settings',
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
        actions: const [
          ConnectivityBadge(),
          SizedBox(width: 14),
        ],
      ),
      body: Stack(
        children: [
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
                      _kAppBlue.withValues(alpha: isDark ? 0.30 : 0.20),
                      _kAppBlue.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
                      _kAppYellow.withValues(alpha: isDark ? 0.20 : 0.16),
                      _kAppYellow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
          // Theme Section
          _SectionHeader('Appearance'),
          _SettingsTile(
            title: 'Dark Mode',
            subtitle: 'Choose theme',
            trailing: DropdownButton<ThemeMode>(
              value: themeProvider.themeMode,
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('System'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (value) {
                if (value != null) {
                  themeProvider.setThemeMode(value);
                }
              },
              underline: const SizedBox(),
            ),
          ),
          _SettingsTile(
            title: 'Text Size',
            subtitle: 'Adjust text scaling',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _textScale,
                min: 0.8,
                max: 1.4,
                divisions: 6,
                label: '${(_textScale * 100).toInt()}%',
                onChanged: (value) async {
                  setState(() => _textScale = value);
                  await _settingsService.setTextScaleFactor(value);
                },
              ),
            ),
          ),

          const SizedBox(height: 24),
          // TTS Section
          _SectionHeader('Text-to-Speech'),
          _SettingsTile(
            title: 'Language',
            subtitle: 'TTS voice language',
            trailing: DropdownButton<String>(
              value: _ttsLanguage,
              items: const [
                DropdownMenuItem(
                  value: 'en-PH',
                  child: Text('English (Philippines)'),
                ),
                DropdownMenuItem(value: 'en-US', child: Text('English (US)')),
                DropdownMenuItem(value: 'en-GB', child: Text('English (UK)')),
                DropdownMenuItem(value: 'fil-PH', child: Text('Filipino')),
              ],
              onChanged: (value) async {
                if (value != null) {
                  setState(() => _ttsLanguage = value);
                  final ttsService = context.read<TtsService>();
                  try {
                    if (_ttsSource == 'offline_english' &&
                        value.toLowerCase() != 'en-us') {
                      await _settingsService.setTtsSource('offline');
                      if (mounted) setState(() => _ttsSource = 'offline');
                    }
                    await ttsService.setLanguage(value);
                    if (mounted) {
                      setState(
                        () => _selectedTtsVoice = _settingsService.ttsVoice,
                      );
                    }
                  } catch (error) {
                    if (mounted) {
                      setState(
                        () => _ttsLanguage = _settingsService.ttsLanguage,
                      );
                    }
                    _showError('Could not change voice language: $error');
                  }
                }
              },
              underline: const SizedBox(),
            ),
          ),
          _SettingsTile(
            title: 'Voice source',
            subtitle: switch (_ttsSource) {
              'online' => 'Microsoft online voice; text is sent to Microsoft',
              'offline_english' => 'Offline English neural female voice',
              'offline' => 'Installed device voice only',
              _
                  when _ttsLanguage.toLowerCase().startsWith('fil') &&
                      _ttsServerUrl.isNotEmpty =>
                'Microsoft online Filipino voice; text is sent to Microsoft',
              _ when _ttsLanguage.toLowerCase().startsWith('fil') =>
                'Using device voice; configure the server for Filipino neural '
                    'speech',
              _ => 'Use online when configured, then try the device voice',
            },
            trailing: DropdownButton<String>(
              value: _ttsSource,
              items: [
                const DropdownMenuItem(
                  value: 'automatic',
                  child: Text('Automatic'),
                ),
                const DropdownMenuItem(value: 'online', child: Text('Online')),
                const DropdownMenuItem(
                  value: 'offline',
                  child: Text('Offline'),
                ),
                if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                  const DropdownMenuItem(
                    value: 'offline_english',
                    child: Text('English female'),
                  ),
              ],
              onChanged: (value) async {
                if (value == null) return;
                if (value == 'offline_english' &&
                    _ttsLanguage.toLowerCase() != 'en-us') {
                  _showError(
                    'Select English (US) before choosing the offline English voice.',
                  );
                  return;
                }
                try {
                  await _settingsService.setTtsSource(value);
                  if (mounted) setState(() => _ttsSource = value);
                } catch (error) {
                  _showError('Could not change voice source: $error');
                }
              },
              underline: const SizedBox(),
            ),
          ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            _SettingsTile(
              title: 'Offline English female voice',
              subtitle: _offlineEnglishVoiceInstalled
                  ? 'Ready offline. Select English (US) to use it.'
                  : '147 MB download; keep about 350 MB free. English only.',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 130,
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _ttsOfflineEnglishVoice,
                      items: const [
                        DropdownMenuItem(
                          value: 'af_maple',
                          child: Text('Maple · Female'),
                        ),
                        DropdownMenuItem(
                          value: 'af_sol',
                          child: Text('Sol · Female'),
                        ),
                        DropdownMenuItem(
                          value: 'bf_vale',
                          child: Text('Vale · Female · UK'),
                        ),
                      ],
                      onChanged: (voice) async {
                        if (voice == null) return;
                        try {
                          await _settingsService.setTtsOfflineEnglishVoice(
                            voice,
                          );
                          if (mounted) {
                            setState(() => _ttsOfflineEnglishVoice = voice);
                          }
                        } catch (error) {
                          _showError('Could not change English voice: $error');
                        }
                      },
                      underline: const SizedBox(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isInstallingOfflineEnglishVoice)
                    SizedBox(
                      width: 72,
                      child: LinearProgressIndicator(
                        value: _offlineVoiceDownloadProgress,
                      ),
                    )
                  else
                    TextButton(
                      onPressed: _offlineEnglishVoiceInstalled
                          ? null
                          : _installOfflineEnglishVoice,
                      child: Text(
                        _offlineEnglishVoiceInstalled
                            ? 'Installed'
                            : 'Download',
                      ),
                    ),
                ],
              ),
            ),
          if (_ttsServerUrl.isNotEmpty)
            _SettingsTile(
              title: 'Filipino speech service',
              subtitle: 'Using $_ttsServerUrl',
              trailing: TextButton(
                onPressed: _configureOnlineTts,
                child: const Text('Edit'),
              ),
            ),
          if (_ttsLanguage.toLowerCase().startsWith('fil'))
            _SettingsTile(
              title: 'Online Filipino voice',
              subtitle: 'Female and male neural voices',
              trailing: DropdownButton<String>(
                value: _ttsOnlineVoice,
                items: const [
                  DropdownMenuItem(
                    value: 'fil-PH-BlessicaNeural',
                    child: Text('Blessica · Female'),
                  ),
                  DropdownMenuItem(
                    value: 'fil-PH-AngeloNeural',
                    child: Text('Angelo · Male'),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  try {
                    await _settingsService.setTtsOnlineVoice(value);
                    if (mounted) setState(() => _ttsOnlineVoice = value);
                  } catch (error) {
                    _showError('Could not change online voice: $error');
                  }
                },
                underline: const SizedBox(),
              ),
            ),
          _SettingsTile(
            title: 'Voice',
            subtitle: _isLoadingVoices
                ? 'Loading device voices...'
                : !hasLanguageVoice
                ? _ttsServerUrl.isNotEmpty &&
                          _ttsLanguage.toLowerCase().startsWith('fil')
                      ? 'No local Filipino voice; online Filipino speech is available'
                      : 'No ${_ttsLanguageName(_ttsLanguage)} voice is installed. Add its speech data in device or browser settings.'
                : 'Female voice selected automatically when the device identifies one',
            trailing: _isLoadingVoices
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : SizedBox(
                    width: 180,
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedTtsVoice == null
                          ? ''
                          : _voiceKey(_selectedTtsVoice!),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Automatic'),
                        ),
                        ...languageVoices.asMap().entries.map(
                          (entry) => DropdownMenuItem(
                            value: _voiceKey(entry.value),
                            child: Text(
                              _voiceLabel(entry.value, entry.key + 1),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: !hasLanguageVoice ? null : _selectTtsVoice,
                      underline: const SizedBox(),
                    ),
                  ),
          ),
          if (_ttsLanguage.toLowerCase().startsWith('fil') &&
              !kIsWeb &&
              defaultTargetPlatform == TargetPlatform.android)
            _SettingsTile(
              title: 'Offline Filipino voice',
              subtitle: hasLanguageVoice
                  ? 'Device Filipino voice is available'
                  : 'Download Filipino speech data from Android',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Refresh device voices',
                    onPressed: _loadSettings,
                    icon: const Icon(Icons.refresh),
                  ),
                  TextButton(
                    onPressed: _installOfflineVoice,
                    child: const Text('Install'),
                  ),
                ],
              ),
            ),
          _SettingsTile(
            title: 'Speech Rate',
            subtitle: 'Adjust speaking speed',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: _ttsRate,
                min: 0.3,
                max: 0.8,
                divisions: 5,
                label: _ttsRate.toStringAsFixed(1),
                onChanged: (value) async {
                  setState(() => _ttsRate = value);
                  final ttsService = context.read<TtsService>();
                  try {
                    await ttsService.setRate(value);
                  } catch (error) {
                    _showError('Could not change speech rate: $error');
                  }
                },
              ),
            ),
          ),
          _SettingsTile(
            title: 'Test Voice',
            subtitle: 'Hear the current TTS settings',
            trailing: IconButton(
              icon: const Icon(Icons.volume_up),
              onPressed: _testVoice,
            ),
          ),

          const SizedBox(height: 24),
          // Model Section
          _SectionHeader('Model'),
          _SettingsTile(
            title: 'Model Version',
            subtitle: _modelVersion == 'Not installed'
                ? 'The FSL recognition model is still in training'
                : _modelVersion,
          ),
          _SettingsTile(
            title: 'Check for Model Updates (OTA)',
            subtitle: 'Fetch latest FSL recognition model over the air',
            trailing: const Icon(Icons.cloud_download_outlined),
            onTap: () {
              final messenger = ScaffoldMessenger.of(context);
              final serverUrl = _settingsService.ttsServerUrl;
              final otaManifestUrl = serverUrl.isNotEmpty
                  ? '$serverUrl/api/v1/ota/manifest'
                  : ModelUpdater.defaultRemoteManifestUrl;
              final updater = ModelUpdater(remoteManifestUrl: otaManifestUrl);
              showDialog(
                context: context,
                builder: (context) => ModelUpdateDialog(
                  modelUpdater: updater,
                  onUpdateComplete: () async {
                    final newVersion = await updater.getInstalledVersion();
                    await _settingsService.setModelVersion(newVersion);
                    if (!mounted) return;
                    setState(() {
                      _modelVersion = newVersion;
                    });
                    messenger.showSnackBar(
                      SnackBar(content: Text('Model updated to $newVersion')),
                    );
                  },
                ),
              );
            },
          ),

          const SizedBox(height: 24),
          // Data Section
          _SectionHeader('Data & Privacy'),
          _SettingsTile(
            title: 'Save History (Private Mode)',
            subtitle: _settingsService.saveHistoryEnabled
                ? 'Conversation history is stored in local database'
                : 'Private Mode active: translations are not saved to database',
            trailing: Switch(
              value: _settingsService.saveHistoryEnabled,
              onChanged: (val) async {
                await _settingsService.setSaveHistoryEnabled(val);
                if (mounted) setState(() {});
              },
            ),
          ),
          _SettingsTile(
            title: 'Audio/Visual Recording Consent',
            subtitle: _settingsService.hasRecordingConsent
                ? 'Consent granted for microphone audio & camera recognition'
                : 'Consent required prior to recording voice or video',
            trailing: Switch(
              value: _settingsService.hasRecordingConsent,
              onChanged: (val) async {
                await _settingsService.setRecordingConsent(val);
                if (mounted) setState(() {});
              },
            ),
          ),
          _SettingsTile(
            title: 'Export History',
            subtitle: 'Export translation history as CSV',
            trailing: const Icon(Icons.download),
            onTap: _exportHistory,
          ),
          _SettingsTile(
            title: 'Clear History',
            subtitle: 'Delete all translation history',
            trailing: const Icon(Icons.delete_outline, color: Colors.red),
            onTap: _clearHistory,
          ),
          _SettingsTile(
            title: 'Clear Cache',
            subtitle: 'Remove exported history files',
            trailing: const Icon(Icons.cleaning_services),
            onTap: _clearCache,
          ),

          const SizedBox(height: 24),
          // Legal & About Section
          _SectionHeader('About'),

          _SettingsTile(
            title: 'Welcome & Landing Page',
            subtitle: 'Revisit introduction, quick phrases & controls',
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LandingPageScreen()),
              );
            },
          ),
          _SettingsTile(
            title: 'Version',
            subtitle: '1.1.0',
            onTap: () => _showAboutDialog('Version'),
          ),
          _SettingsTile(
            title: 'Licenses',
            subtitle: 'Open source licenses',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(context: context),
          ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  ],
),
);
  }

  Future<void> _exportHistory() async {
    try {
      final conversations = await DatabaseHelper.instance.getHistory(
        limit: 100000,
      );
      if (conversations.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('There is no history to export')),
          );
        }
        return;
      }

      final csv = StringBuffer('id,text,confidence,source,timestamp\r\n');
      for (final conversation in conversations) {
        csv.writeln(
          [
            conversation.id,
            conversation.text,
            conversation.confidence,
            conversation.source,
            conversation.timestamp.toIso8601String(),
          ].map(_escapeCsvField).join(','),
        );
      }

      final tempDirectory = await getTemporaryDirectory();
      final file = File(
        '${tempDirectory.path}${Platform.pathSeparator}'
        'tinigsenyas_history_${DateTime.now().millisecondsSinceEpoch}.csv',
      );
      await file.writeAsString(csv.toString(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'TinigSenyas translation history',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export history: $error')),
        );
      }
    }
  }

  String _escapeCsvField(Object? value) {
    final escaped = (value?.toString() ?? '').replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _testVoice() async {
    try {
      final text = _ttsSource == 'offline_english'
          ? 'Hello. This is Tinig Senyas.'
          : 'Kumusta. Ito ang Tinig Senyas.';
      await context.read<TtsService>().speak(text);
    } catch (error) {
      _showError('Could not play test voice: $error');
    }
  }

  Future<void> _installOfflineEnglishVoice() async {
    setState(() {
      _isInstallingOfflineEnglishVoice = true;
      _offlineVoiceDownloadProgress = null;
    });
    try {
      await context.read<TtsService>().installOfflineEnglishVoice(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(
            () => _offlineVoiceDownloadProgress = total > 0
                ? received / total
                : null,
          );
        },
      );
      if (mounted) {
        setState(() => _offlineEnglishVoiceInstalled = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Offline English female voice installed'),
          ),
        );
      }
    } catch (error) {
      _showError('Could not install offline English voice: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isInstallingOfflineEnglishVoice = false;
          _offlineVoiceDownloadProgress = null;
        });
      }
    }
  }

  Future<void> _installOfflineVoice() async {
    try {
      await context.read<TtsService>().openOfflineVoiceSettings();
    } catch (error) {
      _showError('Could not open Android voice-data settings: $error');
    }
  }

  Future<void> _configureOnlineTts() async {
    final savedToken = await _settingsService.getTtsServerToken();
    if (!mounted) return;
    final urlController = TextEditingController(text: _ttsServerUrl);
    final tokenController = TextEditingController(text: savedToken);
    try {
      final result = await showDialog<({String url, String token})>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Configure online TTS'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Backend URL',
                  hintText: 'https://your-server.example',
                ),
              ),
              TextField(
                controller: tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'TTS access token',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'For local development, the speech service is detected '
                'automatically and does not need a token. A hosted app can '
                'detect a same-origin speech service. Never put an Azure key '
                'here.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (
                url: urlController.text.trim(),
                token: tokenController.text.trim(),
              )),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (result == null) return;
      await _settingsService.setTtsServer(url: result.url, token: result.token);
      if (mounted) {
        setState(() => _ttsServerUrl = _settingsService.ttsServerUrl);
      }
    } catch (error) {
      _showError('Could not save online TTS server: $error');
    } finally {
      urlController.dispose();
      tokenController.dispose();
    }
  }

  String _voiceKey(Map<String, String> voice) =>
      '${voice['locale'] ?? ''}|${voice['name'] ?? ''}|${voice['identifier'] ?? ''}';

  bool _voiceMatchesLanguage(Map<String, String> voice) =>
      TtsService.voiceSupportsLanguage(voice, _ttsLanguage);

  String _ttsLanguageName(String language) =>
      language.toLowerCase().startsWith('fil') ||
          language.toLowerCase().startsWith('tl')
      ? 'Filipino'
      : language;

  String _voiceLabel(Map<String, String> voice, [int? index]) {
    final rawName = (voice['name'] ?? '').toLowerCase();
    final isOnline = rawName.contains('network') || rawName.contains('online');
    final isFemale = TtsService.isFemaleVoice(voice) ||
        rawName.contains('cfc') ||
        rawName.contains('fie') ||
        rawName.contains('female');
    final gender = isFemale ? 'Female' : 'Male';
    final type = isOnline ? 'Online' : 'Device';

    if (rawName.contains('-language')) {
      return 'Default ($gender)';
    }

    final voiceNum = index != null ? 'Voice $index' : 'Voice';
    return '$voiceNum · $gender ($type)';
  }

  Future<void> _selectTtsVoice(String? key) async {
    final voice = key == null || key.isEmpty
        ? null
        : _ttsVoices.firstWhere((candidate) => _voiceKey(candidate) == key);
    final ttsService = context.read<TtsService>();
    try {
      await ttsService.setVoice(voice);
      if (mounted) setState(() => _selectedTtsVoice = voice);
    } catch (error) {
      _showError('Could not change voice: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text(
          'Are you sure you want to delete all translation history? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DatabaseHelper.instance.clearHistory();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('History cleared')));
      }
    }
  }

  Future<void> _clearCache() async {
    try {
      final tempDirectory = await getTemporaryDirectory();
      var deletedFiles = 0;
      await for (final entity in tempDirectory.list()) {
        if (entity is File &&
            RegExp(
              r'^tinigsenyas_history_\d+\.csv$',
            ).hasMatch(entity.uri.pathSegments.last)) {
          await entity.delete();
          deletedFiles++;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed $deletedFiles exported file(s)')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear exported files: $error')),
        );
      }
    }
  }

  void _showAboutDialog(String title) {
    showAboutDialog(
      context: context,
      applicationName: 'TinigSenyas',
      applicationVersion: '1.0.0',
      applicationLegalese:
          'Filipino Sign Language e-Learning & Translation System',
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 14, left: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: _kAppBlue,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              color: isDark ? const Color(0xFF60A5FA) : _kAppBlue,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141F36) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.15) : _kAppBlue.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                )
              : null,
          trailing: trailing,
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
      ),
    );
  }
}
