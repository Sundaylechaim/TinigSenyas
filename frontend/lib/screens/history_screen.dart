import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/database_helper.dart';
import '../services/tts_service.dart';
import '../models/conversation.dart';
import '../widgets/connectivity_badge.dart';
import '../widgets/history_tile.dart';

const Color _kAppBlue = Color(0xFF0138FF);
const Color _kAppYellow = Color(0xFFFFC801);

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Conversation> _history = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMoreHistory = true;
  String? _loadError;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _scrollController.addListener(_onScroll);
    DatabaseHelper.instance.historyChangeNotifier.addListener(_loadHistory);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.historyChangeNotifier.removeListener(_loadHistory);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
      _hasMoreHistory = true;
    });
    try {
      final history = await DatabaseHelper.instance.getHistory(limit: 50);
      if (mounted) {
        setState(() {
          _history = history;
          _hasMoreHistory = history.length == 50;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_isLoadingMore || !_hasMoreHistory) return;
    setState(() => _isLoadingMore = true);
    try {
      final moreHistory = await DatabaseHelper.instance.getHistory(
        limit: 50,
        offset: _history.length,
      );
      if (mounted) {
        setState(() {
          _history.addAll(moreHistory);
          _hasMoreHistory = moreHistory.length == 50;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load more history: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _onRefresh() async {
    await _loadHistory();
  }

  Future<void> _speakConversation(Conversation conversation) async {
    try {
      await context.read<TtsService>().speak(conversation.text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play speech: $error')),
        );
      }
    }
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    if (conversation.id != null) {
      await DatabaseHelper.instance.deleteConversation(conversation.id!);
      _loadHistory();
    }
  }

  Future<void> _confirmClearAll() async {
    if (_history.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History'),
        content: const Text(
          'Are you sure you want to delete all translation history? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DatabaseHelper.instance.clearHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All translation history cleared')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF090E1A) : const Color(0xFFF1F5F9);

    return Scaffold(
      backgroundColor: bgColor,
      extendBodyBehindAppBar: true,

      // CONSISTENT FROSTED GLASS APP BAR
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0C1220).withValues(alpha: 0.65)
                    : Colors.white.withValues(alpha: 0.70),
                border: Border(
                  bottom: BorderSide(
                    color: isDark
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
            const Flexible(
              child: Text(
                'Translation History',
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
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Clear all history',
              visualDensity: VisualDensity.compact,
              onPressed: _confirmClearAll,
            ),
          const SizedBox(width: 4),
          const ConnectivityBadge(),
          const SizedBox(width: 10),
        ],
      ),

      // CONSISTENT AMBIENT BACKGROUND LAYER
      body: Stack(
        children: [
          // Top-Right Ambient Orb
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
                      _kAppBlue.withValues(alpha: isDark ? 0.30 : 0.20),
                      _kAppBlue.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Bottom-Left Ambient Orb
          Positioned(
            bottom: -50,
            left: -60,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _kAppYellow.withValues(alpha: isDark ? 0.20 : 0.18),
                      _kAppYellow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Main Content
          SafeArea(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline_rounded, size: 48, color: Colors.redAccent),
                              const SizedBox(height: 12),
                              Text('Could not load history: $_loadError', textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _loadHistory,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _history.isEmpty
                        ? _buildEmptyState(isDark)
                        : RefreshIndicator(
                            onRefresh: _onRefresh,
                            child: ListView.builder(
                              controller: _scrollController,
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.only(top: 8, bottom: 24),
                              itemCount: _history.length + (_hasMoreHistory ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index >= _history.length) {
                                  return Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Center(
                                      child: _isLoadingMore
                                          ? const CircularProgressIndicator()
                                          : const SizedBox.shrink(),
                                    ),
                                  );
                                }
                                final conversation = _history[index];
                                return Dismissible(
                                  key: ValueKey(conversation.id),
                                  direction: DismissDirection.endToStart,
                                  background: Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.redAccent.withValues(alpha: 0.85),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 20),
                                    child: const Icon(
                                      Icons.delete_rounded,
                                      color: Colors.white,
                                    ),
                                  ),
                                  confirmDismiss: (direction) async {
                                    return await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        title: const Text('Delete Conversation', style: TextStyle(fontWeight: FontWeight.w800)),
                                        content: Text('Delete "${conversation.text}"?'),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            style: FilledButton.styleFrom(
                                              backgroundColor: Colors.redAccent,
                                            ),
                                            onPressed: () => Navigator.pop(context, true),
                                            child: const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                  onDismissed: (_) => _deleteConversation(conversation),
                                  child: HistoryTile(
                                    conversation: conversation,
                                    onSpeak: () => _speakConversation(conversation),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28.0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.14)
                      : Colors.white.withValues(alpha: 0.75),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: _kAppBlue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.history_rounded,
                      size: 32,
                      color: _kAppBlue,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No history yet',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Translate a sign in camera or speak into microphone and tap Save to see your transcript here.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
