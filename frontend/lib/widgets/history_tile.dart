import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/conversation.dart';

const Color _kAppBlue = Color(0xFF2D5FB8);
const Color _kAppYellow = Color(0xFFF4C95D);

class HistoryTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onSpeak;

  const HistoryTile({
    super.key,
    required this.conversation,
    this.onTap,
    this.onDelete,
    this.onSpeak,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final timeFormat = DateFormat('HH:mm');
    final dateFormat = DateFormat('MMM d, yyyy');
    final timestamp = conversation.timestamp;
    final isToday =
        timestamp.year == DateTime.now().year &&
        timestamp.month == DateTime.now().month &&
        timestamp.day == DateTime.now().day;

    final isSpeech = conversation.source == 'speech';
    final accentColor = isSpeech ? _kAppYellow : _kAppBlue;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                ? Colors.black.withValues(alpha: 0.2)
                : accentColor.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Source Icon Container
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSpeech
                        ? _kAppYellow.withValues(alpha: isDark ? 0.25 : 0.18)
                        : _kAppBlue.withValues(alpha: isDark ? 0.25 : 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSpeech
                          ? _kAppYellow.withValues(alpha: 0.4)
                          : _kAppBlue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      isSpeech ? Icons.mic_rounded : Icons.back_hand_rounded,
                      color: isSpeech
                          ? (isDark ? _kAppYellow : const Color(0xFFB45309))
                          : (isDark ? const Color(0xFF60A5FA) : _kAppBlue),
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                // Content Column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.text,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: isDark
                              ? Colors.white
                              : const Color(0xFF0F172A),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          // Source badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: isSpeech
                                  ? _kAppYellow.withValues(alpha: 0.18)
                                  : _kAppBlue.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isSpeech ? 'Speech' : 'Sign (FSL)',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: isSpeech
                                    ? (isDark
                                          ? _kAppYellow
                                          : const Color(0xFFB45309))
                                    : (isDark
                                          ? const Color(0xFF60A5FA)
                                          : _kAppBlue),
                              ),
                            ),
                          ),
                          if (!isSpeech) ...[
                            const SizedBox(width: 8),
                            Text(
                              '${(conversation.confidence * 100).toStringAsFixed(0)}% match',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? const Color(0xFF94A3B8)
                                    : const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Trailing Timestamp & Speak Action
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isToday
                          ? timeFormat.format(timestamp)
                          : dateFormat.format(timestamp),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? const Color(0xFF64748B)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                    if (onSpeak != null) ...[
                      const SizedBox(height: 6),
                      Material(
                        color: isDark
                            ? const Color(0xFF1E293B)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          onTap: onSpeak,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.volume_up_rounded,
                              size: 16,
                              color: isDark ? Colors.white : _kAppBlue,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
