import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

const Color _kAppBlue = Color(0xFF2D5FB8);
const String _kAlphabetVideoUrl = 'https://www.youtube.com/watch?v=TiBzKFHvZRg';
const String _kAlphabetChartUrl =
    'https://eccdcouncil.gov.ph/wp-content/uploads/2024/10/Guidebook-on-Inclusion-V14_F.pdf';
const String _kGreetingsSourceUrl =
    'https://sites.google.com/depedmanila.net/pangkat1/fsl-filipino-sign-language/tarat-matuto-mag-fsl/mga-pagbati';
const String _kFslLanguageSourceUrl =
    'https://elibrary.judiciary.gov.ph/thebookshelf/showdocs/2/96594';

void showFslGuideSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return DraggableScrollableSheet(
        initialChildSize: 0.80,
        maxChildSize: 0.95,
        minChildSize: 0.50,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0E1626).withValues(alpha: 0.98)
                    : Colors.white.withValues(alpha: 0.98),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: DefaultTabController(
                length: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(
                          Icons.menu_book_rounded,
                          color: _kAppBlue,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'FSL Reference & Guide',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Close guide',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TabBar(
                      indicatorColor: _kAppBlue,
                      indicatorWeight: 3,
                      labelColor: _kAppBlue,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      unselectedLabelColor: isDark
                          ? Colors.white60
                          : const Color(0xFF64748B),
                      labelStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                      tabs: const [
                        Tab(text: 'Conversational'),
                        Tab(text: 'Medical & Health'),
                        Tab(text: 'Alphabet A–Z'),
                        Tab(text: 'Accuracy Tips'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // 1. Conversational phrases documented in the
                          // DepEd Manila Senyas-Salin greeting lesson.
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'English explanations are provided for ASL-first readers. FSL and ASL are distinct sign languages, so an English translation does not make the signs interchangeable. These phrase examples are documented by DepEd Manila; follow the linked FSL lesson for handshape, movement, facial expression, and regional variation.',
                                  style: TextStyle(fontSize: 13, height: 1.4),
                                ),
                              ),
                              FslGuideItem(
                                'HOW ARE YOU? · KUMUSTA KA?',
                                'Senyas-Salin gloss: KUMUSTA (HELLO) – IKAW (YOU)',
                              ),
                              FslGuideItem(
                                'WHAT IS YOUR NAME? · ANONG PANGALAN MO?',
                                'Senyas-Salin gloss: IKAW (YOU) – PANGALAN (NAME) – ANO (WHAT)',
                              ),
                              FslGuideItem(
                                'YES / NO · OO / HINDI',
                                'Both signs are shown in the Senyas-Salin “Oo at Hindi” lesson.',
                              ),
                              FslGuideItem(
                                'GOOD DAY! · MAGANDANG ARAW!',
                                'Senyas-Salin gloss: MAGANDANG (GOOD) – ARAW (DAY)',
                              ),
                              FslGuideItem(
                                'GOOD MORNING / NOON / AFTERNOON / EVENING · MAGANDANG UMAGA / TANGHALI / HAPON / GABI',
                                'These greetings are included in the Senyas-Salin lesson.',
                              ),
                              SizedBox(height: 8),
                              FslGuideSourceCard(
                                title:
                                    'Supreme Court E-Library · FSL and ASL distinction (RA 11106 IRR)',
                                url: _kFslLanguageSourceUrl,
                              ),
                              FslGuideSourceCard(
                                title:
                                    'DepEd Manila · Senyas-Salin: Mga Pagbati',
                                url: _kGreetingsSourceUrl,
                              ),
                            ],
                          ),

                          // 2. Medical & Health Signs
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideItem(
                                'DOCTOR · DOKTOR',
                                'Fingertips of curved hand tap dominant wrist radial artery (checking pulse)',
                              ),
                              FslGuideItem(
                                'NURSE',
                                'N-handshape (two fingers over thumb) taps inner wrist twice gently',
                              ),
                              FslGuideItem(
                                'MEDICINE · GAMOT',
                                'Middle finger of dominant hand stirs in open palm of non-dominant hand (mortar & pestle)',
                              ),
                              FslGuideItem(
                                'PAIN · SAKIT / MASAKIT',
                                'Two index fingers point toward each other and twist back and forth at pain area',
                              ),
                              FslGuideItem(
                                'HEADACHE · MASAKIT ANG ULO',
                                'Index finger pain sign held near temples with tense expression',
                              ),
                              FslGuideItem(
                                'FEVER · LAGNAT',
                                'Back of dominant hand rests against forehead checking body temperature',
                              ),
                              FslGuideItem(
                                'RUNNY NOSE · SIPON',
                                'Pinched index and thumb wipe down from nostrils mimicking runny nose',
                              ),
                              FslGuideItem(
                                'SNEEZING · BAHING',
                                'Index finger rests under nose then head jerks forward mimicking sneeze',
                              ),
                              FslGuideItem(
                                'BREATHING · PAGHINGA',
                                'Both open palms move toward and away from chest rhythmically',
                              ),
                              FslGuideItem(
                                'DIFFICULTY BREATHING · NAHIHIRAPAN HUMINGA',
                                'Both hands claw over chest with distressed facial expression',
                              ),
                              FslGuideItem(
                                'DIZZINESS · NAHIHILO',
                                'Curved fingers circle clockwise around head while tilting slightly',
                              ),
                              FslGuideItem(
                                'TIRED · PAGOD',
                                'Fingertips on chest drop downward as wrists slump forward',
                              ),
                              FslGuideItem(
                                'BLEEDING · DUMUDUGO',
                                'Fingertips flutter downward from injured spot mimicking dripping blood',
                              ),
                              FslGuideItem(
                                'SWELLING · PAMAMAGA',
                                'Curved hands start small and expand outward indicating swelling',
                              ),
                              FslGuideItem(
                                'BLOOD PRESSURE · TENSIYON',
                                'Dominant hand wraps around upper arm pumping blood pressure cuff',
                              ),
                              FslGuideItem(
                                'ANXIETY / DEPRESSION · ANXIETY / DEPRESYON',
                                'Flat hands slide down chest slowly with a sighing expression',
                              ),
                              FslGuideItem(
                                'ALLERGY · ALLERGIC',
                                'Index finger scratches forearm upward then signs Sakit/Reaction',
                              ),
                            ],
                          ),

                          // 3. Alphabet references. Avoid describing hand
                          // poses here: orientation and motion are visual and
                          // the FSL letterforms can differ from ASL.
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideItem(
                                'A–Z + Ñ + NG',
                                'The Filipino alphabet has 28 letters. Use the visual FSL references below for the demonstrated handshapes and any movement; this guide does not invent pose instructions.',
                              ),
                              SizedBox(height: 8),
                              FslGuideSourceCard(
                                title:
                                    'KonsultaKamay · FSL alphabet video (includes Ñ and NG)',
                                url: _kAlphabetVideoUrl,
                              ),
                              FslGuideSourceCard(
                                title:
                                    'ECCD Council · FSL alphabet chart (A–Z)',
                                url: _kAlphabetChartUrl,
                              ),
                              Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  'The chart is a still reference for A–Z. Ñ and NG are shown in the KonsultaKamay lesson. The app currently has no verified alphabet animation clips; the recognition model predicts labels but does not generate signing motion.',
                                  style: TextStyle(fontSize: 13, height: 1.4),
                                ),
                              ),
                            ],
                          ),

                          // 4. Accuracy Tips Tab
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideTipCard(
                                icon: Icons.light_mode_rounded,
                                title: 'Good, Even Lighting',
                                description:
                                    'Face a light source or window so your hands and face have clear contrast without heavy backlighting or shadows.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.straighten_rounded,
                                title: 'Optimal Distance (0.5m – 1.0m)',
                                description:
                                    'Position your phone on a stand or desk at chest level so your head, shoulders, and both hands remain in frame.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.pan_tool_outlined,
                                title: 'Natural Rest to Pause',
                                description:
                                    'Lower your hands to your lap or sides to pause recognition while thinking. Raise them back into the signing space to resume seamlessly.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.toggle_on_rounded,
                                title: 'Mode Selection for High Precision',
                                description:
                                    'Tap "Mode" on Sign-to-Text to switch to "A–Z" for fingerspelling, "Known phrases" to classify one trained sign or expression per gesture, or "Medical" for health signs. Continuous sentence translation is not available yet.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.speed_rounded,
                                title: 'Deliberate Pacing',
                                description:
                                    'Hold each static letter for about 1 second to confirm detection before transitioning to the next letter.',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class FslGuideItem extends StatelessWidget {
  final String sign;
  final String description;

  const FslGuideItem(this.sign, this.description, {super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final signLabel = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _kAppBlue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        sign,
        softWrap: true,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 12,
          color: _kAppBlue,
        ),
      ),
    );
    final descriptionText = Text(
      description,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white70 : const Color(0xFF334155),
        height: 1.4,
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162138) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF233352) : const Color(0xFFE2E8F0),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: signLabel,
                ),
                const SizedBox(height: 10),
                descriptionText,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              signLabel,
              const SizedBox(width: 14),
              Expanded(child: descriptionText),
            ],
          );
        },
      ),
    );
  }
}

class FslGuideSourceCard extends StatelessWidget {
  final String title;
  final String url;

  const FslGuideSourceCard({super.key, required this.title, required this.url});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162138) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF233352) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          SelectableText(
            url,
            style: const TextStyle(color: _kAppBlue, fontSize: 12),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(
                onPressed: () async {
                  await SharePlus.instance.share(
                    ShareParams(uri: Uri.parse(url)),
                  );
                },
                child: const Text('Share source'),
              ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Source link copied')),
                  );
                },
                child: const Text('Copy link'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class FslGuideTipCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const FslGuideTipCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162138) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF233352) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _kAppBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: _kAppBlue, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
