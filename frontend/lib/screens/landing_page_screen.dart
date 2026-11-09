import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../services/settings_service.dart';
import '../widgets/connectivity_badge.dart';
import '../main.dart';
import 'sign_to_text_screen.dart';
import 'speech_to_text_screen.dart';

/// Complementary palette from user reference:
/// Sun Golden Yellow (#FFC801) and Electric Royal Blue (#0138FF)
const Color _kAppBlue = Color(0xFF0138FF);
const Color _kAppBlueDark = Color(0xFF002BB5);
const Color _kAppYellow = Color(0xFFFFC801);
const Color _kAppYellowDark = Color(0xFFE5B400);

class DemoPhrase {
  final String tagalog;
  final String english;
  final String fsl;
  final IconData icon;

  const DemoPhrase({
    required this.tagalog,
    required this.english,
    required this.fsl,
    required this.icon,
  });
}

class LandingPageScreen extends StatefulWidget {
  const LandingPageScreen({super.key});

  @override
  State<LandingPageScreen> createState() => _LandingPageScreenState();
}

class _LandingPageScreenState extends State<LandingPageScreen> {
  bool _isTagalog = true;
  int _selectedDemoIndex = 0;

  final List<DemoPhrase> _samplePhrases = const [
    DemoPhrase(
      tagalog: 'Kamusta ka?',
      english: 'How are you?',
      fsl: 'Hawakan ang dibdib at dahan-dahang itaas ang kamay na may kasamang ngiti.',
      icon: Icons.waving_hand_rounded,
    ),
    DemoPhrase(
      tagalog: 'Salamat!',
      english: 'Thank you!',
      fsl: 'Ipatong ang mga daliri ng kanang kamay sa labi at iunat ito pasulong.',
      icon: Icons.volunteer_activism_rounded,
    ),
    DemoPhrase(
      tagalog: 'Mahal kita',
      english: 'I love you',
      fsl: 'I-angat ang hinlalaki, hintuturo, at kalingkingan nang magkasabay (ILY sign).',
      icon: Icons.favorite_rounded,
    ),
    DemoPhrase(
      tagalog: 'Tulong po',
      english: 'Need help',
      fsl: 'Ipatong ang nakasarang kamao na may hinlalaking nakataas sa kabilang palad.',
      icon: Icons.help_outline_rounded,
    ),
    DemoPhrase(
      tagalog: 'Magandang araw',
      english: 'Good day',
      fsl: 'Ilagay ang kamay sa bibig at iunat pasulong (salamat), sabay iunat ang palad pataas.',
      icon: Icons.wb_sunny_rounded,
    ),
  ];

