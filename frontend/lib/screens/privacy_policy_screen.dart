import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy & Legal Terms'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            'TinigSenyas Privacy Policy & Compliance Notice',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Last Updated: October 31, 2026',
            style: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[600], fontSize: 13),
          ),
          const Divider(height: 24),

          _buildSectionHeader(Icons.child_care_rounded, '1. Children\'s Privacy (COPPA Compliance)'),
          _buildParagraph(
            'TinigSenyas is strictly NOT intended for, directed to, or designed for children under '
            '13 years of age. We do not knowingly collect, solicit, or maintain personal data, voice recordings, '
            'video feeds, or biometric identifiers from children under 13 in compliance with the '
            'Children\'s Online Privacy Protection Act (COPPA, 15 U.S.C. §§ 6501–6506).\n\n'
            'An age verification gate is enforced before accessing camera-based gesture recognition '
            'or speech-to-text recording features. If we learn that a user is under 13 years old, '
            'access to recording features is immediately restricted and any associated data stored '
            'will be deleted.'
          ),

          _buildSectionHeader(Icons.security_rounded, '2. Third-Party Data & GDPR Disclosures'),
          _buildParagraph(
            'In compliance with the General Data Protection Regulation (GDPR) and international privacy frameworks:\n'
            '• Local First & Self-Hosted: TinigSenyas operates primarily offline. Core FSL recognition and '
            'speech dictionary lookups occur on your local device.\n'
            '• External Requests: The application does NOT use third-party analytics trackers, session replays, '
            'or advertising pixels. All visual assets and fonts are self-hosted.\n'
            '• Optional Cloud TTS: When online Filipino speech synthesis is selected, translation text is '
            'transmitted to the configured backend speech synthesizer (e.g. Edge TTS / Azure Speech) '
            'strictly for immediate audio conversion and is not permanently stored by third-party servers.'
          ),

          _buildSectionHeader(Icons.mic_none_rounded, '3. Recording & Audio/Visual Privacy (CIPA Compliance)'),
          _buildParagraph(
            'Under the California Invasion of Privacy Act (CIPA, Cal. Penal Code § 631 & § 632) and wiretapping laws:\n'
            '• Camera Visual Analysis: Live video stream frames are processed in real-time solely to extract '
            'hand landmarks for Filipino Sign Language translation. Raw video frames are not saved or uploaded '
            'unless the user explicitly configures a remote server.\n'
            '• Microphone Speech Recognition: Audio from your microphone is processed strictly during active '
            'dictation sessions with affirmative user consent.\n'
            '• Conversation History: Translations are stored locally on your device\'s SQLite database. You may '
            'disable history logging at any time in Settings (Private Mode) or clear your history permanently.'
          ),

          _buildSectionHeader(Icons.mail_outline_rounded, '4. Marketing Communications (CAN-SPAM Act)'),
          _buildParagraph(
            'TinigSenyas does not send unsolicited commercial emails. If you opt in to receive release announcements '
            'or updates, every email will contain:\n'
            '• A clear, non-deceptive sender identity ("From: TinigSenyas Team").\n'
            '• A physical postal mailing address (2034 Zamora Street, Brgy. 782, Sta. Ana, Manila, Philippines).\n'
            '• A working, one-click unsubscribe mechanism. Opt-out requests are processed immediately and '
            'honored within 10 business days as required by 15 U.S.C. § 7704.'
          ),

          _buildSectionHeader(Icons.autorenew_rounded, '5. Subscriptions & Billing (California ARL)'),
          _buildParagraph(
            'TinigSenyas is currently provided 100% free of charge for KAINAKAP community members and general users.\n'
            'Should any paid subscription, auto-renewing plan, or paid add-on feature be offered in the future, '
            'we strictly adhere to the California Automatic Renewal Law (Cal. Bus. & Prof. Code §§ 17600–17606):\n'
            '• All fees, billing intervals, and "renews until cancelled" terms will be clearly presented in immediate '
            'visual proximity to the pay button.\n'
            '• Express affirmative consent is required before charging.\n'
            '• A confirmation receipt with clear cancellation instructions will be sent promptly via email.\n'
            '• Online, frictionless one-click cancellation will be available inside the app settings.'
          ),

          _buildSectionHeader(Icons.copyright_rounded, '6. Copyright & User Content (DMCA Safe Harbor)'),
          _buildParagraph(
            'We respect intellectual property rights and adhere to the Digital Millennium Copyright Act (17 U.S.C. § 512).\n'
            'If you believe that any content, vocabulary gesture, or model asset infringes upon your copyright, '
            'you may submit a formal takedown notice to our designated Copyright Agent at:\n'
            'Email: dmca@tinigsenyas.org\n'
            'TinigSenyas maintains a strict repeat infringer termination policy.'
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF0138FF)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParagraph(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, height: 1.5),
      ),
    );
  }
}

