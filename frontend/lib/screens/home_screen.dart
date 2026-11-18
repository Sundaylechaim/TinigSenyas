import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/model_updater.dart';
import '../services/settings_service.dart';
import '../widgets/connectivity_badge.dart';
import '../widgets/fsl_guide_sheet.dart';
import 'sign_to_text_screen.dart';
import 'speech_to_text_screen.dart';
import 'text_to_sign_screen.dart';
import 'settings_screen.dart';
import 'history_screen.dart';

const Color _kAppBlue = Color(0xFF2D5FB8);
const Color _kAppYellow = Color(0xFFF4C95D);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onSelectTab});

  final ValueChanged<int>? onSelectTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  void _openDestination(BuildContext context, int tabIndex, Widget screen) {
    final selectTab = widget.onSelectTab;
    if (selectTab != null) {
      selectTab(tabIndex);
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final settingsService = context.watch<SettingsService>();

    final bgColor = isDarkMode
        ? const Color(0xFF090E1A)
        : const Color(0xFFF1F5F9);
    final textColor = isDarkMode ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDarkMode
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

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
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
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

      // Essential navigation and support links.
      drawer: Drawer(
        backgroundColor: isDarkMode
            ? const Color(0xFF0E1626).withValues(alpha: 0.98)
            : Colors.white,
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              DrawerHeader(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDarkMode
                        ? [
                            _kAppBlue.withValues(alpha: 0.5),
                            const Color(0xFF0C1220),
                          ]
                        : [_kAppBlue, const Color(0xFF1E3A8A)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Image.asset(
                      'assets/images/logo.png',
                      height: 38,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.sign_language_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'TinigSenyas',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      'Everyday connection through FSL',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.86),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  'COMMUNICATE',
                  style: TextStyle(
                    color: subtextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.sign_language_rounded,
                  color: _kAppBlue,
                ),
                title: const Text('Sign to Text & Voice'),
                onTap: () {
                  Navigator.pop(context);
                  _openDestination(context, 1, const SignToTextScreen());
                },
              ),
              ListTile(
                leading: const Icon(Icons.mic_rounded, color: _kAppBlue),
                title: const Text('Speech to Captions'),
                onTap: () {
                  Navigator.pop(context);
                  _openDestination(context, 3, const SpeechToTextScreen());
                },
              ),
              ListTile(
                leading: const Icon(Icons.menu_book_rounded, color: _kAppBlue),
                title: const Text('Type, Speak & FSL Signs'),
                onTap: () {
                  Navigator.pop(context);
                  _openDestination(context, 2, const TextToSignScreen());
                },
              ),
              const Divider(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text(
                  'APP',
                  style: TextStyle(
                    color: subtextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.history_rounded, color: _kAppBlue),
                title: const Text('Translation History'),
                onTap: () {
                  Navigator.pop(context);
                  _openDestination(context, 4, const HistoryScreen());
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined, color: _kAppBlue),
                title: const Text('Settings'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
              const Divider(height: 12),
              ListTile(
                leading: const Icon(
                  Icons.info_outline_rounded,
                  color: _kAppBlue,
                ),
                title: const Text('About TinigSenyas'),
                onTap: () {
                  Navigator.pop(context);
                  showAboutDialog(
                    context: context,
                    applicationName: 'TinigSenyas',
                    applicationVersion: ModelUpdater.currentAppVersion,
                    applicationIcon: const Icon(
                      Icons.sign_language_rounded,
                      color: _kAppBlue,
                      size: 40,
                    ),
                    applicationLegalese:
                        'Connecting communities through Filipino Sign Language.',
                    children: [
                      const SizedBox(height: 12),
                      const Text(
                        'TinigSenyas is a communication companion for Deaf and hearing people. It brings together recognition for supported Filipino Sign Language signs, live speech captions, and visual sign guides to make everyday conversations easier to share.',
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Created to support connection in homes, schools, and community services, TinigSenyas honors the language, expertise, and leadership of the Deaf community.',
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Sa Filipino',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Ang TinigSenyas ay katuwang sa komunikasyon ng mga Bingi at nakaririnig. Pinag-uugnay nito ang pagkilala sa mga FSL senyas na suportado ng app, live na caption mula sa pagsasalita, at mga visual na gabay sa senyas. Dinisenyo ito upang makatulong sa pang-araw-araw na usapan sa tahanan, paaralan, at mga serbisyo sa komunidad, habang kinikilala ang wika, kaalaman, at pamumuno ng komunidad ng mga Bingi.',
                      ),
                    ],
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
                      _kAppBlue.withValues(alpha: isDarkMode ? 0.16 : 0.08),
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
                      _kAppYellow.withValues(alpha: isDarkMode ? 0.10 : 0.07),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 16.0,
              ),
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
                      Expanded(
                        child: Text(
                          'Choose how to communicate',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
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
                    description:
                        'Translate Filipino Sign Language gestures in real time using your device camera.',
                    actionText: 'Open Camera Translation',
                    isDark: isDarkMode,
                    onTap: () =>
                        _openDestination(context, 1, const SignToTextScreen()),
                  ),

                  const SizedBox(height: 16),

                  // Card 2: SPEECH TO TEXT (Voice Recognition)
                  _PrimaryTranslationCard(
                    icon: Icons.mic_rounded,
                    accentColor: _kAppYellow,
                    category: 'VOICE ASSISTANT',
                    title: 'Speech to Text & Signs',
                    description:
                        'Speak naturally to transcribe your voice into clear text for deaf and hard-of-hearing partners.',
                    actionText: 'Start Voice Translation',
                    isDark: isDarkMode,
                    onTap: () => _openDestination(
                      context,
                      3,
                      const SpeechToTextScreen(),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Typed messages use the same recorded FSL clip preview as speech transcripts.
                  _PrimaryTranslationCard(
                    icon: Icons.chat_bubble_outline_rounded,
                    accentColor: const Color(0xFF10B981),
                    category: 'TYPE A MESSAGE',
                    title: 'Type & Speak',
                    description:
                        'Type a message to speak it aloud, or preview available FSL sign clips.',
                    actionText: 'Open Message Composer',
                    isDark: isDarkMode,
                    onTap: () =>
                        _openDestination(context, 2, const TextToSignScreen()),
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
                        'More tools',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: textColor,
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
                          accentColor: _kAppBlue,
                          title: 'History',
                          subtitle: 'Past logs',
                          isDark: isDarkMode,
                          onTap: () => _openDestination(
                            context,
                            4,
                            const HistoryScreen(),
                          ),
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
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
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
                      Flexible(
                        child: Text(
                          '$timeGreeting!',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: MediaQuery.sizeOf(context).width < 400
                                ? 20
                                : 25,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                            color: textColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text('👋', style: TextStyle(fontSize: 20)),
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

        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDarkMode
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.80),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDarkMode
                    ? Colors.white.withValues(alpha: 0.12)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  settingsService.saveHistoryEnabled
                      ? Icons.history_rounded
                      : Icons.visibility_off_rounded,
                  size: 15,
                  color: subtextColor,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    settingsService.saveHistoryEnabled
                        ? 'Conversation history is on'
                        : 'Private mode is on',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: subtextColor,
                    ),
                  ),
                ),
              ],
            ),
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
    final subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

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
              color: isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0),
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
                            color: accentColor.withValues(
                              alpha: isDark ? 0.22 : 0.12,
                            ),
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
                                  ? (accentColor == _kAppYellow
                                        ? _kAppYellow
                                        : const Color(0xFF60A5FA))
                                  : (accentColor == _kAppYellow
                                        ? const Color(0xFFB45309)
                                        : _kAppBlue),
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(
                                    alpha: isDark ? 0.20 : 0.10,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  category,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                    letterSpacing: 0.5,
                                    color: isDark
                                        ? (accentColor == _kAppYellow
                                              ? _kAppYellow
                                              : const Color(0xFF93C5FD))
                                        : (accentColor == _kAppYellow
                                              ? const Color(0xFFB45309)
                                              : _kAppBlue),
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
                    SizedBox(
                      width: double.infinity,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: accentColor == _kAppYellow
                              ? (isDark
                                    ? _kAppYellow.withValues(alpha: 0.25)
                                    : const Color(0xFFFFFBEB))
                              : (isDark
                                    ? _kAppBlue.withValues(alpha: 0.25)
                                    : const Color(0xFFEFF6FF)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: accentColor.withValues(alpha: 0.35),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                actionText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: isDark
                                      ? (accentColor == _kAppYellow
                                            ? _kAppYellow
                                            : const Color(0xFF93C5FD))
                                      : (accentColor == _kAppYellow
                                            ? const Color(0xFFB45309)
                                            : _kAppBlue),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 14,
                              color: isDark
                                  ? (accentColor == _kAppYellow
                                        ? _kAppYellow
                                        : const Color(0xFF93C5FD))
                                  : (accentColor == _kAppYellow
                                        ? const Color(0xFFB45309)
                                        : _kAppBlue),
                            ),
                          ],
                        ),
                      ),
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
    final subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

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
            color: isDark
                ? Colors.black.withValues(alpha: 0.15)
                : _kAppBlue.withValues(alpha: 0.03),
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
