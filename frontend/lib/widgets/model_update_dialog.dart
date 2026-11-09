import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart' as sb;
import '../../services/model_updater.dart';

class ModelUpdateDialog extends StatefulWidget {
  final ModelUpdater modelUpdater;
  final VoidCallback? onUpdateComplete;

  const ModelUpdateDialog({
    super.key,
    required this.modelUpdater,
    this.onUpdateComplete,
  });

  @override
  State<ModelUpdateDialog> createState() => _ModelUpdateDialogState();
}

class _ModelUpdateDialogState extends State<ModelUpdateDialog> {
  ModelUpdateInfo? _updateInfo;
  Stream<ModelUpdateInfo>? _downloadStream;
  bool _isChecking = true;
  String? _appUpdateNotice;

  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _isChecking = true;
      _appUpdateNotice = null;
    });

    // 1. Check Shorebird OTA Code Updates
    final updater = sb.ShorebirdUpdater();
    if (updater.isAvailable) {
      try {
        final status = await updater.checkForUpdate();
        if (status == sb.UpdateStatus.outdated) {
          setState(() {
            _appUpdateNotice = 'Downloading app update in background...';
          });
          await updater.update();
          setState(() {
            _appUpdateNotice = 'App update ready! Restart TinigSenyas to apply.';
          });
        } else if (status == sb.UpdateStatus.restartRequired) {
          setState(() {
            _appUpdateNotice = 'App update downloaded! Please restart the app.';
          });
        }
      } catch (e) {
        debugPrint('[Shorebird] Update check: $e');
      }
    }

    // 2. Check FSL AI Model Updates
    final info = await widget.modelUpdater.checkForUpdates();
    if (!mounted) return;

    setState(() {
      _isChecking = false;
      _updateInfo = info;
    });

    if (info.status == UpdateStatus.updateAvailable) {
      _startDownload(info);
    }
  }

  void _startDownload(ModelUpdateInfo info) {
    _downloadStream = widget.modelUpdater.downloadUpdate(info);
    _downloadStream!.listen(
      (update) {
        if (!mounted) return;
        setState(() {
          _updateInfo = update;
        });
        if (update.status == UpdateStatus.upToDate && update.progress >= 1.0) {
          widget.onUpdateComplete?.call();
          if (mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _updateInfo = info.copyWith(
            status: UpdateStatus.error,
            errorMessage: 'Download failed: $error',
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking && _updateInfo == null) {
      return const AlertDialog(
        title: Text('Updates (OTA)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Checking for app & model updates...'),
          ],
        ),
      );
    }

    final info = _updateInfo;
    if (info == null) {
      return const AlertDialog(
        title: Text('Updates (OTA)'),
        content: Text('Unable to read update status.'),
      );
    }

    return AlertDialog(
      title: const Text('Updates (OTA)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'App Version: 1.2.0 (Model: ${info.currentVersion})',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          if (_appUpdateNotice != null) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: Text(
                _appUpdateNotice!,
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blue),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (info.status == UpdateStatus.upToDate && info.progress < 1.0) ...[
            Text('Your app and AI models are up to date!'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ] else if (info.status == UpdateStatus.updateAvailable ||
              info.status == UpdateStatus.downloading) ...[
            Text('Downloading model update to v${info.version}...'),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: info.progress),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${(info.progress * 100).toInt()}%'),
            ),
          ] else if (info.status == UpdateStatus.error) ...[
            Text(
              info.errorMessage ??
                  'Failed to download model updates. Please check your internet connection.',
              style: const TextStyle(color: Colors.redAccent),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _checkForUpdates,
                child: const Text('Retry'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
