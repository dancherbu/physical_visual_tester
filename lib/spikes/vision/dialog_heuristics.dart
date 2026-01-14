import 'ocr_models.dart';

class DialogHeuristics {
  static const _modalWords = <String>{
    'ok',
    'cancel',
    'close',
    'retry',
    'dismiss',
    'allow',
    'deny',
    'later',
    'update',
    'yes',
    'no',
  };

  static const _errorWords = <String>{
    'error',
    'failed',
    'failure',
    'unable',
    'exception',
    'denied',
    'warning',
  };

  static DerivedFlags derive({
    required List<OcrBlock> blocks,
    required int imageWidth,
    required int imageHeight,
  }) {
    final keywords = <String>[];

    bool hasModal = false;
    bool hasError = false;

    for (final block in blocks) {
      final t = _normalize(block.text);
      if (t.isEmpty) continue;

      for (final w in _modalWords) {
        if (t.contains(w)) {
          keywords.add(w);
          hasModal = true;
        }
      }
      for (final w in _errorWords) {
        if (t.contains(w)) {
          hasError = true;
        }
      }
    }

    // Geometry heuristic: text clustered near center often indicates a modal.
    if (!hasModal && imageWidth > 0 && imageHeight > 0) {
      final centerHits = blocks.where((b) {
        final cx = (b.boundingBox.left + b.boundingBox.right) / 2;
        final cy = (b.boundingBox.top + b.boundingBox.bottom) / 2;
        final nx = cx / imageWidth;
        final ny = cy / imageHeight;
        return nx >= 0.25 && nx <= 0.75 && ny >= 0.25 && ny <= 0.75;
      }).length;
      if (centerHits >= 3) hasModal = true;
    }

    return DerivedFlags(
      hasModalCandidate: hasModal,
      hasErrorCandidate: hasError,
      modalKeywords: keywords.toSet().toList()..sort(),
    );
  }

  static String _normalize(String s) {
    return s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }
}
