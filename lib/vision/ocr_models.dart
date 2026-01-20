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
    buffer.writeln('Screen Resolution: ${imageWidth}x$imageHeight');
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

// ============================================================
// REGION GROUPING - Phase 2.5
// ============================================================

/// Represents a spatial region containing multiple OCR blocks.
/// 
/// Regions are created by clustering nearby blocks, useful for:
/// - Identifying dialog boundaries
/// - Disambiguating elements with the same text ("OK" in different dialogs)
/// - Understanding UI hierarchy
@immutable
class OcrRegion {
  const OcrRegion({
    required this.bounds,
    required this.blocks,
    this.label,
  });

  /// The bounding box encompassing all blocks in this region.
  final BoundingBox bounds;
  
  /// The OCR blocks that belong to this region.
  final List<OcrBlock> blocks;
  
  /// Optional label for this region (e.g., "Dialog: Confirm Delete").
  final String? label;

  /// All text in this region, concatenated.
  String get allText => blocks.map((b) => b.text).join(' ');
  
  /// Check if this region contains a specific text.
  bool containsText(String text) => 
      blocks.any((b) => b.text.toLowerCase().contains(text.toLowerCase()));

  /// Find a specific block by text within this region.
  OcrBlock? findBlock(String text) {
    final searchLower = text.toLowerCase();
    for (final block in blocks) {
      if (block.text.toLowerCase().contains(searchLower)) {
        return block;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'bounds': bounds.toJson(),
    'blocks': blocks.map((b) => b.toJson()).toList(),
    if (label != null) 'label': label,
  };
}

/// Utility class for grouping OCR blocks into spatial regions.
class RegionGrouper {
  /// Groups blocks into regions based on spatial proximity.
  /// 
  /// [proximityThreshold] is the maximum gap (in pixels) between blocks
  /// to be considered part of the same region.
  static List<OcrRegion> groupByProximity(
    List<OcrBlock> blocks, {
    double proximityThreshold = 50.0,
  }) {
    if (blocks.isEmpty) return [];
    
    // Simple clustering: merge blocks that are close to each other
    final regions = <OcrRegion>[];
    final used = List.filled(blocks.length, false);
    
    for (int i = 0; i < blocks.length; i++) {
      if (used[i]) continue;
      
      // Start a new region with this block
      final cluster = <OcrBlock>[blocks[i]];
      used[i] = true;
      
      // Find all nearby blocks
      bool foundNew = true;
      while (foundNew) {
        foundNew = false;
        for (int j = 0; j < blocks.length; j++) {
          if (used[j]) continue;
          
          // Check if block j is close to any block in the cluster
          for (final clusterBlock in cluster) {
            if (_isClose(clusterBlock.boundingBox, blocks[j].boundingBox, proximityThreshold)) {
              cluster.add(blocks[j]);
              used[j] = true;
              foundNew = true;
              break;
            }
          }
        }
      }
      
      // Create region from cluster
      regions.add(_createRegion(cluster));
    }
    
    return regions;
  }

  /// Groups blocks by vertical alignment (rows).
  static List<OcrRegion> groupByRows(
    List<OcrBlock> blocks, {
    double rowTolerance = 20.0,
  }) {
    if (blocks.isEmpty) return [];
    
    // Sort by vertical position
    final sorted = List<OcrBlock>.from(blocks)
      ..sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));
    
    final rows = <List<OcrBlock>>[];
    List<OcrBlock> currentRow = [sorted.first];
    double currentRowTop = sorted.first.boundingBox.top;
    
    for (int i = 1; i < sorted.length; i++) {
      final block = sorted[i];
      if ((block.boundingBox.top - currentRowTop).abs() <= rowTolerance) {
        currentRow.add(block);
      } else {
        rows.add(currentRow);
        currentRow = [block];
        currentRowTop = block.boundingBox.top;
      }
    }
    rows.add(currentRow);
    
    // Sort each row by horizontal position and create regions
    return rows.map((row) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      return _createRegion(row);
    }).toList();
  }

  /// Identifies candidate "container" regions (e.g., dialogs, panels).
  /// 
  /// A container is a region that is significantly larger than average
  /// and contains multiple sub-regions.
  static List<OcrRegion> findContainers(
    List<OcrBlock> blocks, {
    double areaMultiplier = 3.0,
    int minBlocks = 3,
  }) {
    final regions = groupByProximity(blocks, proximityThreshold: 30);
    if (regions.isEmpty) return [];
    
    final avgArea = regions.map((r) => r.bounds.area).reduce((a, b) => a + b) / regions.length;
    
    return regions.where((r) => 
      r.bounds.area >= avgArea * areaMultiplier && 
      r.blocks.length >= minBlocks
    ).toList();
  }

  static bool _isClose(BoundingBox a, BoundingBox b, double threshold) {
    // Calculate minimum distance between boxes
    final hGap = (a.left > b.right) 
        ? (a.left - b.right) 
        : (b.left > a.right ? b.left - a.right : 0.0);
    final vGap = (a.top > b.bottom) 
        ? (a.top - b.bottom) 
        : (b.top > a.bottom ? b.top - a.bottom : 0.0);
    
    return hGap <= threshold && vGap <= threshold;
  }

  static OcrRegion _createRegion(List<OcrBlock> blocks) {
    // Calculate encompassing bounds
    double minLeft = double.infinity;
    double minTop = double.infinity;
    double maxRight = double.negativeInfinity;
    double maxBottom = double.negativeInfinity;
    
    for (final block in blocks) {
      if (block.boundingBox.left < minLeft) minLeft = block.boundingBox.left;
      if (block.boundingBox.top < minTop) minTop = block.boundingBox.top;
      if (block.boundingBox.right > maxRight) maxRight = block.boundingBox.right;
      if (block.boundingBox.bottom > maxBottom) maxBottom = block.boundingBox.bottom;
    }
    
    return OcrRegion(
      bounds: BoundingBox(
        left: minLeft,
        top: minTop,
        right: maxRight,
        bottom: maxBottom,
      ),
      blocks: blocks,
    );
  }
}
