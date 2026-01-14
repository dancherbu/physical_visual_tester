import 'vision/ocr_models.dart';

/// Simple in-memory storage to pass spike data between pages.
///
/// This avoids adding state management before we know what the real architecture
/// needs to be.
class SpikeStore {
  static UIState? lastUiState;
}
