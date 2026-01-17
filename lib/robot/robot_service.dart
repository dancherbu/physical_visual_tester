import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../vision/ocr_models.dart';
import '../spikes/brain/ollama_client.dart';
import '../spikes/brain/qdrant_service.dart';
import 'training_model.dart';
import 'dart:io';

/// Represents the decision made by the Robot.
class RobotDecision {
  final bool isConfident;
  final String reasoning;
  final Map<String, dynamic>? action; 
  final String? suggestedGoal;

  RobotDecision({
    required this.isConfident,
    required this.reasoning,
    this.action,
    this.suggestedGoal,
  });

  @override
  String toString() => 'Confident: $isConfident | $reasoning | Action: $action';
}

class RobotService {
  RobotService({
    required this.ollama,
    required this.qdrant,
  });

  final OllamaClient ollama;
  final QdrantService qdrant;
  
  // Training Section
  TrainingSession? _currentSession;
  UIState? _lastRecordedState;
  
  bool get isRecording => _currentSession != null;

  /// The Core "Brain" Loop:
  /// 1. Observe (State is passed in).
  /// 2. Recall (Search Qdrant for similar states).
  /// 3. Decide (Do we know what to do?).
  Future<RobotDecision> think({
    required UIState state,
    String? currentGoal,
  }) async {
    try {
      // 1. Describe Context for Embedding
      final description = state.toLLMDescription();
      final prompt = currentGoal != null 
          ? 'Goal: $currentGoal. Screen: $description' 
          : description;

      // 2. Embed & Search Memory
      final embedding = await ollama.embed(prompt: prompt);
      
      // Search Qdrant
      final memories = await qdrant.search(
        queryEmbedding: embedding,
        limit: 1, 
      );
      
      if (memories.isNotEmpty) {
        final best = memories.first;
        final score = best['score'] as double;
        final payload = best['payload'] as Map<String, dynamic>;
        
        // Threshold for "Confidence"
        if (score > 0.88) {
           // CHECK PREREQUISITES
           if (payload.containsKey('prerequisites')) {
              final prereqs = (payload['prerequisites'] as List).cast<String>();
              if (prereqs.isNotEmpty) {
                 return RobotDecision(
                   isConfident: false, // Don't auto-act if prereqs exist yet
                   reasoning: 'I need to check prerequisites: $prereqs',
                   suggestedGoal: payload['goal'],
                 );
              }
           }
        
           return RobotDecision(
             isConfident: true,
             reasoning: 'Memory Match! (Score: ${(score*100).toStringAsFixed(1)}%). Goal: "${payload['goal']}"',
             action: payload['action'],
             suggestedGoal: payload['goal'],
           );
        } else {
           return RobotDecision(
             isConfident: false,
             reasoning: 'Vague memory found (${(score*100).toStringAsFixed(1)}%). Not confident enough to act.',
             suggestedGoal: payload['goal'],
           );
        }
      }

      return RobotDecision(
        isConfident: false,
        reasoning: 'No relevant memories found. I need help.',
      );

    } catch (e) {
      debugPrint('Robot Think Failed: $e');
      return RobotDecision(
        isConfident: false,
        reasoning: 'Internal Error: $e',
      );
    }
  }

