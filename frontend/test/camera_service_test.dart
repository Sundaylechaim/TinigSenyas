import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinigsenyas/services/camera_service.dart';

void main() {
  group('CameraService display names and error classes', () {
    test('formats front camera name cleanly', () {
      const frontCam = CameraDescription(
        name: '0',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 270,
      );
      final label = CameraService.getCameraDisplayName(frontCam, 0);
      expect(label, contains('Front Camera (Selfie)'));
      expect(label, contains('(0)'));
    });

    test('formats back camera name cleanly', () {
      const backCam = CameraDescription(
        name: '1',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      );
      final label = CameraService.getCameraDisplayName(backCam, 1);
      expect(label, contains('Back Camera'));
      expect(label, contains('(1)'));
    });

    test('formats external USB camera name cleanly', () {
      const usbCam = CameraDescription(
        name: 'HD USB Webcam',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final label = CameraService.getCameraDisplayName(usbCam, 2);
      expect(label, contains('External / USB Webcam'));
      expect(label, contains('(HD USB Webcam)'));
    });

    test('custom camera exception types maintain messages', () {
      final permDenied = CameraPermissionDeniedException('Permission was denied');
      expect(permDenied.message, 'Permission was denied');
      expect(permDenied.toString(), 'Permission was denied');

      final permBlocked =
          CameraPermissionPermanentlyDeniedException('Permanently blocked');
      expect(permBlocked.message, 'Permanently blocked');

      final noCam = NoCameraAvailableException('No camera found');
      expect(noCam.message, 'No camera found');

      final inUse = CameraInUseException('Camera in use');
      expect(inUse.message, 'Camera in use');
    });
  });
}

