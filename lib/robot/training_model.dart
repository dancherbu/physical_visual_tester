import 'dart:convert';
import '../vision/ocr_models.dart';

enum TrainingEventType {
  none,
  start,
  navigation,   // Significant screen change
  typing,       // Text content change in small area
  click,        // Inferred click (state change)
  idle_analysis // Generated during idle time
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
}

class TrainingFrame {
  final String id;
  final DateTime timestamp;
  final String imagePath; 
  final UIState? uiState; 
  final TrainingEventType eventType; // [NEW] Why was this recorded?
  TrainingHypothesis? hypothesis;

  TrainingFrame({
    required this.id,
    required this.timestamp,
    required this.imagePath,
    this.uiState,
    this.eventType = TrainingEventType.none,
    this.hypothesis,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'imagePath': imagePath,
    'uiState': uiState?.toJson(),
    'eventType': eventType.toString(),
    if (hypothesis != null) 'hypothesis': hypothesis!.toJson(),
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

// [NEW] For Task Review Checklist
class TaskStepVerification {
    final String stepDescription;
    final bool isKnown;
    final double confidence; // 0.0 to 1.0

    TaskStepVerification({
        required this.stepDescription,
        required this.isKnown,
        required this.confidence,
    });
}
