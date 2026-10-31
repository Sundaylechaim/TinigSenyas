import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraService {
  CameraController? _controller;
  CameraDescription? _selectedCamera;
  List<CameraDescription> _cameras = [];
  StreamController<CameraImage>? _frameController;
  bool _isSwitching = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  CameraDescription? get selectedCamera => _selectedCamera;
  List<CameraDescription> get availableCamerasList => List.unmodifiable(_cameras);
  bool get canSwitchCamera => _cameras.length > 1 && !_isSwitching;
  Stream<CameraImage> get frameStream => _frameController?.stream ?? const Stream.empty();

  /// Checks whether camera permission has been granted without automatically prompting.
  Future<bool> hasCameraPermission() async {
    if (kIsWeb) return true; // Web browsers prompt upon getUserMedia / availableCameras
    final status = await Permission.camera.status;
    return status.isGranted;
  }

  /// Checks if permission is permanently denied (requires navigating to system settings).
  Future<bool> isPermissionPermanentlyDenied() async {
    if (kIsWeb) return false;
    final status = await Permission.camera.status;
    return status.isPermanentlyDenied;
  }

  /// Explicitly requests camera permission from the user.
  Future<bool> requestCameraPermission() async {
    if (kIsWeb) return true;
    final status = await Permission.camera.request();
    return status.isGranted;
  }

  /// Opens the device settings page so the user can re-enable camera permission.
  Future<bool> openSettings() async {
    if (kIsWeb) return false;
    return await openAppSettings();
  }

  /// Initializes the camera. If permission is not granted, requests it first.
  /// Gracefully attempts fallback resolutions and image format groups across
  /// all types of cameras (front, back, external USB, virtual).
  Future<void> initialize({
    CameraLensDirection? direction,
    CameraLensDirection preferredDirection = CameraLensDirection.front,
    CameraDescription? specificCamera,
  }) async {
    final targetDirection = direction ?? preferredDirection;

    // 1. Ensure permission is granted before accessing hardware
    if (!kIsWeb) {
      final status = await Permission.camera.status;
      if (!status.isGranted) {
        final requestResult = await Permission.camera.request();
        if (!requestResult.isGranted) {
          if (requestResult.isPermanentlyDenied) {
            throw CameraPermissionPermanentlyDeniedException(
              'Camera permission is permanently denied. Please enable it in system settings.',
            );
          }
          throw CameraPermissionDeniedException(
            'Camera permission was denied. Please allow camera access to use sign translation.',
          );
        }
      }
    }

    // 2. Discover all available cameras connected to the system
    try {
      _cameras = await availableCameras();
    } catch (e) {
      final err = e.toString();
      if (err.contains('cameraNotReadable') || err.contains('NotReadableError')) {
        throw CameraInUseException(
          'The webcam is in use by another program (such as Zoom, Teams, Discord, another browser tab, or background script) or blocked by Windows settings.',
        );
      }
      throw CameraException('Failed to discover connected cameras: $e');
    }

    if (_cameras.isEmpty) {
      throw NoCameraAvailableException(
        'No camera detected on this device. Please connect a webcam or enable camera hardware.',
      );
    }

    // 3. Select requested camera or best matching lens direction
    CameraDescription? primaryCamera;
    if (specificCamera != null && _cameras.contains(specificCamera)) {
      primaryCamera = specificCamera;
    } else {
      primaryCamera = _cameras.firstWhere(
        (cam) => cam.lensDirection == targetDirection,
        orElse: () => _cameras.first,
      );
    }

    // Try primary camera first, then gracefully fall back to all other connected cameras
    final camerasToTry = <CameraDescription>[
      primaryCamera,
      ..._cameras.where((c) => c != primaryCamera),
    ];

    Object? lastError;
    for (final cam in camerasToTry) {
      try {
        await _initializeControllerWithFallback(cam);
        _startFrameStream();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('Camera init failed for "${cam.name}", trying next camera: $e');
      }
    }

    final errStr = lastError.toString();
    if (errStr.contains('cameraNotReadable') || errStr.contains('NotReadableError') || errStr.contains('hardware error')) {
      throw CameraInUseException(
        'The webcam is in use by another program (such as Zoom, Teams, Discord, another browser tab, or background script) or blocked by Windows settings.',
      );
    }
    throw CameraException('Could not initialize any connected camera: $lastError');
  }

  Future<void> _initializeControllerWithFallback(CameraDescription camera) async {
    await _controller?.dispose();
    _controller = null;

    // Native resolution priority: Start with medium (640x480) for web compatibility
    final resolutions = kIsWeb
        ? const [
            ResolutionPreset.medium,
            ResolutionPreset.low,
            ResolutionPreset.high,
          ]
        : const [
            ResolutionPreset.high,
            ResolutionPreset.medium,
            ResolutionPreset.low,
          ];

    final formatGroups = kIsWeb
        ? <ImageFormatGroup?>[null]
        : <ImageFormatGroup?>[ImageFormatGroup.yuv420, ImageFormatGroup.nv21, null];

    Object? lastError;

    for (final format in formatGroups) {
      for (final resolution in resolutions) {
        CameraController? controller;
        try {
          controller = CameraController(
            camera,
            resolution,
            enableAudio: false,
            imageFormatGroup: format,
          );

          await controller.initialize();
          _controller = controller;
          _selectedCamera = camera;
          return;
        } catch (e) {
          lastError = e;
          await controller?.dispose();
          debugPrint('Camera init fallback (Camera: ${camera.name}, Resolution: $resolution): $e');
        }
      }
    }

    throw CameraException('Could not initialize camera "${camera.name}": $lastError');
  }

  void _startFrameStream() {
    _frameController?.close();
    _frameController = StreamController<CameraImage>.broadcast();

    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      _controller!.startImageStream((CameraImage image) {
        if (!_frameController!.isClosed) {
          _frameController!.add(image);
        }
      });
    } catch (e) {
      // Flutter Web does not implement startImageStream; ignore gracefully
      debugPrint('Live frame streaming not supported on this platform: $e');
    }
  }

  /// Switches to the next available camera (front -> back -> external -> front)
  Future<void> switchCamera() async {
    if (_cameras.length < 2 || _isSwitching) return;
    _isSwitching = true;

    try {
      final currentIndex = _cameras.indexOf(_selectedCamera!);
      final nextIndex = (currentIndex + 1) % _cameras.length;
      final nextCamera = _cameras[nextIndex];

      await selectCamera(nextCamera);
    } finally {
      _isSwitching = false;
    }
  }

  /// Selects a specific camera from the available camera list
  Future<void> selectCamera(CameraDescription camera) async {
    if (!_cameras.contains(camera)) return;

    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        await _controller!.stopImageStream().catchError((_) {});
      }
    } catch (_) {}

    await _initializeControllerWithFallback(camera);
    _startFrameStream();
  }

  /// Helper to get a human-friendly display name for a camera
  static String getCameraDisplayName(CameraDescription camera, int index) {
    final direction = switch (camera.lensDirection) {
      CameraLensDirection.front => 'Front Camera (Selfie)',
      CameraLensDirection.back => 'Back Camera',
      CameraLensDirection.external => 'External / USB Webcam',
    };
    return camera.name.isNotEmpty ? '$direction (${camera.name})' : '$direction #$index';
  }

  void dispose() {
    try {
      if (_controller != null && _controller!.value.isStreamingImages) {
        _controller!.stopImageStream().catchError((_) {});
      }
    } catch (_) {}

    _frameController?.close();
    _controller?.dispose();
    _controller = null;
    _frameController = null;
    _isSwitching = false;
  }
}

class CameraException implements Exception {
  final String message;
  CameraException(this.message);
  @override
  String toString() => message;
}

class CameraPermissionDeniedException extends CameraException {
  CameraPermissionDeniedException(super.message);
}

class CameraPermissionPermanentlyDeniedException extends CameraException {
  CameraPermissionPermanentlyDeniedException(super.message);
}

class NoCameraAvailableException extends CameraException {
  NoCameraAvailableException(super.message);
}

class CameraInUseException extends CameraException {
  CameraInUseException(super.message);
}
