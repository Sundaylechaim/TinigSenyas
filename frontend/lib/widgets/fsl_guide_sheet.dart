import 'dart:ui';
import 'package:flutter/material.dart';

const Color _kAppBlue = Color(0xFF0138FF);

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
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
                        const Icon(Icons.menu_book_rounded, color: _kAppBlue, size: 22),
                        const SizedBox(width: 8),
                        const Text(
                          'FSL Reference & Guide',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
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
                      unselectedLabelColor: isDark ? Colors.white60 : const Color(0xFF64748B),
                      labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
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
                          // 1. Conversational Phrases
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideItem('KAMUSTA', 'Friendly open-palm wave at cheek/shoulder level with palm facing forward'),
                              FslGuideItem('KAMUSTA KA', 'Curved hands with palms up rotate outward toward conversation partner'),
                              FslGuideItem('MABUTI', 'Fingertips of dominant flat hand touch chin and move forward and down'),
                              FslGuideItem('SALAMAT', 'Flat open hand touches chin/lips then extends gracefully toward receiver'),
                              FslGuideItem('WALANG ANUMAN', 'Open flat palm sweeps inward toward chest with a welcoming nod'),
                              FslGuideItem('MAGANDANG UMAGA', 'Sign Mabuti (chin forward) then dominant hand rises upward like rising sun'),
                              FslGuideItem('MAGANDANG HAPON', 'Sign Mabuti then dominant hand tilts downward at 45° angle over arm'),
                              FslGuideItem('MAGANDANG GABI', 'Sign Mabuti then curved hand covers non-dominant wrist like sunset'),
                              FslGuideItem('IKINAGAGALAK KITANG MAKILALA', 'Index fingers of both hands approach each other at chest level'),
                              FslGuideItem('MAGKITA TAYO BUKAS', 'V-handshape points from eyes outward, then thumb flicks forward at cheek'),
                              FslGuideItem('OO', 'Closed fist nods up and down at chest height mimicking a nodding head'),
                              FslGuideItem('HINDI', 'Index and middle finger extended together snap sharply to meet the thumb'),
                              FslGuideItem('TAMA', 'Dominant index finger edge drops firmly across top of non-dominant index finger'),
                              FslGuideItem('MALI', 'Y-handshape (thumb and pinky extended) touches the center of the chin'),
                              FslGuideItem('ALAM', 'Fingertips of flat hand tap temple/forehead once with confident nod'),
                              FslGuideItem('HINDI ALAM', 'Fingertips touch temple then twist sharply outward with head shake'),
                              FslGuideItem('NAIINTINDIHAN', 'Index finger flicks upward from thumb near temple like a light bulb'),
                              FslGuideItem('HINDI MAINTINDIHAN', 'Index flick near temple accompanied by furrowed brow and head shake'),
                              FslGuideItem('BINGI', 'Index finger touches ear then moves forward to touch near the mouth'),
                              FslGuideItem('MAHIRAP MAKARINIG', 'H-handshape taps downward once then twice indicating partial hearing'),
                            ],
                          ),

                          // 2. Medical & Health Signs
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideItem('DOKTOR', 'Fingertips of curved hand tap dominant wrist radial artery (checking pulse)'),
                              FslGuideItem('NURSE', 'N-handshape (two fingers over thumb) taps inner wrist twice gently'),
                              FslGuideItem('GAMOT', 'Middle finger of dominant hand stirs in open palm of non-dominant hand (mortar & pestle)'),
                              FslGuideItem('SAKIT / MASAKIT', 'Two index fingers point toward each other and twist back and forth at pain area'),
                              FslGuideItem('MASAKIT ANG ULO', 'Index finger pain sign held near temples with tense expression'),
                              FslGuideItem('LAGNAT', 'Back of dominant hand rests against forehead checking body temperature'),
                              FslGuideItem('SIPON', 'Pinched index and thumb wipe down from nostrils mimicking runny nose'),
                              FslGuideItem('BAHING', 'Index finger rests under nose then head jerks forward mimicking sneeze'),
                              FslGuideItem('PAGHINGA', 'Both open palms move toward and away from chest rhythmically'),
                              FslGuideItem('NAHIHIRAPAN HUMINGA', 'Both hands claw over chest with distressed facial expression'),
                              FslGuideItem('NAHIHILO', 'Curved fingers circle clockwise around head while tilting slightly'),
                              FslGuideItem('PAGOD', 'Fingertips on chest drop downward as wrists slump forward'),
                              FslGuideItem('DUMUDUGO', 'Fingertips flutter downward from injured spot mimicking dripping blood'),
                              FslGuideItem('PAMAMAGA', 'Curved hands start small and expand outward indicating swelling'),
                              FslGuideItem('TENSIYON', 'Dominant hand wraps around upper arm pumping blood pressure cuff'),
                              FslGuideItem('ANXIETY / DEPRESYON', 'Flat hands slide down chest slowly with a sighing expression'),
                              FslGuideItem('ALLERGIC', 'Index finger scratches forearm upward then signs Sakit/Reaction'),
                            ],
                          ),

                          // 3. Alphabet Tab
                          ListView(
                            controller: scrollController,
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              FslGuideItem('A', 'Closed fist with thumb resting alongside index finger'),
                              FslGuideItem('B', 'Four fingers held upright together, thumb folded flat across palm'),
                              FslGuideItem('C', 'Hand curved into a "C" shape facing outward'),
                              FslGuideItem('D', 'Index finger points straight up; thumb and other 3 fingers form a circle'),
                              FslGuideItem('E', 'All four fingertips curled down resting lightly on thumb tip'),
                              FslGuideItem('F', 'Index finger and thumb touch in circle; other 3 fingers extended upward'),
                              FslGuideItem('G', 'Index finger and thumb point sideways parallel to each other'),
                              FslGuideItem('H', 'Index and middle fingers extended together pointing horizontally'),
                              FslGuideItem('I', 'Little finger (pinky) pointed straight up; all other fingers closed in fist'),
                              FslGuideItem('J', 'Little finger up, trace the curve of a "J" in the air'),
                              FslGuideItem('K', 'Index finger upright, middle tilted forward, thumb placed between them'),
                              FslGuideItem('L', 'Thumb and index finger form an "L" shape upright'),
                              FslGuideItem('M', 'Thumb tucked under three folded fingers (index, middle, ring)'),
                              FslGuideItem('N', 'Thumb tucked under two folded fingers (index and middle)'),
                              FslGuideItem('O', 'All fingertips touch thumb tip forming an "O" oval'),
                              FslGuideItem('P', 'Same as "K" handshape pointed downwards toward floor'),
                              FslGuideItem('Q', 'Same as "G" handshape pointed downwards toward floor'),
                              FslGuideItem('R', 'Middle finger crossed over index finger upright'),
                              FslGuideItem('S', 'Closed fist with thumb folded tightly across the front of fingers'),
                              FslGuideItem('T', 'Thumb inserted between index and middle finger with fist closed'),
                              FslGuideItem('U', 'Index and middle fingers held straight up touching together'),
                              FslGuideItem('V', 'Index and middle fingers upright spread apart forming a "V"'),
                              FslGuideItem('W', 'Index, middle, and ring fingers spread upright forming a "W"'),
                              FslGuideItem('X', 'Index finger crooked into a hook; other fingers closed in fist'),
                              FslGuideItem('Y', 'Thumb and pinky extended outward like a "shaka" phone sign'),
                              FslGuideItem('Z', 'Index finger points and traces a "Z" in the air'),
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
                                description: 'Face a light source or window so your hands and face have clear contrast without heavy backlighting or shadows.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.straighten_rounded,
                                title: 'Optimal Distance (0.5m – 1.0m)',
                                description: 'Position your phone on a stand or desk at chest level so your head, shoulders, and both hands remain in frame.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.pan_tool_outlined,
                                title: 'Natural Rest to Pause',
                                description: 'Lower your hands to your lap or sides to pause recognition while thinking. Raise them back into the signing space to resume seamlessly.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.toggle_on_rounded,
                                title: 'Mode Selection for High Precision',
                                description: 'Tap "Mode" on Sign-to-Text to switch to "A–Z" for fingerspelling, "Phrases" for conversational signs, or "Medical" for health symptoms.',
                              ),
                              FslGuideTipCard(
                                icon: Icons.speed_rounded,
                                title: 'Deliberate Pacing',
                                description: 'Hold each static letter for about 1 second to confirm detection before transitioning to the next letter.',
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _kAppBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              sign,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: _kAppBlue,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : const Color(0xFF334155),
              ),
            ),
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
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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

