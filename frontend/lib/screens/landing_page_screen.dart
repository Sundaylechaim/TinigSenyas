import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../providers/theme_provider.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connectivity_badge.dart';
import 'sign_to_text_screen.dart';
import 'speech_to_text_screen.dart';
import 'text_to_sign_screen.dart';

const Color _kAppBlue = AppTheme.kPrimaryBlue;
const Color _kAppBlueDark = AppTheme.kDeepBlue;
const Color _kAppYellow = AppTheme.kSunYellow;
const Color _kAppYellowDark = AppTheme.kSunYellowDark;

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
      fsl:
          'Hawakan ang dibdib at dahan-dahang itaas ang kamay na may kasamang ngiti.',
      icon: Icons.waving_hand_rounded,
    ),
    DemoPhrase(
      tagalog: 'Salamat!',
      english: 'Thank you!',
      fsl:
          'Ipatong ang mga daliri ng kanang kamay sa labi at iunat ito pasulong.',
      icon: Icons.volunteer_activism_rounded,
    ),
    DemoPhrase(
      tagalog: 'Mahal kita',
      english: 'I love you',
      fsl:
          'I-angat ang hinlalaki, hintuturo, at kalingkingan nang magkasabay (ILY sign).',
      icon: Icons.favorite_rounded,
    ),
    DemoPhrase(
      tagalog: 'Tulong po',
      english: 'Need help',
      fsl:
          'Ipatong ang nakasarang kamao na may hinlalaking nakataas sa kabilang palad.',
      icon: Icons.help_outline_rounded,
    ),
    DemoPhrase(
      tagalog: 'Magandang araw',
      english: 'Good day',
      fsl:
          'Ilagay ang kamay sa bibig at iunat pasulong, sabay iunat ang palad pataas.',
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SignToTextScreen()));
  }

  void _openSpeechToText(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SpeechToTextScreen()));
  }

  void _openTextToSign(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TextToSignScreen()));
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
    final settings = context.watch<SettingsService>();
    final textScale = settings.textScaleFactor;
    final canPop = Navigator.of(context).canPop();

    final bgColor = isDark ? const Color(0xFF090E1A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF131D31) : Colors.white;
    final borderColor = isDark
        ? const Color(0xFF223253)
        : const Color(0xFFE2E8F0);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF090E1A) : Colors.white,
        centerTitle: false,
        leading: canPop
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                tooltip: _isTagalog ? 'Bumalik' : 'Back',
                onPressed: () => Navigator.of(context).pop(),
              )
            : Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Image.asset(
                  'assets/images/logo.png',
                  height: 30,
                  fit: BoxFit.contain,
                ),
              ),
        titleSpacing: canPop ? 0 : 10,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'TinigSenyas',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 18,
                letterSpacing: -0.4,
                color: _kAppBlue,
              ),
            ),
            Text(
              _isTagalog
                  ? 'Tulay sa Filipino Sign Language'
                  : 'Filipino Sign Language Bridge',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: subtextColor,
              ),
            ),
          ],
        ),
        actions: [
          const ConnectivityBadge(),
          const SizedBox(width: 8),

          // FIL / EN Language Switcher
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLanguageButton('FIL', _isTagalog, () {
                  setState(() => _isTagalog = true);
                }),
                _buildLanguageButton('EN', !_isTagalog, () {
                  setState(() => _isTagalog = false);
                }),
              ],
            ),
          ),
          const SizedBox(width: 4),

          // Theme toggle
          IconButton(
            tooltip: isDark ? 'Light Mode' : 'Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? _kAppYellow : const Color(0xFF475569),
              size: 20,
            ),
            onPressed: () {
              context.read<ThemeProvider>().setThemeMode(
                isDark ? ThemeMode.light : ThemeMode.dark,
              );
            },
          ),

          // Dashboard button in AppBar
          if (!canPop)
            IconButton(
              key: const Key('appbar_dashboard_button'),
              tooltip: _isTagalog ? 'Dashboard' : 'Open Dashboard',
              icon: const Icon(Icons.dashboard_rounded, size: 22),
              color: _kAppBlue,
              onPressed: () => _goToDashboard(context),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Clean, Friendly Hero Banner
              _buildHeroCard(context, isDark),
              const SizedBox(height: 20),

              // 2. Section Header
              Text(
                _isTagalog ? 'Pangunahing Gamit' : 'Main Features',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 10),

              // 3. Simple Action Cards
              _buildActionCard(
                context: context,
                isDark: isDark,
                cardBg: cardBg,
                borderColor: borderColor,
                icon: Icons.videocam_rounded,
                iconColor: Colors.white,
                iconBgColor: _kAppBlue,
                title: _isTagalog
                    ? 'Senyas ➔ Salita at Boses'
                    : 'Sign to Voice & Text',
                subtitle: _isTagalog
                    ? 'Gamitin ang camera upang isalin ang FSL senyas sa boses at teksto.'
                    : 'Point your camera to translate FSL hand signs into spoken words.',
                badge: _isTagalog ? 'CAMERA AI' : 'CAMERA AI',
                badgeColor: _kAppBlue,
                onTap: () => _openSignToText(context),
              ),
              const SizedBox(height: 12),

              _buildActionCard(
                context: context,
                isDark: isDark,
                cardBg: cardBg,
                borderColor: borderColor,
                icon: Icons.mic_rounded,
                iconColor: const Color(0xFF111827),
                iconBgColor: _kAppYellow,
                title: _isTagalog
                    ? 'Boses ➔ Malalaking Letra'
                    : 'Speech to Live Captions',
                subtitle: _isTagalog
                    ? 'Magsalita para makabuo ng malalaking subtitles na madaling basahin.'
                    : 'Speak into your phone to display clear, high-contrast captions.',
                badge: _isTagalog ? 'SPEECH AI' : 'SPEECH AI',
                badgeColor: _kAppYellowDark,
                onTap: () => _openSpeechToText(context),
              ),
              const SizedBox(height: 12),

              _buildActionCard(
                context: context,
                isDark: isDark,
                cardBg: cardBg,
                borderColor: borderColor,
                icon: Icons.menu_book_rounded,
                iconColor: Colors.white,
                iconBgColor: const Color(0xFF0D9488),
                title: _isTagalog
                    ? 'Diksyunaryo ng Senyas'
                    : 'Sign Language Dictionary',
                subtitle: _isTagalog
                    ? 'Maghanap ng mga salita at tingnan ang tamang paraan ng pag-senyas.'
                    : 'Search words and learn how to perform FSL gestures with guides.',
                badge: _isTagalog ? 'DIKSYUNARYO' : 'DICTIONARY',
                badgeColor: const Color(0xFF0D9488),
                onTap: () => _openTextToSign(context),
              ),
              const SizedBox(height: 20),

              // 4. Quick Phrases Reference
              _buildQuickPhrases(context, isDark, cardBg, borderColor),
              const SizedBox(height: 16),

              // 5. Dashboard Action Button
              _buildDashboardButton(context, isDark),
              const SizedBox(height: 16),

              // 6. Subtle Accessibility Text Scaler
              _buildAccessibilityBar(context, isDark, textScale),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageButton(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? _kAppBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : const Color(0xFF64748B),
          ),
        ),
      ),
    );
  }

  // Hero Card
  Widget _buildHeroCard(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF14244A), const Color(0xFF0F1B38)]
              : [_kAppBlue, _kAppBlueDark],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _kAppBlue.withValues(alpha: isDark ? 0.3 : 0.2),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/images/logo.png',
                height: 44,
                fit: BoxFit.contain,
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kAppYellow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.accessibility_new_rounded,
                      color: Color(0xFF111827),
                      size: 13,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isTagalog ? 'INKLUSIBO' : 'ACCESSIBLE',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _isTagalog
                ? 'Tulay sa Pagitan ng\nBoses at Senyas'
                : 'Bridging Voice\nand Filipino Sign',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.25,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isTagalog
                ? 'Madaling komunikasyon para sa komunidad ng Bingi at Nagsasalita.'
                : 'Simple, direct communication for the Deaf and Hearing communities.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('enter_dashboard_button'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAppYellow,
                foregroundColor: const Color(0xFF111827),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(
                _isTagalog ? 'Buksan ang Dashboard' : 'Open Dashboard',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              onPressed: () => _goToDashboard(context),
            ),
          ),
        ],
      ),
    );
  }

  // Simple Action Card
  Widget _buildActionCard({
    required BuildContext context,
    required bool isDark,
    required Color cardBg,
    required Color borderColor,
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String title,
    required String subtitle,
    required String badge,
    required Color badgeColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: badgeColor,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFF94A3B8),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Quick Phrases Reference
  Widget _buildQuickPhrases(
    BuildContext context,
    bool isDark,
    Color cardBg,
    Color borderColor,
  ) {
    final phrase = _samplePhrases[_selectedDemoIndex];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tips_and_updates_rounded, color: _kAppYellowDark, size: 18),
              const SizedBox(width: 8),
              Text(
                _isTagalog ? 'Mabilisang Gabay sa Senyas' : 'Quick FSL Phrases',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Horizontal scrollable phrase pills
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: List.generate(_samplePhrases.length, (index) {
                final isSelected = _selectedDemoIndex == index;
                final p = _samplePhrases[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(p.tagalog),
                    selected: isSelected,
                    selectedColor: _kAppBlue,
                    backgroundColor: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFF1F5F9),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected
                          ? Colors.white
                          : (isDark ? Colors.white70 : const Color(0xFF334155)),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: BorderSide(
                      color: isSelected ? _kAppBlue : borderColor,
                    ),
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedDemoIndex = index);
                      }
                    },
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),

          // Selected phrase details
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _kAppYellow.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(phrase.icon, color: _kAppYellowDark, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${phrase.tagalog} • ${phrase.english}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        phrase.fsl,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: isDark ? Colors.white70 : const Color(0xFF475569),
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

  // Dashboard Button
  Widget _buildDashboardButton(BuildContext context, bool isDark) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: _kAppBlue,
        side: const BorderSide(color: _kAppBlue, width: 1.2),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      icon: const Icon(Icons.dashboard_customize_outlined, size: 20),
      label: Text(
        _isTagalog
            ? 'Lahat ng Gamit (Dashboard)'
            : 'View All Features (Dashboard)',
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
      onPressed: () => _goToDashboard(context),
    );
  }

  // Accessibility text scaler bar
  Widget _buildAccessibilityBar(
    BuildContext context,
    bool isDark,
    double textScale,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131D31) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.format_size_rounded,
            size: 18,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          Text(
            _isTagalog ? 'Laki ng Teksto:' : 'Text Size:',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${(textScale * 100).toInt()}%',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: _kAppBlue,
            ),
          ),
          const Spacer(),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
            tooltip: _isTagalog ? 'Paliitin' : 'Decrease',
            onPressed: textScale > 0.8
                ? () => _adjustTextScale(context, -0.1)
                : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
            tooltip: _isTagalog ? 'Palakihin' : 'Increase',
            onPressed: textScale < 1.4
                ? () => _adjustTextScale(context, 0.1)
                : null,
          ),
        ],
      ),
    );
  }
}
