import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/camera_service.dart';

class CameraPreviewWidget extends StatelessWidget {
  final CameraService cameraService;
  final Widget? overlay;
  final BoxFit fit;

  const CameraPreviewWidget({
    super.key,
    required this.cameraService,
    this.overlay,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final controller = cameraService.controller;
    if (!cameraService.isInitialized || controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final isRotated = !kIsWeb && MediaQuery.of(context).orientation == Orientation.portrait;
    final previewWidth = isRotated
        ? (controller.value.previewSize?.height ?? 1)
        : (controller.value.previewSize?.width ?? 1);
    final previewHeight = isRotated
        ? (controller.value.previewSize?.width ?? 1)
        : (controller.value.previewSize?.height ?? 1);

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: fit,
            child: SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: CameraPreview(controller),
            ),
          ),
        ),
        ?overlay,
      ],
    );
  }
}
