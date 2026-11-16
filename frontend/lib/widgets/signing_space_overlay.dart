import 'package:flutter/material.dart';

class SigningSpaceOverlay extends StatelessWidget {
  final bool showZoneGuides;

  const SigningSpaceOverlay({super.key, this.showZoneGuides = true});

  @override
  Widget build(BuildContext context) {
    if (!showZoneGuides) return const SizedBox.shrink();

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;

          final leftZoneBoundary = width * 0.33;
          final rightZoneBoundary = width * 0.67;

          return Stack(
            children: [
              // Left zone divider guide (subtle dashed/faded line)
              Positioned(
                left: leftZoneBoundary,
                top: height * 0.18,
                bottom: height * 0.22,
                child: Container(
                  width: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.25),
                        Colors.white.withValues(alpha: 0.25),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),

              // Right zone divider guide
              Positioned(
                left: rightZoneBoundary,
                top: height * 0.18,
                bottom: height * 0.22,
                child: Container(
                  width: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.25),
                        Colors.white.withValues(alpha: 0.25),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),

              // Signing Box Reticle (Center Focus Area)
              Center(
                child: Container(
                  width: width * 0.78,
                  height: height * 0.52,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),

              // Subtle Zone Indicators at the top
              Positioned(
                top: height * 0.14,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildZonePill('Left', isCenter: false),
                    _buildZonePill('Signing Area', isCenter: true),
                    _buildZonePill('Right', isCenter: false),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildZonePill(String text, {required bool isCenter}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isCenter
            ? const Color(0xFFF4C95D).withValues(alpha: 0.2)
            : Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCenter
              ? const Color(0xFFF4C95D).withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isCenter ? const Color(0xFFF4C95D) : Colors.white70,
          fontSize: 11,
          fontWeight: isCenter ? FontWeight.w700 : FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