  void _goToDashboard(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
      );
    }
  }

  void _openSignToText(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignToTextScreen()),
    );
  }

  void _openSpeechToText(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SpeechToTextScreen()),
    );
  }

  void _adjustTextScale(BuildContext context, double delta) {
    final settings = context.read<SettingsService>();
    final newScale = (settings.textScaleFactor + delta).clamp(0.8, 1.4);
    settings.setTextScaleFactor(double.parse(newScale.toStringAsFixed(1)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final settingsService = context.watch<SettingsService>();
    final textScale = settingsService.textScaleFactor;
    final canPop = Navigator.of(context).canPop();

    // Mobile background palette
    final bgColor = isDark ? const Color(0xFF0C1220) : const Color(0xFFF6F8FC);
    final cardBg = isDark ? const Color(0xFF141F36) : Colors.white;
    final borderColor = isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      // MOBILE NATIVE APP BAR
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF0C1220) : Colors.white,
        centerTitle: false,
        leading: canPop
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                tooltip: _isTagalog ? 'Bumalik' : 'Back',
                onPressed: () => Navigator.of(context).pop(),
              )
            : Container(
                margin: const EdgeInsets.only(left: 14),
                alignment: Alignment.centerLeft,
                child: Image.asset(
                  'assets/images/logo.png',
                  height: 32,
                  fit: BoxFit.contain,
                ),
              ),
        titleSpacing: 8,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Flexible(
                  child: Text(
                    'TinigSenyas',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      letterSpacing: -0.5,
                      color: _kAppBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: _kAppYellow,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            Text(
              _isTagalog ? 'FSL Translation Bridge' : 'FSL Mobile Assistant',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: subtextColor,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        actions: [
          // Connectivity indicator
          const ConnectivityBadge(),
          const SizedBox(width: 6),

          // Compact Mobile Language Pill (FIL / EN)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLanguageButton(
                  label: 'FIL',
                  active: _isTagalog,
                  onTap: () => setState(() => _isTagalog = true),
                ),
                _buildLanguageButton(
                  label: 'EN',
                  active: !_isTagalog,
                  onTap: () => setState(() => _isTagalog = false),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),

          // Dark mode toggle
          IconButton(
            tooltip: isDark ? 'Light Mode' : 'Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? _kAppYellow : const Color(0xFF475569),
              size: 22,
            ),
            onPressed: () {
              context.read<ThemeProvider>().setThemeMode(
                isDark ? ThemeMode.light : ThemeMode.dark,
              );
            },
          ),
          if (!canPop)
            IconButton(
              key: const Key('appbar_dashboard_button'),
              tooltip: _isTagalog ? 'Dashboard' : 'Open Dashboard',
              icon: const Icon(Icons.dashboard_customize_outlined, size: 22),
              onPressed: () => _goToDashboard(context),
            ),
          const SizedBox(width: 8),
        ],
      ),

      // MOBILE SCROLLABLE BODY
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. ACCESSIBILITY PWD QUICK STRIP
              _buildAccessibilityStrip(context, isDark, textScale),
              const SizedBox(height: 14),

              // 2. MOBILE HERO BANNER (Complementary Blue & Yellow Motif)
              _buildMobileHero(context, isDark),
              const SizedBox(height: 16),

              // Section header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: Row(
                  children: [
                    Text(
                      _isTagalog ? 'Pangunahing Gamit' : 'Quick Actions',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _isTagalog ? 'Pumili ng paraan' : 'Select mode',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: subtextColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 3. CORE FUNCTION CARDS (SENYAS = BLUE, BOSES = YELLOW)
              _buildSenyasCard(context, isDark, cardBg, borderColor),
              const SizedBox(height: 14),
              _buildBosesCard(context, isDark, cardBg, borderColor),
              const SizedBox(height: 18),

              // 4. INTERACTIVE QUICK FSL PHRASES
              _buildQuickPhrasesCard(context, isDark, cardBg, borderColor),
              const SizedBox(height: 18),

              // 5. BOTTOM MOBILE DASHBOARD ENTRY
              _buildDashboardEntryButton(context, isDark),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // Language Pill Button
  Widget _buildLanguageButton({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: active ? _kAppBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: active ? Colors.white : const Color(0xFF64748B),
          ),
        ),
      ),
    );
  }

  // 1. Accessibility quick bar
  Widget _buildAccessibilityStrip(
    BuildContext context,
    bool isDark,
    double textScale,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141F36) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _kAppBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.text_fields_rounded, color: _kAppBlue, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isTagalog ? 'Laki ng Teksto' : 'Text Size Scale',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                Text(
                  '${(textScale * 100).toInt()}% • ${_isTagalog ? 'Madaling basahin' : 'Easy reading'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          // Decrement
          Material(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: textScale > 0.8 ? () => _adjustTextScale(context, -0.1) : null,
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.remove_rounded, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Increment
          Material(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: textScale < 1.4 ? () => _adjustTextScale(context, 0.1) : null,
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.add_rounded, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 2. Mobile Hero Banner with Complementary Contrast
  Widget _buildMobileHero(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF0E1A33), const Color(0xFF082269)]
              : [_kAppBlue, _kAppBlueDark],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: _kAppBlue.withValues(alpha: isDark ? 0.35 : 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Official Brand Logo Showcase
          Center(
            child: Image.asset(
              'assets/images/logo.png',
              height: 110,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 16),

          // Complementary badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _kAppYellow,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome_rounded, color: Color(0xFF111827), size: 13),
                const SizedBox(width: 5),
                Text(
                  _isTagalog ? 'KOMUNIKASYON PARA SA LAHAT' : 'INCLUSIVE COMMUNICATION',
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Headline
          Text(
            _isTagalog
                ? 'Tulay sa Pagitan ng\nBoses at Senyas'
                : 'Bridge Between\nVoice & Sign',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.2,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),

          // Subtitle
          Text(
            _isTagalog
                ? 'Mabilisang pagsasalin ng Filipino Sign Language sa salita at boses nang walang sagabal.'
                : 'Real-time Filipino Sign Language recognition and live speech subtitles in one mobile app.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.88),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),

          // Complementary Dual-Sphere Visual Indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildHeroFeatureItem(
                  icon: Icons.back_hand_rounded,
                  iconColor: Colors.white,
                  bgColor: _kAppBlue.withValues(alpha: 0.4),
                  title: _isTagalog ? 'Kamera AI' : 'Sign AI',
                  subtitle: 'FSL Recognition',
                ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _kAppYellow,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(Icons.sync_alt_rounded, color: Color(0xFF111827), size: 18),
                  ),
                ),
                _buildHeroFeatureItem(
                  icon: Icons.record_voice_over_rounded,
                  iconColor: const Color(0xFF111827),
                  bgColor: _kAppYellow,
                  title: _isTagalog ? 'Boses at Tunog' : 'Voice Subtitles',
                  subtitle: 'Live Speech',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroFeatureItem({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 3. Card A: SENYAS (Powered by Complementary Blue)
  Widget _buildSenyasCard(
    BuildContext context,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _kAppBlue.withValues(alpha: isDark ? 0.4 : 0.25),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _kAppBlue.withValues(alpha: isDark ? 0.12 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openSignToText(context),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _kAppBlue,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: _kAppBlue.withValues(alpha: 0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.videocam_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _kAppBlue.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _isTagalog ? 'PARA SA NAKIKIPAG-SENYAS' : 'FOR SIGNERS',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: _kAppBlue,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isTagalog ? 'Senyas ➔ Boses at Teksto' : 'Sign ➔ Voice & Text',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _isTagalog
                      ? 'Itutok ang kamera sa kamay. Isasalin ng on-device AI ang FSL gestures tungo sa malinaw na salita at pagsasalita.'
                      : 'Point camera at hand gestures. On-device AI recognizes Filipino Sign Language and speaks it aloud in real-time.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),

                // Mobile Button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAppBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.camera_alt_rounded, size: 20),
                    label: Text(
                      _isTagalog ? 'Buksan ang Senyas Kamera' : 'Open Sign Camera',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    onPressed: () => _openSignToText(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 3. Card B: BOSES (Powered by Complementary Sun Yellow)
  Widget _buildBosesCard(
    BuildContext context,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _kAppYellow.withValues(alpha: isDark ? 0.6 : 0.45),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _kAppYellow.withValues(alpha: isDark ? 0.12 : 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openSpeechToText(context),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _kAppYellow,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: _kAppYellow.withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.mic_rounded,
                        color: Color(0xFF111827),
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _kAppYellow.withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _isTagalog ? 'PARA SA NAGSASALITA' : 'FOR SPEAKERS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: isDark ? _kAppYellow : const Color(0xFFB45309),
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isTagalog ? 'Boses ➔ Malalaking Letra' : 'Speech ➔ Live Captions',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _isTagalog
                      ? 'Magsalita sa mikropono. Agad na ipapakita ang malalaking subtitles sa screen para sa kausap mong bingi.'
                      : 'Speak into your phone. Subtitles appear in high-contrast large font for deaf friends and family to read instantly.',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),

                // Mobile Button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAppYellow,
                      foregroundColor: const Color(0xFF111827),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.mic_rounded, size: 20),
                    label: Text(
                      _isTagalog ? 'Magsimulang Magsalita' : 'Start Speech to Text',
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                    ),
                    onPressed: () => _openSpeechToText(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 4. Interactive Quick FSL Phrases Reference
  Widget _buildQuickPhrasesCard(
    BuildContext context,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    final phrase = _samplePhrases[_selectedDemoIndex];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _kAppBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.menu_book_rounded, color: _kAppBlue, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isTagalog ? 'Mabilisang Gabay sa Senyas' : 'Quick Sign Reference',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                    Text(
                      _isTagalog ? 'Pindutin upang makita ang paraan' : 'Tap to see gesture guide',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Horizontal/Wrapping Interactive Chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_samplePhrases.length, (index) {
              final isSelected = _selectedDemoIndex == index;
              final p = _samplePhrases[index];
              return InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  setState(() {
                    _selectedDemoIndex = index;
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? _kAppBlue
                        : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isSelected
                          ? _kAppBlue
                          : (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        p.icon,
                        size: 14,
                        color: isSelected
                            ? _kAppYellow
                            : (isDark ? Colors.white70 : const Color(0xFF475569)),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        p.tagalog,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : (isDark ? Colors.white : const Color(0xFF1E293B)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 14),

          // Detailed gesture instruction box
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _kAppBlue.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _kAppYellow.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(phrase.icon, color: _kAppYellowDark, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            phrase.tagalog,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '(${phrase.english})',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        phrase.fsl,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: isDark ? Colors.white70 : const Color(0xFF334155),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 5. Mobile Bottom Dashboard Action
  Widget _buildDashboardEntryButton(BuildContext context, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141F36) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: const Key('enter_dashboard_button'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => _goToDashboard(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.dashboard_rounded, color: _kAppBlue, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isTagalog ? 'Pumunta sa Dashboard' : 'Open Full Dashboard',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                      Text(
                        _isTagalog ? 'History, Diksyunaryo, at Settings' : 'History, dictionary & settings',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _kAppBlue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
