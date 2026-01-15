import 'package:flutter/material.dart';

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_models.dart';

class VisionOverlayPainter extends CustomPainter {
  VisionOverlayPainter({
    required this.blocks,
    required this.imageSize,
    required this.previewSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  final List<OcrBlock> blocks;
  final Size imageSize;
  final Size previewSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.greenAccent;

    for (final b in blocks) {
      final rect = b.boundingBox;
      
      final left = translateX(
          rect.left, rotation, size, imageSize, cameraLensDirection);
      final top = translateY(
          rect.top, rotation, size, imageSize, cameraLensDirection);
      final right = translateX(
          rect.right, rotation, size, imageSize, cameraLensDirection);
      final bottom = translateY(
          rect.bottom, rotation, size, imageSize, cameraLensDirection);

      canvas.drawRect(
        Rect.fromLTRB(left, top, right, bottom),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(VisionOverlayPainter oldDelegate) {
    return oldDelegate.blocks != blocks ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.previewSize != previewSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}

double translateX(
  double x,
  InputImageRotation rotation,
  Size size,
  Size absoluteImageSize,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      return x *
          size.width /
          (Platform.isIOS ? absoluteImageSize.width : absoluteImageSize.height);
    case InputImageRotation.rotation270deg:
      return size.width -
          x *
              size.width /
              (Platform.isIOS
                  ? absoluteImageSize.width
                  : absoluteImageSize.height);
    default:
      return x * size.width / absoluteImageSize.width;
  }
}

double translateY(
  double y,
  InputImageRotation rotation,
  Size size,
  Size absoluteImageSize,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y *
          size.height /
          (Platform.isIOS
              ? absoluteImageSize.height
              : absoluteImageSize.width);
    default:
      return y * size.height / absoluteImageSize.height;
  }
}
