import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connectivity_service.dart';

class ConnectivityBadge extends StatelessWidget {
  const ConnectivityBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final connectivity = context.watch<ConnectivityService>();
    return StreamBuilder<ConnectivityStatus>(
      initialData: connectivity.currentStatus,
      stream: connectivity.statusStream,
      builder: (context, snapshot) {
        final status = snapshot.data ?? ConnectivityStatus.checking;
        final isOnline = status == ConnectivityStatus.online;
        final isChecking = status == ConnectivityStatus.checking;
        final isOffline = status == ConnectivityStatus.offline;
        final color = isOnline
            ? const Color(0xFF10B981) // emerald green
            : isOffline
                ? const Color(0xFFF59E0B) // amber
                : const Color(0xFF94A3B8); // slate

        final shortLabel = isChecking
            ? 'Checking'
            : isOnline
                ? 'Online'
                : isOffline
                    ? 'Offline'
                    : 'Unknown';

        final tooltipMessage = connectivity.lastError ??
            (isOnline
                ? 'Connected • AI Services Active'
                : isOffline
                    ? 'Offline Mode • On-Device AI Active'
                    : 'Checking network status...');

        final screenWidth = MediaQuery.of(context).size.width;
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        // Display sleek compact badge on all mobile screens (< 500px) or enlarged text scales
        // to guarantee zero collision with screen titles across all devices and scaling levels.
        final showCompact = screenWidth < 500 || textScale >= 1.1;

        return MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.1,
          child: Tooltip(
            message: tooltipMessage,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: showCompact ? 6 : 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: color.withValues(alpha: 0.6),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isOnline
                        ? Icons.wifi_rounded
                        : isOffline
                            ? Icons.wifi_off_rounded
                            : Icons.wifi_find_rounded,
                    size: 13,
                    color: color,
                  ),
                  const SizedBox(width: 4),
                  if (showCompact)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    )
                  else
                    Text(
                      shortLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: color,
                        letterSpacing: -0.2,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
