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

  String toLLMDescription() {
    // simplified for LLM token efficiency
    return '"$text" at ${boundingBox.center}'; 
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OcrBlock &&
          runtimeType == other.runtimeType &&
          text == other.text &&
          boundingBox == other.boundingBox;

  @override
  int get hashCode => text.hashCode ^ boundingBox.hashCode;
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
  
  String get center => '[${(left + width / 2).toStringAsFixed(0)}, ${(top + height / 2).toStringAsFixed(0)}]';

  Map<String, Object?> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoundingBox &&
          runtimeType == other.runtimeType &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom;

  @override
  int get hashCode =>
      left.hashCode ^ top.hashCode ^ right.hashCode ^ bottom.hashCode;
}

@immutable
class UIState {
  const UIState({
    required this.ocrBlocks,
    required this.imageWidth,
    required this.imageHeight,
    required this.derived,
    required this.createdAt,
    this.embedding,
  });

  final List<OcrBlock> ocrBlocks;
  final int imageWidth;
  final int imageHeight;
  final DerivedFlags derived;
  final DateTime createdAt;
  
  /// Vector embedding of this state (CRITICAL for Qdrant/Memory)
  final List<double>? embedding;

  Map<String, Object?> toJson() => {
        'created_at': createdAt.toIso8601String(),
        'image': {
          'width': imageWidth,
          'height': imageHeight,
        },
        'ocr_blocks': ocrBlocks.map((b) => b.toJson()).toList(growable: false),
        'derived': derived.toJson(),
        if (embedding != null) 'embedding': embedding,
      };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Generates a dense textual description for Ollama.
  String toLLMDescription() {
    final buffer = StringBuffer();
    buffer.writeln('Screen Resolution: ${imageWidth}x${imageHeight}');
    buffer.writeln('Visible Text Elements:');
    for (final block in ocrBlocks) {
      buffer.writeln('- ${block.toLLMDescription()}');
    }
    if (derived.hasModalCandidate) {
      buffer.writeln('Context: A modal/dialog appears to be open.');
    }
    return buffer.toString();
  }
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
