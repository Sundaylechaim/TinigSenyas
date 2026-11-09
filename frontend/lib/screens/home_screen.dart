import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../services/settings_service.dart';
import '../widgets/connectivity_badge.dart';
import '../widgets/fsl_guide_sheet.dart';
import 'sign_to_text_screen.dart';
import 'speech_to_text_screen.dart';
import 'settings_screen.dart';
import 'landing_page_screen.dart';
import 'history_screen.dart';

const Color _kAppBlue = Color(0xFF0138FF);
const Color _kAppYellow = Color(0xFFFFC801);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _modelVersion = 'Not installed';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = context.read<SettingsService>();
    _modelVersion = settings.modelVersion;
    if (mounted) setState(() {});
  }

  void _openLandingPage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LandingPageScreen()),
    );
  }

  String _formatTtsLanguage(String code) {
    final lower = code.toLowerCase();
    if (lower.startsWith('fil') || lower.startsWith('tl')) return 'Filipino';
    if (lower.contains('ph')) return 'English (PH)';
    if (lower.contains('us')) return 'English (US)';
    if (lower.contains('gb')) return 'English (UK)';
    return code;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final settingsService = context.watch<SettingsService>();
    final textScale = settingsService.textScaleFactor;

    final bgColor = isDarkMode ? const Color(0xFF090E1A) : const Color(0xFFF1F5F9);
    final textColor = isDarkMode ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDarkMode ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      extendBodyBehindAppBar: true,

      // GLASSMORPHIC APP BAR WITH AUTHENTIC LOGO (NO BOX)
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: isDarkMode
                    ? const Color(0xFF0C1220).withValues(alpha: 0.70)
                    : Colors.white.withValues(alpha: 0.75),
                border: Border(
                  bottom: BorderSide(
                    color: isDarkMode
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
            // Authentic logo image without artificial box
            Image.asset(
              'assets/images/logo.png',
              height: 26,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.sign_language_rounded,
                color: _kAppBlue,
                size: 24,
              ),
            ),
            const SizedBox(width: 8),
            const Flexible(
              child: Text(
                'TinigSenyas',
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
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'FSL Guide & Phrases',
            visualDensity: VisualDensity.compact,
            onPressed: () => showFslGuideSheet(context),
          ),
          const SizedBox(width: 4),
          const ConnectivityBadge(),
          const SizedBox(width: 10),
        ],
      ),

      // ACCESSIBLE NAVIGATION DRAWER
      drawer: Drawer(
        backgroundColor: isDarkMode
            ? const Color(0xFF0E1626).withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.96),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDarkMode
                        ? [_kAppBlue.withValues(alpha: 0.5), const Color(0xFF0C1220)]
                        : [_kAppBlue, const Color(0xFF002BB5)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Real logo without circle/box wrapper
                    Image.asset(
                      'assets/images/logo.png',
                      height: 40,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.sign_language_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'TinigSenyas System',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      'Filipino Sign Language Assistant',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),

              // Dark Mode Switch
              SwitchListTile(
                secondary: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: (isDarkMode ? _kAppYellow : _kAppBlue).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                    color: isDarkMode ? _kAppYellow : _kAppBlue,
                    size: 20,
                  ),
                ),
                title: const Text('Dark Mode', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                value: isDarkMode,
                onChanged: (val) {
                  context.read<ThemeProvider>().setThemeMode(
                    val ? ThemeMode.dark : ThemeMode.light,
                  );
                },
              ),
              const Divider(height: 1),

              // Text Size Scale for Accessibility
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _kAppBlue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.format_size_rounded, color: _kAppBlue, size: 20),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Text Size Scale',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Text(
                      '${(textScale * 100).toInt()}%',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: subtextColor,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Slider(
                  activeColor: _kAppBlue,
                  thumbColor: _kAppYellow,
                  value: textScale,
                  min: 0.8,
                  max: 1.4,
                  divisions: 6,
                  label: '${(textScale * 100).toInt()}%',
                  onChanged: (val) {
                    settingsService.setTextScaleFactor(val);
                  },
                ),
              ),
              const Divider(height: 1),

              // Direct Navigation Destinations
              ListTile(
                leading: const Icon(Icons.history_rounded, color: _kAppBlue),
                title: const Text('Translation History', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: const Text('View saved conversations & logs', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.psychology_outlined, color: _kAppBlue),
                title: const Text('FSL Model Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: Text('Status: $_modelVersion', style: const TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.menu_book_rounded, color: _kAppBlue),
                title: const Text('FSL Guide & Reference', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: const Text('Phrases, alphabet & tips', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  showFslGuideSheet(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.explore_outlined, color: _kAppBlue),
                title: const Text('Welcome Guide & Tutorial', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: const Text('Quick introduction to TinigSenyas', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _openLandingPage(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined, color: _kAppBlue),
                title: const Text('System Settings', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: const Text('Voice tuning & preferences', style: TextStyle(fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded, color: Colors.grey),
                title: const Text('About TinigSenyas', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                onTap: () {
                  Navigator.pop(context);
                  showAboutDialog(
                    context: context,
                    applicationName: 'TinigSenyas',
                    applicationVersion: '1.2.0',
                    applicationLegalese: 'Filipino Sign Language e-Learning & Translation System',
                  );
                },
              ),
            ],
          ),
        ),
      ),

      // BODY WITH AMBIENT GLOW AND FLUID SPACING
      body: Stack(
        children: [
          // Ambient Glow Top-Right
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
                      _kAppBlue.withValues(alpha: isDarkMode ? 0.30 : 0.20),
                      _kAppBlue.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Ambient Glow Center-Left
          Positioned(
            top: 260,
            left: -80,
            child: IgnorePointer(
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _kAppYellow.withValues(alpha: isDarkMode ? 0.20 : 0.18),
                      _kAppYellow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Main Dashboard Content
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 14.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. ENGAGING HERO HEADER (NO BOX - SITS NATURALLY ON CANVAS)
                  _buildEngagingHeroHeader(
                    context,
                    isDarkMode,
                    textColor,
                    subtextColor,
                    settingsService,
                  ),

                  const SizedBox(height: 22),

                  // Section Header: PRIMARY TRANSLATION MODES
                  Row(
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
                        'TRANSLATION MODES',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                          color: isDarkMode ? const Color(0xFF60A5FA) : _kAppBlue,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Card 1: SIGN TO TEXT (Camera Recognition)
                  _PrimaryTranslationCard(
                    icon: Icons.sign_language_rounded,
                    accentColor: _kAppBlue,
                    category: 'CAMERA RECOGNITION',
                    title: 'Sign to Text & Voice',
                    description: 'Translate Filipino Sign Language gestures in real time using your device camera.',
                    actionText: 'Open Camera Translation',
                    isDark: isDarkMode,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SignToTextScreen()),
                      );
                    },
                  ),

                  const SizedBox(height: 14),

                  // Card 2: SPEECH TO TEXT (Voice Recognition)
                  _PrimaryTranslationCard(
                    icon: Icons.mic_rounded,
                    accentColor: _kAppYellow,
                    category: 'VOICE ASSISTANT',
                    title: 'Speech to Text & Signs',
                    description: 'Speak naturally to transcribe your voice into clear text for deaf and hard-of-hearing partners.',
                    actionText: 'Start Voice Translation',
                    isDark: isDarkMode,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SpeechToTextScreen()),
                      );
                    },
                  ),

                  const SizedBox(height: 24),

                  // Section Header: QUICK ACCESS & TOOLS
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 16,
                        decoration: BoxDecoration(
                          color: _kAppYellow,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'QUICK TOOLS & EXPLORATION',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                          color: isDarkMode ? const Color(0xFFFDE047) : const Color(0xFFB45309),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Quick Access Navigation Row
                  Row(
                    children: [
                      // Quick Tool 1: History
                      Expanded(
                        child: _QuickToolCard(
                          icon: Icons.history_rounded,
                          accentColor: const Color(0xFF3B82F6),
                          title: 'History',
                          subtitle: 'Past logs',
                          isDark: isDarkMode,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const HistoryScreen()),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Quick Tool 2: Audio & Settings
                      Expanded(
                        child: _QuickToolCard(
                          icon: Icons.tune_rounded,
                          accentColor: const Color(0xFF10B981),
                          title: 'Settings',
                          subtitle: 'Speech & AI',
                          isDark: isDarkMode,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SettingsScreen()),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Quick Tool 3: FSL Phrase Guide
                      Expanded(
                        child: _QuickToolCard(
                          icon: Icons.menu_book_rounded,
                          accentColor: const Color(0xFFF59E0B),
                          title: 'FSL Guide',
                          subtitle: 'Phrases',
                          isDark: isDarkMode,
                          onTap: () => showFslGuideSheet(context),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ENGAGING HERO HEADER (NO ENCLOSING BOX - FLOWS NATURALLY)
  Widget _buildEngagingHeroHeader(
    BuildContext context,
    bool isDarkMode,
    Color textColor,
    Color subtextColor,
    SettingsService settingsService,
  ) {
    final hour = DateTime.now().hour;
    final timeGreeting = hour < 12
        ? 'Magandang Umaga'
        : hour < 18
            ? 'Magandang Hapon'
            : 'Magandang Gabi';

    final isModelTraining = _modelVersion == 'Not installed';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        // Warm greetings row
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '$timeGreeting!',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('👋', style: TextStyle(fontSize: 22)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Bridging Filipino Sign Language & Spoken Voice',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: subtextColor,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Interactive Status Pills Row (Engaging & Accessible)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              // 1. FSL Model Status Pill
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? (isModelTraining
                              ? Colors.amber.withValues(alpha: 0.15)
                              : Colors.green.withValues(alpha: 0.15))
                          : (isModelTraining
                              ? Colors.amber.withValues(alpha: 0.12)
                              : Colors.green.withValues(alpha: 0.12)),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isModelTraining
                            ? Colors.amber.withValues(alpha: 0.4)
                            : Colors.green.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: isModelTraining ? Colors.amber[700] : Colors.green[600],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isModelTraining ? 'Model: Training' : 'Model: Active',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isModelTraining
                                ? (isDarkMode ? Colors.amber[300] : Colors.amber[900])
                                : (isDarkMode ? Colors.green[300] : Colors.green[800]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // 2. Speech Engine / TTS Pill
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? _kAppBlue.withValues(alpha: 0.18)
                          : _kAppBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _kAppBlue.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.volume_up_rounded,
                          size: 13,
                          color: isDarkMode ? const Color(0xFF93C5FD) : _kAppBlue,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'TTS: ${_formatTtsLanguage(settingsService.ttsLanguage)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDarkMode ? const Color(0xFF93C5FD) : _kAppBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // 3. Privacy / Mode Pill
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? Colors.white.withValues(alpha: 0.07)
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDarkMode
                            ? Colors.white.withValues(alpha: 0.15)
                            : Colors.black.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          settingsService.saveHistoryEnabled
                              ? Icons.history_rounded
                              : Icons.visibility_off_rounded,
                          size: 13,
                          color: subtextColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          settingsService.saveHistoryEnabled ? 'History On' : 'Private Mode',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: subtextColor,
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
      ],
    );
  }
}

// PRIMARY TRANSLATION CARD (ACCESSIBLE, PROMINENT, MODERN)
class _PrimaryTranslationCard extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String category;
  final String title;
  final String description;
  final String actionText;
  final VoidCallback onTap;
  final bool isDark;

  const _PrimaryTranslationCard({
    required this.icon,
    required this.accentColor,
    required this.category,
    required this.title,
    required this.description,
    required this.actionText,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF141F36).withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF223253)
                  : const Color(0xFFE2E8F0),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.22)
                    : accentColor.withValues(alpha: 0.06),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Accessible Icon Container
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: isDark ? 0.22 : 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: accentColor.withValues(alpha: 0.4),
                              width: 1,
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              icon,
                              size: 28,
                              color: isDark
                                  ? (accentColor == _kAppYellow ? _kAppYellow : const Color(0xFF60A5FA))
                                  : (accentColor == _kAppYellow ? const Color(0xFFB45309) : _kAppBlue),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Category badge
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: isDark ? 0.20 : 0.10),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  category,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                    letterSpacing: 0.5,
                                    color: isDark
                                        ? (accentColor == _kAppYellow ? _kAppYellow : const Color(0xFF93C5FD))
                                        : (accentColor == _kAppYellow ? const Color(0xFFB45309) : _kAppBlue),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 17,
                                  color: textColor,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 13,
                        color: subtextColor,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Action Button Pill
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: accentColor == _kAppYellow
                                ? (isDark ? _kAppYellow.withValues(alpha: 0.25) : const Color(0xFFFFFBEB))
                                : (isDark ? _kAppBlue.withValues(alpha: 0.25) : const Color(0xFFEFF6FF)),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: accentColor.withValues(alpha: 0.35),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                actionText,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: isDark
                                      ? (accentColor == _kAppYellow ? _kAppYellow : const Color(0xFF93C5FD))
                                      : (accentColor == _kAppYellow ? const Color(0xFFB45309) : _kAppBlue),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.arrow_forward_rounded,
                                size: 14,
                                color: isDark
                                    ? (accentColor == _kAppYellow ? _kAppYellow : const Color(0xFF93C5FD))
                                    : (accentColor == _kAppYellow ? const Color(0xFFB45309) : _kAppBlue),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// QUICK ACCESS TOOL CARD
class _QuickToolCard extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDark;

  const _QuickToolCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Container(
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
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: isDark ? 0.22 : 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: isDark ? const Color(0xFF93C5FD) : accentColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: subtextColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
