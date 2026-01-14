import 'dart:convert';

import 'package:meta/meta.dart';

@immutable
class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.boundingBox,
    this.confidence,
  });

  final String text;
  final BoundingBox boundingBox;

  /// ML Kit text recognition does not always provide per-block confidence.
  final double? confidence;

  Map<String, Object?> toJson() => {
        'text': text,
        'bbox': boundingBox.toJson(),
        'confidence': confidence,
      };

  @override
  String toString() => jsonEncode(toJson());
}

@immutable
class BoundingBox {
  const BoundingBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).abs();
  double get height => (bottom - top).abs();
  double get area => width * height;

  Map<String, Object?> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };
}

@immutable
class UIState {
  const UIState({
    required this.ocrBlocks,
    required this.imageWidth,
    required this.imageHeight,
    required this.derived,
    required this.createdAt,
  });

  final List<OcrBlock> ocrBlocks;
  final int imageWidth;
  final int imageHeight;
  final DerivedFlags derived;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'created_at': createdAt.toIso8601String(),
        'image': {
          'width': imageWidth,
          'height': imageHeight,
        },
        'ocr_blocks': ocrBlocks.map((b) => b.toJson()).toList(growable: false),
        'derived': derived.toJson(),
      };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

@immutable
class DerivedFlags {
  const DerivedFlags({
    required this.hasModalCandidate,
    required this.hasErrorCandidate,
    required this.modalKeywords,
  });

  final bool hasModalCandidate;
  final bool hasErrorCandidate;
  final List<String> modalKeywords;

  Map<String, Object?> toJson() => {
        'has_modal_candidate': hasModalCandidate,
        'has_error_candidate': hasErrorCandidate,
        'modal_keywords': modalKeywords,
      };
}
