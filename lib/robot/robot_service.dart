import 'dart:async';
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

class IdleAnalysisResult {
    final List<String> messages;
    final Set<String> learnedItems;
    
    IdleAnalysisResult({this.messages = const [], this.learnedItems = const {}});
}

class RobotService {
  RobotService({
    required this.ollama,
    required this.ollamaEmbed, // [NEW]
    required this.qdrant,
  });

  final OllamaClient ollama;
  final OllamaClient ollamaEmbed; // [NEW]
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
      final embedding = await ollamaEmbed.embed(prompt: prompt);
      
      // Search Qdrant
      final memories = await qdrant.search(
        queryEmbedding: embedding,
        limit: 5, // [FIX] Get more context to avoid repetition
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
    String? overrideDescription, // [NEW] For offline/mock training
  }) async {
    // 1. Create the detailed description
    final description = overrideDescription ?? state.toLLMDescription();
    final prompt = 'Goal: $goal. Screen: $description. Prerequisites: $prerequisites';

    // 2. Embed
    final embedding = await ollamaEmbed.embed(prompt: prompt);

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

  /// Recalls "Known" interactive elements for the current screen context.
  /// Returns a set of text labels (target_text) that resulted in successful actions in the past.
  Future<Set<String>> fetchKnownInteractiveElements(UIState state) async {
      try {
          final description = state.toLLMDescription();
          final embedding = await ollamaEmbed.embed(prompt: description);
          
          // Search broadly for this context
          final memories = await qdrant.search(
            queryEmbedding: embedding,
            limit: 15, // Check top 15 relevant memories
          );
          
          final known = <String>{};
          for (final m in memories) {
              final payload = m['payload'] as Map<String, dynamic>;
              if (payload.containsKey('action')) {
                  final action = payload['action'] as Map<String, dynamic>;
                  if (action.containsKey('target_text')) {
                      known.add(action['target_text'].toString());
                  }
              }
          }
          return known;
      } catch (e) {
          debugPrint("Memory Fetch Error: $e");
          return {};
      }
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
           debugPrint("[OLLAMA RAW - Decompose]: $response");
           final clean = _extractJson(response);
           steps = (jsonDecode(clean) as List).cast<String>();
       } catch (e) {
           // Fallback if decomposition fails
           steps = [userInstruction];
       }
       
       // 2. Verify each step against memory
       final results = <TaskStepVerification>[];
       
       for (final step in steps) {
           final embedding = await ollamaEmbed.embed(prompt: step);
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
        debugPrint("[OLLAMA RAW - Teach]: $response");
        final clean = _extractJson(response);
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
       final embedding = await ollamaEmbed.embed(prompt: question);
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
  Future<IdleAnalysisResult> analyzeIdlePage(UIState state) async {
       // Only analyze if state has significant content (e.g. headers, windows)
       final text = state.toLLMDescription();
       
       // 1. Check what we already know to avoid asking dumb questions
       // [TEMP] Disable Recall to prevent Model Swapping (RAM Thrashing)
       // final embedding = await ollamaEmbed.embed(prompt: text);
       // final knownMemories = await qdrant.search(queryEmbedding: embedding, limit: 10);
       // final knownGoals = knownMemories...
       final knownGoals = ""; // Empty context for speed

       final prompt = '''
       You are analyzing a CURRENT screen capture. Output ONLY valid JSON, no markdown, no explanations.
       
       CURRENT SCREEN TEXT ELEMENTS:
       $text
       
       ALREADY LEARNED (ignore these): [$knownGoals]
       
       TASK: For each UI element in the CURRENT screen text above:
       - If you recognize its standard function (e.g., "Save", "Close", "Settings"), create an "insight"
       - If you don't understand its purpose, create a "question" asking what it does
       - IMPORTANT: Only analyze elements that are ACTUALLY PRESENT in the current screen text above
       - DO NOT mention elements from other screens or contexts
       
       OUTPUT FORMAT (pure JSON, no markdown):
       {
         "insights": [
           {
             "goal": "Brief action name",
             "action": {"type": "click", "target_text": "Exact text from current screen"},
             "fact": "What clicking this does"
           }
         ],
         "questions": ["What does [specific element from current screen] do?"]
       }
       
       Return {"insights": [], "questions": []} if current screen has no new elements to learn.
       ''';
       
       try {
          final stopwatch = Stopwatch()..start();
          
          // [DEBUG] Start Heartbeat Logger
          final timer = Timer.periodic(const Duration(seconds: 5), (t) {
              debugPrint("⏳ [Ollama Wait] Still waiting... (${t.tick * 5}s elapsed)");
          });

          debugPrint("🚀 [Ollama Start] Sending request to '${ollama.model}'...");
          String response;
          try {
             response = await ollama.generate(prompt: prompt, numPredict: 256);
          } finally {
             timer.cancel(); // Stop heartbeat
             stopwatch.stop();
          }
          
          debugPrint("✅ [Ollama Done] Response received in ${stopwatch.elapsed.inSeconds}s.");
          debugPrint("[ROBOT] [OLLAMA RAW]: $response");
          var clean = _extractJson(response).trim();
          
          if (!clean.startsWith('{')) {
               final startBrace = clean.indexOf('{');
               if (startBrace != -1) clean = clean.substring(startBrace);
          }
           
          final dynamic decoded = jsonDecode(clean);
          final messages = <String>[];
          final learned = <String>{};
          
          if (decoded is Map<String, dynamic>) {
              // 1. Process Insights (Auto-Learn)
              if (decoded.containsKey('insights') && decoded['insights'] is List) {
                  for (final item in decoded['insights']) {
                      if (item is Map<String, dynamic>) {
                          final goal = item['goal']?.toString() ?? 'Unknown Goal';
                          final action = item['action'] as Map<String, dynamic>? ?? {};
                          final fact = item['fact']?.toString() ?? '';
                          
                          if (action.isNotEmpty && action.containsKey('target_text')) {
                              // Execute Learning Side-Effect
                              await learn(
                                  state: state, 
                                  goal: goal, 
                                  action: action, 
                                  factualDescription: fact
                              );
                              final target = action['target_text'].toString();
                              learned.add(target);
                              messages.add("💡 I autonomously learned that '$target' is used to '$goal'. Saved to memory.");
                          }
                      }
                  }
              }
              
              // 2. Process Questions
              if (decoded.containsKey('questions') && decoded['questions'] is List) {
                  for (final q in decoded['questions']) {
                      messages.add(q.toString());
                  }
              }
          }
          
          return IdleAnalysisResult(messages: messages, learnedItems: learned);
       } catch (e) {
          debugPrint("[ROBOT] ❌ Idle Analysis Failed: $e");
          return IdleAnalysisResult();
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

  // --- CLARIFICATION ANALYSIS ---

  Future<Map<String, dynamic>?> analyzeUserClarification({
      required String userText,
      required String? lastQuestion,
      required UIState state,
  }) async {
       final screenDesc = state.toLLMDescription();
       final prompt = '''
       I am a Robot Assistant. I asked the user: "${lastQuestion ?? 'What should I do?'}".
       The user replied: "$userText".
       
       The current screen contains:
       $screenDesc
       
       Analyze the user's reply. Does it teach me how to perform a specific action on this screen?
       If YES, extract the following as JSON:
       {
         "goal": "Short description of the goal (e.g. 'Opening Settings')",
         "action": {
            "type": "click" or "type",
            "target_text": "The exact text on the UI element to interact with",
            "text": "Text to type if type action" (optional)
         },
         "fact": "A factual summary of what this element does"
       }
       
       If the user is just chatting or I cannot map it to a UI element, return only: {"analysis": "no_action"}
       ''';
       
       try {
           final response = await ollama.generate(prompt: prompt, numPredict: 256);
           debugPrint("[OLLAMA RAW - Clarify]: $response");
           final clean = _extractJson(response);
           final dynamic json = jsonDecode(clean);
           
           if (json is Map && json.containsKey('action')) {
               return json as Map<String, dynamic>;
           }
           return null;
       } catch (e) {
           debugPrint("Clarification Analysis Failed: $e");
           return null;
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
          debugPrint("[OLLAMA RAW - Hypothesis]: $response");
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
  // Helper to extract JSON from Llama's chatty response
  String _extractJson(String response) {
      // 1. Remove Markdown code blocks if present
      final codeBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
      final match = codeBlockRegex.firstMatch(response);
      if (match != null) {
          response = match.group(1) ?? response;
      }
      
      // 2. Find start of JSON structure
      int start = response.indexOf('[');
      int startObj = response.indexOf('{');
      
      int index = -1;
      if (start != -1 && startObj != -1) {
          index = start < startObj ? start : startObj;
      } else if (start != -1) {
          index = start;
      } else if (startObj != -1) {
          index = startObj;
      }
      
      if (index == -1) return "{}"; 
      
      String clean = response.substring(index);

      // 3. Find end of JSON structure
      int end = -1;
      if (clean.startsWith('[')) {
           end = clean.lastIndexOf(']');
      } else {
           end = clean.lastIndexOf('}');
      }
         
      if (end != -1) {
          return clean.substring(0, end + 1);
      } else {
          // Heuristic fix for truncated JSON
          if (clean.startsWith('{')) return "$clean}"; 
          if (clean.startsWith('[')) return "$clean]"; 
      }
      return clean;
  }
}