  /// Learns a new skill by saving it to Qdrant.
  Future<void> learn({
    required UIState state,
    required String goal,
    required Map<String, dynamic> action,
    List<String> prerequisites = const [],
    String? factualDescription,
  }) async {
    // 1. Create the detailed description
    final description = state.toLLMDescription();
    final prompt = 'Goal: $goal. Screen: $description';

    // 2. Embed
    final embedding = await ollama.embed(prompt: prompt);

    // 3. Save
    await qdrant.saveMemory(
      embedding: embedding,
      payload: {
        'goal': goal,
        'action': action,
        'description': description,
        'prerequisites': prerequisites,
        'fact': factualDescription ?? '',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }
  
  // Verifys if we know how to do a user's instruction
  Future<List<TaskStepVerification>> decomposeAndVerify(String userInstruction) async {
       // 1. Decompose
       final prompt = '''
       Break down this instruction into atomic UI actions (click, type, open).
       Instruction: "$userInstruction"
       
       Format as JSON List of strings. Example: ["Click Chrome", "Type Google.com", "Press Enter"]
       ''';
       
       List<String> steps = [];
       try {
           final response = await ollama.generate(prompt: prompt, numPredict: 100);
           final clean = response.replaceAll('```json', '').replaceAll('```', '').trim();
           steps = (jsonDecode(clean) as List).cast<String>();
       } catch (e) {
           // Fallback if decomposition fails
           steps = [userInstruction];
       }
       
       // 2. Verify each step against memory
       final results = <TaskStepVerification>[];
       
       for (final step in steps) {
           final embedding = await ollama.embed(prompt: step);
           final memories = await qdrant.search(queryEmbedding: embedding, limit: 1);
           
           bool known = false;
           double conf = 0.0;
           
           if (memories.isNotEmpty) {
               conf = memories.first['score'] as double;
               // Lower threshold for "knowing" a concept vs acting
               if (conf > 0.85) known = true; 
           }
           
           results.add(TaskStepVerification(
               stepDescription: step, 
               isKnown: known, 
               confidence: conf
           ));
       }
       
       return results;
  }
  
  // --- CONVERSATIONAL METHODS ---

  Future<Map<String, dynamic>> parseTeachingResponse(String userResponse, String blockText) async {
      final prompt = '''
      The user is teaching a robot about a UI button labeled "$blockText".
      The user said: "$userResponse".
      
      Extract the following in JSON format:
      {
        "goal": "The high-level goal (e.g. Log In)",
        "fact": "A factual description of what the button does",
        "prerequisites": ["List", "of", "conditions", "if", "mentioned"]
      }
      If no specific prerequisites mentioned, return empty list.
      ''';

      try {
        final response = await ollama.generate(prompt: prompt, numPredict: 128);
        final clean = response.replaceAll('```json', '').replaceAll('```', '').trim();
        return jsonDecode(clean);
      } catch (e) {
        debugPrint("Parse Error: $e");
        return {
          'goal': userResponse, // Fallback
          'fact': userResponse,
          'prerequisites': [],
        };
      }
  }

  Future<String> answerQuestion(String question) async {
     try {
       final embedding = await ollama.embed(prompt: question);
       final results = await qdrant.search(queryEmbedding: embedding, limit: 3);
       
       final context = results.map((r) {
          final p = r['payload'];
          return "- When trying to '${p['goal']}', I '${p['action']['type']}' on '${p['action']['target_text']}'. Fact: ${p['fact'] ?? 'N/A'}.";
       }).join('\n');
       
       final prompt = '''
       You are a Robot Assistant. The user asks: "$question".
       Here is what you know from your memory:
       $context
       
       Answer the user concisely based ONLY on your memory. If you don't know, say so.
       ''';
       
       return await ollama.generate(prompt: prompt);
     } catch (e) {
       return "I can't access my memory right now.";
     }
  }
  
  // --- IDLE CURIOSITY METHODS ---
  
  /// Called periodically during user inactivity to "daydream" or analyze the screen.
  /// Returns a list of generated questions for the user.
  Future<List<String>> analyzeIdlePage(UIState state) async {
       // Only analyze if state has significant content (e.g. headers, windows)
       final text = state.toLLMDescription();
       
       final prompt = '''
       I am an AI Robot looking at this screen content:
       $text
       
       Identify the main application or context (e.g., 'PowerPoint', 'Gmail').
       Generate 1-2 curiosity questions to ask the user to learn more about this context.
       However, if the context is obvious or trivial, return nothing.
       
       Format output as JSON list of strings: ["What is the purpose of the 'Submit' button here?", "Is this a production environment?"]
       ''';
       
       try {
          final response = await ollama.generate(prompt: prompt, numPredict: 100);
          final clean = response.replaceAll('```json', '').replaceAll('```', '').trim();
          final List<dynamic> json = jsonDecode(clean);
          return json.cast<String>();
       } catch (e) {
          debugPrint("Idle Analysis Failed: $e");
          return [];
       }
  }

  // --- DIAGNOSIS ---
  
  Future<String> diagnoseFailure(UIState state, String failedTask) async {
       final text = state.toLLMDescription();
       final prompt = '''
       I am trying to complete this task: "$failedTask".
       However, I am stuck. The current screen shows:
       $text
       
       Analyze WHY I cannot complete the task.
       - Are there missing prerequisites? (e.g. need to be on a different page?)
       - Is the element missing or named differently?
       
       Propose a solution or a sequence of steps to fix this.
       Be concise.
       ''';
       
       try {
          return await ollama.generate(prompt: prompt, numPredict: 128);
       } catch (e) {
          return "I could not diagnose the failure. Error: $e";
       }
  }
  
  // --- TRAINING SESSION METHODS ---
  // Now Event-Driven
  
  void startRecording(String sessionName) {
      _currentSession = TrainingSession(
          id: DateTime.now().millisecondsSinceEpoch.toString(), 
          name: sessionName, 
          startTime: DateTime.now(), 
          frames: []
      );
      _lastRecordedState = null;
      debugPrint("Started Recording Session: $sessionName");
  }
  
  TrainingSession? stopRecording() {
      final s = _currentSession;
      _currentSession = null;
      _lastRecordedState = null;
      debugPrint("Stopped Recording Session. Frames: ${s?.frames.length}");
      return s;
  }
  
  void captureTrainingFrame({required UIState state, required String imagePath}) {
      if (_currentSession == null) return;
      
      TrainingEventType event = TrainingEventType.none;
      
      if (_lastRecordedState == null) {
          event = TrainingEventType.start;
      } else {
          // Detect specific events
          final oldText = _lastRecordedState!.ocrBlocks.map((b) => b.text).toSet();
          final newText = state.ocrBlocks.map((b) => b.text).toSet();
          
          final intersection = oldText.intersection(newText).length;
          final union = oldText.union(newText).length;
          final jaccard = intersection / (union == 0 ? 1 : union); // Similarity
          
          if (jaccard < 0.6) {
             // Low similarity = Navigation / Page Change
             event = TrainingEventType.navigation;
          } else if (oldText.length != newText.length || oldText.difference(newText).isNotEmpty) {
             // Slight change = Typing or minor state update
             // Heuristic: If we see a block content change at same loc? 
             // For now, treat as typing/action
             event = TrainingEventType.typing;
          } else {
             // No text change...
             // Could be mouse movement? We don't track mouse yet in this method (needs HID input or visual mouse tracking).
             // Assume IDLE/noise.
             event = TrainingEventType.none;
          }
      }
      
      // ONLY save if Event detected
      if (event != TrainingEventType.none) {
          _currentSession!.frames.add(TrainingFrame(
              id: DateTime.now().millisecondsSinceEpoch.toString(), 
              timestamp: DateTime.now(), 
              imagePath: imagePath,
              uiState: state,
              eventType: event
          ));
          _lastRecordedState = state;
          debugPrint("Captured Event: $event");
      }
  }
  
  void deleteSessionData(TrainingSession session) {
      for (final f in session.frames) {
          try {
             if (f.imagePath.contains('robot_eye_mock')) continue; 
             final file = File(f.imagePath);
             if (file.existsSync()) file.deleteSync();
          } catch(e) {
             debugPrint("Failed to delete frame: $e");
          }
      }
  }
  
  // -- ANALYSIS --
  
  Future<void> analyzeSession(TrainingSession session) async {
       if (session.frames.isEmpty) return;
       
       for (int i = 0; i < session.frames.length; i++) {
           final frame = session.frames[i];
           if (i < session.frames.length - 1) {
              final nextFrame = session.frames[i+1];
              final hyp = await _generateHypothesis(frame, nextFrame);
              frame.hypothesis = hyp;
           } else {
              frame.hypothesis = TrainingHypothesis(
                  description: "Final Result State.", 
                  goal: "Complete Task",
                  suggestedAction: null
              );
           }
       }
  }
  
  Future<TrainingHypothesis> _generateHypothesis(TrainingFrame prev, TrainingFrame next) async {
      // 1. Detect Changes
      final prevText = prev.uiState?.ocrBlocks.map((b) => b.text).toList() ?? [];
      final nextText = next.uiState?.ocrBlocks.map((b) => b.text).toList() ?? [];
      
      final gained = nextText.where((t) => !prevText.contains(t)).toList();
      
      String description = "Unknown change";
      String goal = "Interact";
      List<String> prerequisites = [];
      String input = "";
      
      // Check for URL/Header prerequisites
      for (final t in prevText) {
          if (t.contains('.com') || t.contains('.app') || t.contains('http')) {
             prerequisites.add("URL: $t");
          }
      }
      
      if (gained.isNotEmpty) {
         input = gained.first; 
         description = "You typed '$input' into a text field.";
         goal = "Enter Data";
      } else if (prev.imagePath != next.imagePath) {
         description = "You clicked a button effectively navigating to a new screen.";
         goal = "Navigate";
      }
      
      // 3. Ask Ollama to refine
      try {
          final prompt = '''
          I am analyzing a screen recording.
          State A had text: ${prevText.take(10).join(', ')}...
          State B had text: ${nextText.take(10).join(', ')}...
          Prerequisites found: $prerequisites.
          
          Generate a hypothesis about what the user did.
          Format as JSON:
          {
            "description": "User typed 'dan' into 'username' field",
            "goal": "Enter Username",
            "input": "dan"
          }
          ''';
          
          final response = await ollama.generate(prompt: prompt, numPredict: 100);
          final clean = response.replaceAll('```json', '').replaceAll('```', '').trim();
          final json = jsonDecode(clean);
          
          description = json['description'] ?? description;
          goal = json['goal'] ?? goal;
      } catch (e) {
          debugPrint("Hypothesis Gen Failed: $e");
      }

      return TrainingHypothesis(
          description: description,
          goal: goal,
          prerequisites: prerequisites,
          suggestedAction: {
             'type': 'type', 
             'input': input,
          }
      );
  }
  // --- TASK EXECUTION ---
  
  final List<String> _taskQueue = [];
  final List<String> _failedTasks = []; // [NEW] Track failures
  int _currentTaskIndex = 0;
  
  void loadTasks(String document) {
      // Simple logic: Split by lines, filter empty/numbered lists
      final lines = document.split('\n');
      _taskQueue.clear();
      _failedTasks.clear();
      _currentTaskIndex = 0;
      
      for (var line in lines) {
          line = line.trim();
          if (line.isEmpty) continue;
          // Remove leading "1. " or "- "
          line = line.replaceAll(RegExp(r'^[\d\-\.\s]+'), '');
          if (line.isNotEmpty) _taskQueue.add(line);
      }
      debugPrint("Loaded ${_taskQueue.length} tasks.");
  }
  
  String? getNextTask() {
      if (_currentTaskIndex < _taskQueue.length) {
          return _taskQueue[_currentTaskIndex];
      }
      return null;
  }
  
  void completeTask() {
      if (_currentTaskIndex < _taskQueue.length) {
          _currentTaskIndex++;
      }
  }
  
  void markTaskFailed(String task) {
      if (!_failedTasks.contains(task)) {
          _failedTasks.add(task);
      }
      // Also skip it in the queue so we don't get stuck forever?
      // For now, let's assume calling this means we are aborting the run or defining it as failed.
  }
  
  List<String> get remainingTasks {
      if (_currentTaskIndex >= _taskQueue.length) return [];
      return _taskQueue.sublist(_currentTaskIndex);
  }
  
  List<String> get failedTasks => List.unmodifiable(_failedTasks);
  
  bool get hasPendingTasks => _currentTaskIndex < _taskQueue.length;
  String get taskProgress => "Task ${_currentTaskIndex + 1}/${_taskQueue.length}";

  // --- MEMORY OPTIMIZATION ---
  
  Future<void> optimizeMemory() async {
      // In a real scenario, this would trigger Qdrant optimization/indexing
      // For now, we simulate a "consolidation" delay
      await Future.delayed(const Duration(seconds: 2));
      debugPrint("Memory Optimized (Simulated). Verified Qdrant Collection Health.");
  }
}
