import 'package:flutter/material.dart';

import 'ocr_models.dart';

class VisionOverlayPainter extends CustomPainter {
  VisionOverlayPainter({
    required this.blocks,
    required this.imageSize,
    required this.previewSize,
  });

  final List<OcrBlock> blocks;

  /// Size of the OCR input image coordinates (CameraImage width/height).
  final Size imageSize;

  /// Actual size of the widget displaying preview.
  final Size previewSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.greenAccent;

    // Best-effort scaling (good enough for a spike). This assumes the preview
    // is not cropped; if it is, boxes may drift.
    final sx = previewSize.width / imageSize.width;
    final sy = previewSize.height / imageSize.height;

    for (final b in blocks) {
      final r = Rect.fromLTRB(
        b.boundingBox.left * sx,
        b.boundingBox.top * sy,
        b.boundingBox.right * sx,
        b.boundingBox.bottom * sy,
      );
      canvas.drawRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant VisionOverlayPainter oldDelegate) {
    return oldDelegate.blocks != blocks ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.previewSize != previewSize;
  }
}
