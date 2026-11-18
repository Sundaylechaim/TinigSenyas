import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../providers/theme_provider.dart';
import '../theme/app_theme.dart';
import 'sign_to_text_screen.dart';
import 'speech_to_text_screen.dart';
import 'text_to_sign_screen.dart';

const Color _kAppBlue = AppTheme.kPrimaryBlue;
const Color _kAppBlueDark = AppTheme.kDeepBlue;
const Color _kAppYellow = AppTheme.kSunYellow;
const Color _kAppTeal = Color(0xFF0D9488);

class LandingPageScreen extends StatefulWidget {
  const LandingPageScreen({super.key});

  @override
  State<LandingPageScreen> createState() => _LandingPageScreenState();
}

class _LandingPageScreenState extends State<LandingPageScreen> {
  bool _isTagalog = true;

  void _openAllTools(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
    );
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

  void _openFslDictionary(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TextToSignScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final canPop = Navigator.of(context).canPop();
    final compactHeader = MediaQuery.sizeOf(context).width < 380;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF090E1A)
          : const Color(0xFFF8FAFC),
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark
            ? const Color(0xFF090E1A)
            : const Color(0xFFF8FAFC),
        leading: canPop
            ? IconButton(
                tooltip: _isTagalog ? 'Bumalik' : 'Back',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        titleSpacing: canPop ? 0 : 20,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compactHeader) ...[
              Image.asset(
                'assets/images/logo.png',
                width: 30,
                height: 30,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 8),
            ],
            const Text(
              'TinigSenyas',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                letterSpacing: -0.4,
                color: _kAppBlue,
              ),
            ),
          ],
        ),
        actions: [
          _buildLanguageSwitcher(),
          const SizedBox(width: 2),
          IconButton(
            tooltip: isDark ? 'Light mode' : 'Dark mode',
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
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
              children: [
                _buildHero(context),
                const SizedBox(height: 30),
                Text(
                  _isTagalog ? 'Pumili ng paraan' : 'Choose how to connect',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isTagalog
                      ? 'Mga simpleng gamit para sa pang-araw-araw na usapan.'
                      : 'Simple tools for everyday conversations.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                _buildFeatureCard(
                  context: context,
                  isDark: isDark,
                  icon: Icons.sign_language_rounded,
                  iconColor: _kAppBlue,
                  iconBackground: isDark
                      ? const Color(0xFF1D3156)
                      : const Color(0xFFE8EEFF),
                  title: _isTagalog
                      ? 'Senyas sa teksto at boses'
                      : 'Sign to text and voice',
                  description: _isTagalog
                      ? 'I-senyas ang mga salitang kinikilala ng app at ibahagi ang resulta.'
                      : 'Sign supported FSL words and share the result as text or speech.',
                  onTap: () => _openSignToText(context),
                  isPrimary: true,
                ),
                const SizedBox(height: 12),
                _buildFeatureCard(
                  context: context,
                  isDark: isDark,
                  icon: Icons.mic_rounded,
                  iconColor: const Color(0xFF8A6200),
                  iconBackground: isDark
                      ? const Color(0xFF3B321B)
                      : const Color(0xFFFFF4CC),
                  title: _isTagalog
                      ? 'Boses sa live caption'
                      : 'Speech to live captions',
                  description: _isTagalog
                      ? 'Ipakita sa screen ang sinasabi bilang malinaw na teksto.'
                      : 'Turn spoken words into clear, live captions.',
                  onTap: () => _openSpeechToText(context),
                ),
                const SizedBox(height: 12),
                _buildFeatureCard(
                  context: context,
                  isDark: isDark,
                  icon: Icons.menu_book_rounded,
                  iconColor: _kAppTeal,
                  iconBackground: isDark
                      ? const Color(0xFF163631)
                      : const Color(0xFFE1F5F1),
                  title: _isTagalog
                      ? 'Mag-type ng mensahe'
                      : 'Type & speak a message',
                  description: _isTagalog
                      ? 'Ipa-boses ang mensahe o tingnan ang mga senyas na nasa gabay.'
                      : 'Speak any typed message or preview available FSL sign clips.',
                  onTap: () => _openFslDictionary(context),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    _isTagalog
                        ? 'Dinisenyo para sa pang-araw-araw na komunikasyon sa FSL.'
                        : 'Made for everyday communication in Filipino Sign Language.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageSwitcher() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFEFF2F7),
        borderRadius: BorderRadius.circular(14),
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
    );
  }

  Widget _buildLanguageButton(String label, bool active, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: active,
      label: label == 'FIL' ? 'Filipino' : 'English',
      child: Material(
        color: active
            ? _kAppBlue
            : (isDark ? const Color(0xFF1E293B) : Colors.transparent),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                color: active
                    ? Colors.white
                    : (isDark ? Colors.white70 : const Color(0xFF64748B)),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final constraints = MediaQuery.sizeOf(context).width;
    final compact = constraints < 560;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF14244A), const Color(0xFF0F1B38)]
              : [_kAppBlue, _kAppBlueDark],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: _kAppBlue.withValues(alpha: isDark ? 0.22 : 0.16),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.sign_language_rounded,
                  color: _kAppYellow,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  'FILIPINO SIGN LANGUAGE',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.94),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.55,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _isTagalog
                ? 'Mas madaling magkaintindihan.'
                : 'A clearer way to connect.',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 31,
              height: 1.12,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.75,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isTagalog
                ? 'Pag-isahin ang Filipino Sign Language, boses, at teksto para sa pang-araw-araw na usapan.'
                : 'Bring Filipino Sign Language, speech, and text together for everyday conversations.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          if (compact)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPrimaryHeroButton(context),
                const SizedBox(height: 8),
                _buildSecondaryHeroButton(context),
              ],
            )
          else
            Row(
              children: [
                _buildPrimaryHeroButton(context),
                const SizedBox(width: 10),
                _buildSecondaryHeroButton(context),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildPrimaryHeroButton(BuildContext context) {
    return FilledButton.icon(
      key: const Key('landing_start_signing_button'),
      style: FilledButton.styleFrom(
        backgroundColor: _kAppYellow,
        foregroundColor: const Color(0xFF172033),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      icon: const Icon(Icons.back_hand_rounded, size: 18),
      label: Text(
        _isTagalog ? 'Subukan ang senyas' : 'Start with signing',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      onPressed: () => _openSignToText(context),
    );
  }

  Widget _buildSecondaryHeroButton(BuildContext context) {
    return OutlinedButton.icon(
      key: const Key('landing_explore_tools_button'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      icon: const Icon(Icons.grid_view_rounded, size: 18),
      label: Text(
        _isTagalog ? 'Tingnan ang mga gamit' : 'Explore all tools',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      onPressed: () => _openAllTools(context),
    );
  }

  Widget _buildFeatureCard({
    required BuildContext context,
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required Color iconBackground,
    required String title,
    required String description,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    final theme = Theme.of(context);
    final borderColor = isPrimary
        ? _kAppBlue.withValues(alpha: isDark ? 0.65 : 0.35)
        : (isDark ? const Color(0xFF223253) : const Color(0xFFE2E8F0));

    return Material(
      color: isDark ? const Color(0xFF131D31) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: isPrimary ? 1.3 : 1),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                color: isPrimary
                    ? _kAppBlue
                    : theme.colorScheme.onSurfaceVariant,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
