import '../vision/ocr_models.dart';

enum TrainingEventType {
  none,
  start,
  navigation,   // Significant screen change
  typing,       // Text content change in small area
  click,        // Inferred click (state change)
  idleAnalysis, // Generated during idle time
  hidAction,    // Direct HID action recorded
}

class TrainingSession {
  final String id;
  final String name;
  final DateTime startTime;
  final List<TrainingFrame> frames;

  TrainingSession({
    required this.id,
    required this.name,
    required this.startTime,
    required this.frames,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'startTime': startTime.toIso8601String(),
    'frames': frames.map((f) => f.toJson()).toList(),
  };

  /// Generates a human-readable summary of the session.
  String toSummary() {
    final buffer = StringBuffer();
    buffer.writeln('Session: "$name" (${frames.length} steps)');
    for (int i = 0; i < frames.length; i++) {
      final frame = frames[i];
      String actionStr;
      
      if (frame.recordedAction != null) {
        actionStr = frame.recordedAction.toString();
      } else if (frame.hypothesis?.suggestedAction != null) {
        final action = frame.hypothesis!.suggestedAction!;
        actionStr = '${action['type']} "${action['target_text'] ?? action['input'] ?? ''}"';
      } else {
        actionStr = frame.eventType.toString().split('.').last;
      }
      
      buffer.writeln('  ${i + 1}. $actionStr');
    }
    return buffer.toString();
  }
}

class TrainingFrame {
  final String id;
  final DateTime timestamp;
  final String imagePath; 
  final UIState? uiState; 
  final TrainingEventType eventType; // [NEW] Why was this recorded?
  TrainingHypothesis? hypothesis;
  
  /// Actual recorded HID action (for enhanced recording mode).
  /// If set, this takes precedence over hypothesis.suggestedAction.
  final RecordedHidAction? recordedAction;

  TrainingFrame({
    required this.id,
    required this.timestamp,
    required this.imagePath,
    this.uiState,
    this.eventType = TrainingEventType.none,
    this.hypothesis,
    this.recordedAction,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'imagePath': imagePath,
    'uiState': uiState?.toJson(),
    'eventType': eventType.toString(),
    if (hypothesis != null) 'hypothesis': hypothesis!.toJson(),
    if (recordedAction != null) 'recordedAction': recordedAction!.toJson(),
  };
}

class TrainingHypothesis {
    final String description; 
    final Map<String, dynamic>? suggestedAction; 
    final List<String> prerequisites; 
    final String goal; 

    TrainingHypothesis({
       required this.description,
       this.suggestedAction,
       this.prerequisites = const [],
       required this.goal
    });

    Map<String, dynamic> toJson() => {
       'description': description,
       'suggestedAction': suggestedAction,
       'prerequisites': prerequisites,
       'goal': goal,
    };
}

// ============================================================
// RECORDED HID ACTION - Phase 2.5 Enhanced Recording
// ============================================================

/// Represents an actual HID action recorded during a training session.
/// 
/// This is captured directly from HID events, not inferred from screen changes.
class RecordedHidAction {
  final String type; // click, type, key, mouse_move, etc.
  final int? x;
  final int? y;
  final String? input; // For type/key actions
  final String? targetText; // OCR text at click location (if found)
  final DateTime timestamp;

  RecordedHidAction({
    required this.type,
    this.x,
    this.y,
    this.input,
    this.targetText,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (input != null) 'input': input,
    if (targetText != null) 'target_text': targetText,
    'timestamp': timestamp.toIso8601String(),
  };

  /// Converts to the standard action format used by sequences.
  Map<String, dynamic> toActionPayload() => {
    'type': type,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (input != null) 'input': input,
    if (targetText != null) 'target_text': targetText,
  };

  @override
  String toString() {
    if (type == 'click' && targetText != null) {
      return 'Click "$targetText"';
    } else if (type == 'type' && input != null) {
      return 'Type "$input"';
    } else if (type == 'key' && input != null) {
      return 'Press $input';
    } else {
      return '$type at ($x, $y)';
    }
  }
}

// [NEW] For Task Review Checklist
class TaskStepVerification {
    final String stepDescription;
    final bool isKnown;
    final double confidence; // 0.0 to 1.0
  final String? targetText;
  final bool? contextVisible;
  final String? note;

    TaskStepVerification({
        required this.stepDescription,
        required this.isKnown,
        required this.confidence,
      this.targetText,
      this.contextVisible,
      this.note,
    });
}
