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
    this.learnedTexts = const {},
    this.recognizedTexts = const {}, // [NEW] Brain 1: Seen before (Cyan)
    this.highlightedBlock,
    this.scaleToSize = false,
  });

  final List<OcrBlock> blocks;
  final Set<String> learnedTexts; // Brain 2: Mastered (Green)
  final Set<String> recognizedTexts; // Brain 1: Recognized (Cyan)
  final Size imageSize;
  final Size previewSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final OcrBlock? highlightedBlock;
  final bool scaleToSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final paintUnlearned = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.redAccent;

    final paintLearned = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.green;
      
    final paintRecognized = Paint() // [NEW] Cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.cyanAccent;

    final paintHighlighted = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..color = Colors.amber; // Amber for active selection

    // If we have a highlight, dim everything else
    final hasHighlight = highlightedBlock != null;

    for (final b in blocks) {
      // 1. Check Green (Learned/Mastered)
      bool isLearned = _fuzzyContains(learnedTexts, b.text);
      
      // 2. Check Cyan (Recognized/Brain 1)
      bool isRecognized = false;
      if (!isLearned) {
         isRecognized = _fuzzyContains(recognizedTexts, b.text);
      }
      
      final isHighlighted = highlightedBlock == b;
      
      Paint paintToUse;
      if (isHighlighted) {
         paintToUse = paintHighlighted;
      } else if (hasHighlight) {
         paintToUse = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0
            ..color = Colors.grey.withValues(alpha: 0.2); 
      } else {
         if (isLearned) {
             paintToUse = paintLearned;
         } else if (isRecognized) {
             paintToUse = paintRecognized;
         } else {
             paintToUse = paintUnlearned;
         }
      }

      final rect = b.boundingBox;
      
      double left, top, right, bottom;
      if (scaleToSize) {
         final sx = size.width / imageSize.width;
         final sy = size.height / imageSize.height;
         left = rect.left * sx;
         top = rect.top * sy;
         right = rect.right * sx;
         bottom = rect.bottom * sy;
      } else {
          left = translateX(
              rect.left, rotation, size, imageSize, cameraLensDirection);
          top = translateY(
              rect.top, rotation, size, imageSize, cameraLensDirection);
          right = translateX(
              rect.right, rotation, size, imageSize, cameraLensDirection);
          bottom = translateY(
              rect.bottom, rotation, size, imageSize, cameraLensDirection);
      }

      final dstRect = Rect.fromLTRB(left, top, right, bottom);

      canvas.drawRect(dstRect, paintToUse);
      
      if (isHighlighted) {
         // Draw Crosshair at Center
         final cx = dstRect.center.dx;
         final cy = dstRect.center.dy;
         final paintCross = Paint()
           ..color = Colors.red
           ..strokeWidth = 4.0;
         // Horizontal
         canvas.drawLine(Offset(cx - 10, cy), Offset(cx + 10, cy), paintCross);
         // Vertical
         canvas.drawLine(Offset(cx, cy - 10), Offset(cx, cy + 10), paintCross);
      }
      
      if (isLearned) {
         // Maybe draw a checkmark?
         final icon = Icons.check_circle;
         final textPainter = TextPainter(
             text: TextSpan(
              text: String.fromCharCode(icon.codePoint),
              style: TextStyle(
                fontSize: 14,
                fontFamily: icon.fontFamily,
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
             ),
             textDirection: TextDirection.ltr,
         );
         textPainter.layout();
         textPainter.paint(canvas, dstRect.topRight - const Offset(6, 6)); 
      }
    }

    // Force draw Highlighted Block separately (even if not in 'blocks')
    // This handles the case where the screen refreshed (blocks changed), but we still
    // want to show where the AI originally clicked (the "Ghost" target).
    if (highlightedBlock != null) {
      final rect = highlightedBlock!.boundingBox;
      double left, top, right, bottom;
      if (scaleToSize) {
         final sx = size.width / imageSize.width;
         final sy = size.height / imageSize.height;
         left = rect.left * sx;
         top = rect.top * sy;
         right = rect.right * sx;
         bottom = rect.bottom * sy;
      } else {
          left = translateX(
              rect.left, rotation, size, imageSize, cameraLensDirection);
          top = translateY(
              rect.top, rotation, size, imageSize, cameraLensDirection);
          right = translateX(
              rect.right, rotation, size, imageSize, cameraLensDirection);
          bottom = translateY(
              rect.bottom, rotation, size, imageSize, cameraLensDirection);
      }

      final dstRect = Rect.fromLTRB(left, top, right, bottom);

      // Draw Cyan Box
      final paintHighlighted = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..color = Colors.cyanAccent;
      
      canvas.drawRect(dstRect, paintHighlighted);

      // Draw Red Crosshair
      final cx = dstRect.center.dx;
      final cy = dstRect.center.dy;
      final paintCross = Paint()
        ..color = Colors.red
        ..strokeWidth = 4.0;
        
      canvas.drawLine(Offset(cx - 15, cy), Offset(cx + 15, cy), paintCross);
      canvas.drawLine(Offset(cx, cy - 15), Offset(cx, cy + 15), paintCross);
    }
  }

  @override
  bool shouldRepaint(VisionOverlayPainter oldDelegate) {
    return oldDelegate.blocks != blocks ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.previewSize != previewSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection ||
        oldDelegate.cameraLensDirection != cameraLensDirection ||
        oldDelegate.learnedTexts != learnedTexts ||
        oldDelegate.recognizedTexts != recognizedTexts ||
        oldDelegate.highlightedBlock != highlightedBlock ||
        oldDelegate.scaleToSize != scaleToSize;
  }
  bool _fuzzyContains(Set<String> set, String text) {
      if (set.contains(text)) return true;
      final trimmed = text.trim();
      if (set.contains(trimmed)) return true;
      final cleaned = text.trim().replaceAll(RegExp(r"^['`\x22]+|['`\x22]+$"), '');
      if (set.contains(cleaned)) return true;
      return false;
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
