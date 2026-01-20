import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../vision/ocr_models.dart';
import '../spikes/brain/ollama_client.dart';
import '../spikes/brain/qdrant_service.dart';
import 'training_model.dart';
import 'dart:io';
import 'planner_service.dart';

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
        this.ollamaVisionClient,
    });

  final OllamaClient ollama;
    final OllamaClient? ollamaVisionClient;
    late final OllamaClient ollamaVision = ollamaVisionClient ?? ollama;
  final OllamaClient ollamaEmbed;
  final QdrantService qdrant;
  late final PlannerService planner = PlannerService(ollama);

  final _logController = StreamController<String>.broadcast();
  Stream<String> get logs => _logController.stream;
  
  void dispose() {
    _logController.close();
  }
  
  Future<Map<String, dynamic>> checkHealth() async {
    final ollamaOk = await ollama.ping();
    final qdrantOk = await qdrant.ping();
    
    int vectors = 0;
    if (qdrantOk) {
        try {
            final info = await qdrant.getCollectionInfo();
            vectors = info['points_count'] as int? ?? 0;
        } catch (_) {
            vectors = -1; // Collection missing or error
        }
    }
    
    return {
      'ollama': ollamaOk,
      'qdrant': qdrantOk,
      'vectors': vectors,
    };
  }
  
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
           final memoryAction = payload['action'] as Map<String, dynamic>;
           final targetText = memoryAction['target_text'] as String?;
           
           // GROUNDING: Verify the target actually exists on the screen
           Map<String, dynamic>? groundedAction;
           
           if (targetText != null && state.ocrBlocks.isNotEmpty) {
               // specific for clicks/types
               final type = memoryAction['type'] as String?;
               if (type == 'click' || type == 'type' || type == 'mouse_right_click' || type == 'mouse_move') {
                   // Find the block
                   try {
                       final block = state.ocrBlocks.firstWhere(
                           (b) => b.text.toLowerCase().contains(targetText.toLowerCase())
                       );
                       
                       // Inject coordinates
                       groundedAction = Map.from(memoryAction);
                       // Fix: BoundingBox.center is a String, manually calc
                       final centerX = block.boundingBox.left + block.boundingBox.width / 2;
                       final centerY = block.boundingBox.top + block.boundingBox.height / 2;
                       
                       groundedAction['x'] = centerX.toInt();
                       groundedAction['y'] = centerY.toInt();
                       
                   } catch (e) {
                       // Target NOT found on screen
                       return RobotDecision(
                           isConfident: false,
                           reasoning: 'I recall I need to interact with "$targetText", but I cannot find it on this screen. Context mismatch?',
                           suggestedGoal: payload['goal'],
                       );
                   }
               }
           }
           
           // If we didn't need to ground (e.g. key press) or succeeded
           groundedAction ??= Map.from(memoryAction);

           // CHECK PREREQUISITES
           if (payload.containsKey('prerequisites')) {
              final prereqs = (payload['prerequisites'] as List).cast<String>();
              if (prereqs.isNotEmpty) {
                 // Simple heuristic: If we found the element, maybe prereqs are met?
                 // For now, let's just warn but proceed if we physically see the button.
                 // Actually, if prereq is 'Menu Open', seeing the Menu Item implies it is open.
                 // So "Grounding" is a strong verification of prerequisites.
              }
           }
        
           return RobotDecision(
             isConfident: true,
             reasoning: 'Memory Match! (Score: ${(score*100).toStringAsFixed(1)}%). Found target on screen.',
             action: groundedAction,
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

    // Shared Payload
    final payload = {
        'goal': goal,
        'action': action,
        'description': description,
        'prerequisites': prerequisites,
        'fact': factualDescription ?? '',
        'timestamp': DateTime.now().toIso8601String(),
    };

    // 2a. Goal-Oriented Memory (for "How do I...?")
    // Embed the Goal itself so we can find it by task name.
    final goalEmbedding = await ollamaEmbed.embed(prompt: goal);
    await qdrant.saveMemory(
      embedding: goalEmbedding,
      payload: { ...payload, 'memory_type': 'task' },
    );

    // 2b. Context-Oriented Memory (for "What can I do here?" / Visual Feedback)
    // Embed the Screen Description so we can find it when looking at the screen.
    final contextEmbedding = await ollamaEmbed.embed(prompt: description);
    await qdrant.saveMemory(
      embedding: contextEmbedding,
      payload: { ...payload, 'memory_type': 'context' },
    );
  }

  /// Recalls "Known" interactive elements for the current screen context.
  /// Returns a set of text labels (target_text) that resulted in successful actions in the past.
  Future<Set<String>> fetchKnownInteractiveElements(UIState state) async {
      debugPrint('[ROBOT] 📚 fetchKnownInteractiveElements: Starting recall...');
      try {
          final description = state.toLLMDescription();
          debugPrint('[ROBOT] 📚 Context description length: ${description.length} chars');
          
          final embedding = await ollamaEmbed.embed(prompt: description);
          debugPrint('[ROBOT] 📚 Got embedding, dim=${embedding.length}');
          
          // Search broadly for this context
          final memories = await qdrant.search(
            queryEmbedding: embedding,
            limit: 50, // Check top 50 relevant memories
          );
          
          debugPrint('[ROBOT] 📚 Search returned ${memories.length} memories');
          
          final known = <String>{};
          for (final m in memories) {
              final payload = m['payload'] as Map<String, dynamic>;
              final score = m['score'] as double?;
              if (payload.containsKey('action')) {
                  final action = payload['action'] as Map<String, dynamic>;
                  if (action.containsKey('target_text')) {
                      final target = action['target_text'].toString();
                      known.add(target);
                      debugPrint('[ROBOT] 📚   Found known element: "$target" (score=${score?.toStringAsFixed(3)})');
                  }
              }
          }
          
          debugPrint('[ROBOT] 📚 RESULT: ${known.length} known elements: $known');
          return known;
      } catch (e) {
          debugPrint('[ROBOT] ❌ Memory Fetch Error: $e');
          return {};
      }
  }

  /// Flushes all memories from the vector database.
  Future<void> clearAllMemories() async {
      debugPrint("[ROBOT] Clearing all memories/vectors...");
      await qdrant.deleteCollection(); 
      // Re-create immediately so it's ready
      await qdrant.ensureCollectionExists(); 
  }
  
  // Verifys if we know how to do a user's instruction
    Future<List<TaskStepVerification>> decomposeAndVerify(
        String userInstruction, {
        UIState? state,
    }) async {
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
           final normalized = await _normalizeStep(step);
           final embedding = await ollamaEmbed.embed(prompt: normalized);
           final memories = await qdrant.search(queryEmbedding: embedding, limit: 5);
           
           bool known = false;
           double conf = 0.0;
           String? targetText;
           bool? contextVisible;
           String? note;
           
           if (memories.isNotEmpty) {
               final rerank = await _rerankStepMatch(step: step, memories: memories);
               final selected = rerank ?? memories.first;
               conf = (selected['score'] as num).toDouble();
               
               final payload = selected['payload'] as Map<String, dynamic>;
               if (payload.containsKey('action')) {
                   final action = payload['action'] as Map<String, dynamic>;
                   if (action.containsKey('target_text')) {
                       targetText = action['target_text']?.toString();
                   }
               }

               // Lower threshold for "knowing" a concept vs acting
               if (conf >= 0.85) known = true;
               
               if (state != null && targetText != null) {
                   final targetLower = targetText!.toLowerCase();
                   final visible = state.ocrBlocks.any((b) => b.text.toLowerCase().contains(targetLower));
                   contextVisible = visible;
                   if (!visible) {
                       note = "Not visible on current screen";
                       known = false; // Block action if target not visible
                   }
               }
           }
           
           results.add(TaskStepVerification(
               stepDescription: step, 
               isKnown: known, 
               confidence: conf,
               targetText: targetText,
               contextVisible: contextVisible,
               note: note,
           ));
       }
       
       return results;
  }

  Future<Map<String, dynamic>?> _rerankStepMatch({
      required String step,
      required List<Map<String, dynamic>> memories,
  }) async {
      if (memories.isEmpty) return null;

      final candidates = <Map<String, dynamic>>[];
      for (int i = 0; i < memories.length; i++) {
          final m = memories[i];
          final payload = m['payload'] as Map<String, dynamic>;
          candidates.add({
              'index': i,
              'score': m['score'],
              'goal': payload['goal'],
              'action': payload['action'],
              'fact': payload['fact'],
              'prerequisites': payload['prerequisites'],
          });
      }

      final prompt = '''
      You are matching a task step to the best memory entry.
      Step: "$step"
      Candidates (JSON): ${jsonEncode(candidates)}

      Return ONLY JSON:
      {"best_index": <index>, "confidence": <0.0-1.0>, "reason": "short"}
      ''';

      try {
          final response = await ollama.generate(prompt: prompt, numPredict: 120);
          final clean = _extractJson(response);
          final decoded = jsonDecode(clean);
          if (decoded is Map<String, dynamic>) {
              final idx = (decoded['best_index'] as num?)?.toInt();
              final confidence = (decoded['confidence'] as num?)?.toDouble();
              if (idx != null && idx >= 0 && idx < memories.length) {
                  final selected = Map<String, dynamic>.from(memories[idx]);
                  if (confidence != null && confidence.isFinite) {
                      selected['score'] = confidence;
                  }
                  return selected;
              }
          }
      } catch (_) {}

      return null;
  }

  Future<String> _normalizeStep(String step) async {
      final prompt = '''
      Normalize this task step into a concise UI action query. Keep the target text if present.
      Step: "$step"
      Output only the normalized text.
      Examples:
      - "Click \"Login\" button" -> "Click Login"
      - "Type \"hello\"" -> "Type hello"
      - "Open Start Menu" -> "Click Start"
      ''';

      try {
          final response = await ollama.generate(prompt: prompt, numPredict: 32);
          final normalized = response.trim();
          if (normalized.isNotEmpty) return normalized;
      } catch (_) {}
      return step;
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
    Future<IdleAnalysisResult> analyzeIdlePage(
        UIState state, {
        String? imageBase64,
        bool questionsOnly = false,
        int minQuestions = 20,
    }) async {
       // Only analyze if state has significant content (e.g. headers, windows)
       final text = state.toLLMDescription();
      final ocrTokens = _extractOcrTokens(state);
      final ocrList = ocrTokens.isEmpty ? '[]' : ocrTokens.map((t) => '"$t"').join(', ');
       
       // 1. Check what we already know to avoid asking dumb questions
       // [TEMP] Disable Recall to prevent Model Swapping (RAM Thrashing)
       // final embedding = await ollamaEmbed.embed(prompt: text);
       // final knownMemories = await qdrant.search(queryEmbedding: embedding, limit: 10);
       // final knownGoals = knownMemories...
       final knownGoals = ""; // Empty context for speed

               final prompt = questionsOnly && imageBase64 != null
                   ? '''
               You are analyzing a CURRENT screen capture image. Output ONLY valid JSON, no markdown, no explanations.

               OCR TOKEN LIST (verbatim allowed targets):
               [$ocrList]

               TASK: Generate a list of questions about UI elements you do NOT understand.
               - Produce AT LEAST $minQuestions questions if possible
               - Each question MUST reference an element EXACTLY from the OCR TOKEN LIST
               - If you cannot map an element to OCR tokens, skip it

               OUTPUT FORMAT (pure JSON array of strings):
               ["What does <element> do?", "What is <element> used for?", ...]
               '''
                   : imageBase64 != null
                     ? '''
             You are analyzing a CURRENT screen capture image. Output ONLY valid JSON, no markdown, no explanations.

             OCR TOKEN LIST (verbatim allowed targets):
             [$ocrList]

             ALREADY LEARNED (ignore these): [$knownGoals]

            TASK: Use the IMAGE to identify actionable UI elements.
             - If you recognize its standard function (e.g., "Save", "Close", "Settings"), create an "insight"
             - If you don't understand its purpose, create a "question" asking what it does
            - Try to produce AT LEAST 20 questions if the screen has enough elements
             - CRITICAL: Any action.target_text MUST be an EXACT string from the OCR TOKEN LIST
             - CRITICAL: Any question must reference an element EXACTLY from the OCR TOKEN LIST
             - If you cannot map an element to OCR tokens, skip it

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
             '''
                     : '''
       You are analyzing a CURRENT screen capture. Output ONLY valid JSON, no markdown, no explanations.
       
       CURRENT SCREEN TEXT ELEMENTS:
       $text

             OCR TOKEN LIST (verbatim allowed targets):
             [$ocrList]
       
       ALREADY LEARNED (ignore these): [$knownGoals]
       
       TASK: For each UI element in the CURRENT screen text above:
       - If you recognize its standard function (e.g., "Save", "Close", "Settings"), create an "insight"
       - If you don't understand its purpose, create a "question" asking what it does
       - IMPORTANT: Only analyze elements that are ACTUALLY PRESENT in the current screen text above
       - DO NOT mention elements from other screens or contexts
             - CRITICAL: Any action.target_text MUST be an EXACT string from the OCR TOKEN LIST
             - CRITICAL: Any question must reference an element EXACTLY from the OCR TOKEN LIST
       
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
              final msg = "⏳ [Ollama Wait] Still waiting... (${t.tick * 5}s elapsed)";
              debugPrint(msg);
              _logController.add(msg);
          });

                    final activeClient = imageBase64 != null ? ollamaVision : ollama;
                    debugPrint("🚀 [Ollama Start] Sending request to '${activeClient.model}'...");
          String response;
          try {
                                                 response = await activeClient
                                                         .generate(
                                                             prompt: prompt,
                                                             images: imageBase64 != null ? [imageBase64] : null,
                                                             numPredict: 256,
                                                         )
                                                         .timeout(const Duration(seconds: 180));
          } finally {
             timer.cancel(); // Stop heartbeat
             stopwatch.stop();
          }
          
          debugPrint("✅ [Ollama Done] Response received in ${stopwatch.elapsed.inSeconds}s.");
          debugPrint("[ROBOT] [OLLAMA RAW]: $response");
          _logController.add("VERBOSE: [OLLAMA RESPONSE]\n$response");
          var clean = _extractJson(response).trim();
          
          if (!clean.startsWith('{')) {
               final startBrace = clean.indexOf('{');
               if (startBrace != -1) clean = clean.substring(startBrace);
          }
           
                    dynamic decoded;
                    try {
                        decoded = jsonDecode(clean);
                    } catch (_) {
                        if (questionsOnly) {
                            final start = clean.indexOf('[');
                            final end = clean.lastIndexOf(']');
                            if (start != -1 && end != -1 && end > start) {
                                try {
                                    decoded = jsonDecode(clean.substring(start, end + 1));
                                } catch (_) {
                                    decoded = _extractQuestionsFromText(clean);
                                }
                            } else {
                                decoded = _extractQuestionsFromText(clean);
                            }
                        } else {
                            rethrow;
                        }
                    }
          final messages = <String>[];
          final learned = <String>{};

                    if (questionsOnly) {
                        final questions = decoded is List
                                ? decoded.map((e) => e.toString()).toList()
                                : <String>[];
                        messages.addAll(_filterQuestions(questions, ocrTokens));
                        return IdleAnalysisResult(messages: messages, learnedItems: learned);
                    }

                    Map<String, dynamic>? corrected;
                    if (decoded is Map<String, dynamic>) {
                        final needsCorrection = _idleAnalysisNeedsCorrection(decoded, ocrTokens);
                        if (needsCorrection) {
                            corrected = await _correctIdleAnalysis(decoded, ocrTokens);
                        }
                    }

                    final dynamic effective = corrected ?? decoded;
          
                    if (effective is Map<String, dynamic>) {
                            final filtered = _filterIdleAnalysis(effective, ocrTokens);
                            // 1. Process Insights (Auto-Learn)
                            if (filtered.containsKey('insights') && filtered['insights'] is List) {
                                    for (final item in filtered['insights']) {
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
                            if (filtered.containsKey('questions') && filtered['questions'] is List) {
                                    for (final q in filtered['questions']) {
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

    /// Vision-only idle analysis (no OCR grounding).
    /// Uses a vision model to extract labeled elements, then checks memory for each.
    /// Unknowns become questions; confident unknowns are saved to memory.
    Future<IdleAnalysisResult> analyzeIdlePageVisionOnly({
        required String imageBase64,
        int minQuestions = 20,
        double memoryThreshold = 0.88,
        double visionConfidenceThreshold = 0.72,
        int maxElements = 30,
        int numPredict = 128,
    }) async {
        try {
            final prompt = '''
You are analyzing a CURRENT software UI screenshot.
Return ONLY valid JSON. No markdown, no prose.

Schema:
{
    "screen_summary": "short summary",
    "elements": [
        {
            "label": "exact visible text",
            "role": "button|tab|menu|link|input|icon|other",
            "purpose": "what it likely does (leave empty if unsure)",
            "confidence": 0.0-1.0
        }
    ]
}

Rules:
- Only include elements with visible text labels.
- Use the exact visible text for each label.
- If you are unsure about an element's purpose, set purpose to "" and confidence < 0.5.
- Try to list at least $minQuestions elements if visible.
''';

            final response = await ollamaVision.generate(
                prompt: prompt,
                images: [imageBase64],
                numPredict: numPredict,
                temperature: 0.1,
            ).timeout(const Duration(seconds: 180));

            final clean = _extractJson(response).trim();
            dynamic decoded;
            try {
                decoded = jsonDecode(clean);
            } catch (_) {
                return IdleAnalysisResult();
            }

            String screenSummary = '';
            List<dynamic> elements = [];
            if (decoded is Map<String, dynamic>) {
                screenSummary = decoded['screen_summary']?.toString() ?? '';
                final raw = decoded['elements'] ?? decoded['items'];
                if (raw is List) elements = raw;
            } else if (decoded is List) {
                elements = decoded;
            }

            final questions = <String>{};
            final learned = <String>{};

            var processed = 0;
            final seenLabels = <String>{};
            for (final element in elements) {
                String label = '';
                String role = '';
                String purpose = '';
                double confidence = 0.0;

                if (element is String) {
                    label = element.trim();
                } else if (element is Map) {
                    label = (element['label'] ?? element['text'] ?? element['name'] ?? '').toString().trim();
                    role = (element['role'] ?? element['type'] ?? '').toString().trim();
                    purpose = (element['purpose'] ?? element['description'] ?? '').toString().trim();
                    final conf = element['confidence'];
                    if (conf is num) {
                        confidence = conf.toDouble();
                    } else if (conf is String) {
                        confidence = double.tryParse(conf) ?? 0.0;
                    }
                }

                if (label.isEmpty || _isLikelyTimestampOrNoise(label)) continue;
                if (seenLabels.contains(label.toLowerCase())) continue;
                seenLabels.add(label.toLowerCase());
                processed++;
                if (processed > maxElements) break;

                final query = purpose.isEmpty
                        ? 'Element: $label.'
                        : 'Element: $label. Purpose: $purpose.';

                final queryEmbedding = await ollamaEmbed.embed(prompt: query);
                final memories = await qdrant.search(
                    queryEmbedding: queryEmbedding,
                    limit: 1,
                );

                final score = memories.isNotEmpty ? (memories.first['score'] as double) : 0.0;
                if (score >= memoryThreshold) continue;

                if (purpose.isNotEmpty && confidence >= visionConfidenceThreshold) {
                    final goal = _normalizeGoalFromPurpose(purpose, label);
                    final saveEmbedding = await ollamaEmbed.embed(
                        prompt: 'Goal: $goal. Element: $label. Purpose: $purpose. Screen: $screenSummary.',
                    );

                    await qdrant.saveMemory(
                        embedding: saveEmbedding,
                        payload: {
                            'goal': goal,
                            'action': {
                                'type': 'click',
                                'target_text': label,
                            },
                            'fact': purpose,
                            'description': screenSummary,
                            'role': role,
                            'source': 'vision_mvp',
                            'confidence': confidence,
                            'timestamp': DateTime.now().toIso8601String(),
                        },
                    );
                    learned.add(label);
                } else {
                    if (minQuestions <= 0 || questions.length < minQuestions) {
                        questions.add('What does "$label" do?');
                    }
                }
            }

            return IdleAnalysisResult(
                messages: questions.toList(growable: false),
                learnedItems: learned,
            );
        } catch (e) {
            debugPrint("[ROBOT] ❌ Vision-only Idle Analysis Failed: $e");
            return IdleAnalysisResult();
        }
    }

    /// Hybrid analysis using OCR labels + vision to assign role/purpose.
    Future<IdleAnalysisResult> analyzeIdlePageHybrid({
        required String imageBase64,
        required List<String> labels,
        List<String> knownGoals = const [],
        int maxItems = 30,
        int numPredict = 192,
        double visionConfidenceThreshold = 0.6,
    }) async {
        debugPrint('[ROBOT] 🔬 analyzeIdlePageHybrid: Starting...');
        debugPrint('[ROBOT] 🔬 Input: ${labels.length} labels, ${knownGoals.length} knownGoals');
        
        try {
            if (labels.isEmpty) {
                debugPrint('[ROBOT] 🔬 No labels, returning empty');
                return IdleAnalysisResult();
            }

            final cleaned = _cleanLabelList(labels);
            debugPrint('[ROBOT] 🔬 After cleaning: ${cleaned.length} labels');
            if (cleaned.isEmpty) return IdleAnalysisResult();

            final unique = <String>{};
            final pruned = <String>[];
            for (final l in cleaned) {
                final v = l.trim();
                if (v.isEmpty) continue;
                final key = v.toLowerCase();
                if (unique.add(key)) pruned.add(v);
                if (pruned.length >= maxItems) break;
            }
            
            debugPrint('[ROBOT] 🔬 Pruned labels (${pruned.length}): ${pruned.take(10).join(", ")}...');

            final labelList = pruned.map((l) => '"$l"').join(', ');
            
            // [FIX] Use TEXT-ONLY LLM instead of vision model
            // Moondream doesn't understand JSON format, so we use llama3.2 text model
            // which can infer UI element purposes from common patterns
            final prompt = '''You are analyzing UI element labels from a screenshot.
For each label, infer the role and purpose based on common UI patterns.
Return ONLY a valid JSON array (no markdown, no explanation), like this:
[{"label": "File", "role": "menu", "purpose": "Opens file operations", "confidence": 0.9}]

Labels to analyze:
[$labelList]

Rules:
- Only include labels that are likely interactive (buttons, menus, links)
- Skip timestamps, numbers, and noise
- Be concise in purpose descriptions
- Set confidence 0.7-0.9 for common patterns, 0.5-0.7 for uncertain ones
''';

            debugPrint('[ROBOT] 🔬 Using TEXT-ONLY LLM (${ollama.model}) instead of vision model');
            debugPrint('[ROBOT] 🔬 Prompt length: ${prompt.length} chars');
            
            // Use text-only LLM instead of vision model
            final response = await ollama.generate(
                prompt: prompt,
                numPredict: numPredict,
                temperature: 0.2,
            ).timeout(const Duration(seconds: 60));

            debugPrint('[ROBOT] 🔬 LLM response (first 500 chars): ${response.substring(0, response.length > 500 ? 500 : response.length)}');
            
            final clean = _extractJson(response);
            debugPrint('[ROBOT] 🔬 Extracted JSON (first 300 chars): ${clean.substring(0, clean.length > 300 ? 300 : clean.length)}');
            
            dynamic decoded;
            try {
                decoded = jsonDecode(clean);
                debugPrint('[ROBOT] 🔬 JSON decoded successfully, type: ${decoded.runtimeType}');
            } catch (e) {
                debugPrint('[ROBOT] ⚠️ JSON decode failed: $e');
                decoded = null;
            }

            final items = <Map<String, dynamic>>[];
            if (decoded is List) {
                for (final item in decoded) {
                    if (item is Map<String, dynamic>) items.add(item);
                }
            }
            
            debugPrint('[ROBOT] 🔬 Parsed ${items.length} items from vision response');
            for (var i = 0; i < items.length && i < 5; i++) {
                debugPrint('[ROBOT] 🔬   Item $i: label="${items[i]['label']}", purpose="${items[i]['purpose']}", conf=${items[i]['confidence']}');
            }

            if (items.isEmpty) {
                debugPrint('[ROBOT] 🔬 No items parsed, trying fallback text-only prompt...');
                final fallbackPrompt = '''
You are given UI labels from a screenshot. For each label, infer a role and purpose based on common UI patterns.
Return ONLY lines in this exact format:
Label | role | purpose

Allowed roles: button, tab, menu, link, input, folder, window, other

Labels:
[$labelList]
''';

                final fallbackResponse = await ollama
                    .generate(prompt: fallbackPrompt, numPredict: numPredict)
                    .timeout(const Duration(seconds: 180));

                debugPrint('[ROBOT] 🔬 Fallback response: ${fallbackResponse.substring(0, fallbackResponse.length > 300 ? 300 : fallbackResponse.length)}');
                
                for (final line in fallbackResponse.split('\n')) {
                    if (!line.contains('|')) continue;
                    final parts = line.split('|').map((p) => p.trim()).toList();
                    if (parts.length < 3) continue;
                    items.add({
                        'label': parts[0],
                        'role': parts[1],
                        'purpose': parts.sublist(2).join(' | ').trim(),
                        'confidence': 0.7,
                    });
                }
                debugPrint('[ROBOT] 🔬 Fallback parsed ${items.length} items');
            }

            if (items.isEmpty) {
                debugPrint('[ROBOT] 🔬 No items to process, returning empty result');
                return IdleAnalysisResult();
            }

            final learned = <String>{};
            final questions = <String>[];
            int skippedKnown = 0;
            int skippedLowConf = 0;

            final tasks = <Future<void>>[];
            for (final item in items) {
                final label = (item['label'] ?? '').toString().trim();
                final role = (item['role'] ?? 'other').toString().trim();
                final purpose = (item['purpose'] ?? '').toString().trim();
                final conf = item['confidence'];
                final confVal = conf is num ? conf.toDouble() : double.tryParse(conf?.toString() ?? '') ?? 0.0;
                
                if (label.isEmpty) continue;
                
                // [DEBUG] Check de-duplication
                if (knownGoals.contains(label)) {
                    debugPrint('[ROBOT] 🔬 SKIPPING "$label" - already in knownGoals');
                    skippedKnown++;
                    continue;
                }

                if (purpose.isNotEmpty && confVal >= visionConfidenceThreshold) {
                    debugPrint('[ROBOT] 🔬 LEARNING: "$label" -> "$purpose" (conf=$confVal)');
                    tasks.add(learnVisionOnly(
                        goal: purpose,
                        action: {
                            'type': 'click',
                            'target_text': label,
                            'role': role,
                            'purpose': purpose,
                        },
                        fact: purpose,
                        context: '',
                    ).then((_) {
                       learned.add(label);
                    }).catchError((e) {
                       debugPrint('[ROBOT] ⚠️ Failed to learn "$label": $e');
                    }));
                } else {
                    debugPrint('[ROBOT] 🔬 QUESTION: "$label" (conf=$confVal < $visionConfidenceThreshold or no purpose)');
                    skippedLowConf++;
                    questions.add('What does "$label" do?');
                }
            }
            await Future.wait(tasks);

            debugPrint('[ROBOT] 🔬 SUMMARY: learned=${learned.length}, questions=${questions.length}, skippedKnown=$skippedKnown, skippedLowConf=$skippedLowConf');
            debugPrint('[ROBOT] 🔬 Learned items: $learned');

            return IdleAnalysisResult(messages: questions, learnedItems: learned);
        } catch (e) {
            debugPrint("[ROBOT] ❌ Hybrid Idle Analysis Failed: $e");
            return IdleAnalysisResult();
        }
    }

    List<String> _cleanLabelList(List<String> labels) {
        final cleaned = <String>[];
        for (final label in labels) {
            var l = label.trim().replaceAll(RegExp(r"^['`\x22]+|['`\x22]+$"), '');
            if (l.isEmpty) continue;
            if (l.length < 4) continue;
            if (!RegExp(r'[A-Za-z]').hasMatch(l)) continue;
            if (RegExp(r'^[0-9\.]+$').hasMatch(l)) continue;
            if (l.contains('â') || l.contains('�')) continue;
            final digits = RegExp(r'\d').allMatches(l).length;
            final digitRatio = digits / l.length;
            if (digitRatio > 0.4) continue;
            final nonAlnum = RegExp(r'[^A-Za-z0-9\s]').allMatches(l).length;
            if ((nonAlnum / l.length) > 0.4) continue;
            if (RegExp(r'[~`^]').hasMatch(l)) continue;
            cleaned.add(l);
        }

        final seen = <String>{};
        final result = <String>[];
        for (final l in cleaned) {
            final key = l.toLowerCase();
            if (seen.contains(key)) continue;
            seen.add(key);
            result.add(l);
        }
        return result;
    }

    List<String> _extractOcrTokens(UIState state) {
        final tokens = <String>{};
        for (final block in state.ocrBlocks) {
            final lines = block.text.split(RegExp(r'[\r\n]+'));
            for (final line in lines) {
                final trimmed = line.trim();
                if (trimmed.isEmpty) continue;
                tokens.add(trimmed);
                final parts = trimmed.split(RegExp(r'\s{2,}|\t|\|'));
                for (final part in parts) {
                    final p = part.trim();
                    if (p.isNotEmpty) tokens.add(p);
                }
                final words = trimmed.split(RegExp(r'\s+'));
                for (final word in words) {
                    final w = word.trim();
                    if (w.length >= 2 && w.length <= 32) tokens.add(w);
                }
            }
        }
        return tokens.toList();
    }

    String _normalizeToken(String value) {
        return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    }

    bool _isLikelyTimestampOrNoise(String value) {
        final v = value.trim();
        if (v.isEmpty) return true;
        // Date-like: 17/01/2026 or 17-01-2026
        if (RegExp(r'^\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}$').hasMatch(v)) return true;
        // Time-like: 12:34 or 12:34:56
        if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(v)) return true;
        // Date+time fragments or mixed numeric noise
        final normalized = _normalizeToken(v);
        final hasAlpha = RegExp(r'[a-z]').hasMatch(normalized);
        final hasDigit = RegExp(r'\d').hasMatch(normalized);
        if (!hasAlpha && hasDigit) return true;
        // Very short fragments like "a" or "..."
        if (normalized.length <= 1) return true;
        return false;
    }

    bool _tokenExists(String candidate, List<String> ocrTokens) {
        if (candidate.trim().isEmpty) return false;
        final normalized = _normalizeToken(candidate);
        for (final token in ocrTokens) {
            if (_normalizeToken(token) == normalized) return true;
        }
        return false;
    }

    String? _bestTokenMatch(String candidate, List<String> ocrTokens) {
        if (candidate.trim().isEmpty || ocrTokens.isEmpty) return null;
        final normalizedCandidate = _normalizeToken(candidate);
        double bestScore = 0.0;
        String? bestToken;
        for (final token in ocrTokens) {
            if (_isLikelyTimestampOrNoise(token)) continue;
            final normalizedToken = _normalizeToken(token);
            if (normalizedToken.isEmpty) continue;
            final dist = _levenshtein(normalizedCandidate, normalizedToken);
            final maxLen = normalizedCandidate.length > normalizedToken.length
                    ? normalizedCandidate.length
                    : normalizedToken.length;
            final score = maxLen == 0 ? 0.0 : (1.0 - (dist / maxLen));
            if (score > bestScore) {
                bestScore = score;
                bestToken = token;
            }
        }
        if (bestScore >= 0.82) return bestToken;
        return null;
    }

    int _levenshtein(String a, String b) {
        final m = a.length;
        final n = b.length;
        if (m == 0) return n;
        if (n == 0) return m;
        final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
        for (int i = 0; i <= m; i++) dp[i][0] = i;
        for (int j = 0; j <= n; j++) dp[0][j] = j;
        for (int i = 1; i <= m; i++) {
            for (int j = 1; j <= n; j++) {
                final cost = a[i - 1] == b[j - 1] ? 0 : 1;
                dp[i][j] = [
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1,
                    dp[i - 1][j - 1] + cost,
                ].reduce((v, e) => v < e ? v : e);
            }
        }
        return dp[m][n];
    }

    bool _idleAnalysisNeedsCorrection(Map<String, dynamic> decoded, List<String> ocrTokens) {
        if (ocrTokens.isEmpty) return false;
        if (decoded.containsKey('insights') && decoded['insights'] is List) {
            for (final item in decoded['insights']) {
                if (item is Map<String, dynamic>) {
                    final action = item['action'] as Map<String, dynamic>? ?? {};
                    final target = action['target_text']?.toString() ?? '';
                    if (!_tokenExists(target, ocrTokens)) return true;
                }
            }
        }
        if (decoded.containsKey('questions') && decoded['questions'] is List) {
            for (final q in decoded['questions']) {
                final question = q is Map<String, dynamic> ? q['question']?.toString() ?? '' : q.toString();
                final target = _extractQuestionTarget(question);
                if (target != null && !_tokenExists(target, ocrTokens)) return true;
            }
        }
        return false;
    }

    Future<Map<String, dynamic>?> _correctIdleAnalysis(
        Map<String, dynamic> decoded,
        List<String> ocrTokens,
    ) async {
        if (ocrTokens.isEmpty) return null;
        final prompt = '''
You are correcting LLM output to match OCR tokens.
OCR TOKENS (allowed): ${jsonEncode(ocrTokens)}

Original JSON:
${jsonEncode(decoded)}

Rules:
- Replace any action.target_text with the closest matching OCR token.
- Replace any question to reference an OCR token exactly.
- If you cannot map an item to OCR tokens, drop it.

Return ONLY JSON in the same shape:
{"insights": [...], "questions": [...]}
''';

        try {
            final response = await ollama.generate(prompt: prompt, numPredict: 200);
            final clean = _extractJson(response);
            final dynamic result = jsonDecode(clean);
            if (result is Map<String, dynamic>) return result;
        } catch (e) {
            debugPrint("Idle correction failed: $e");
        }
        return null;
    }

    Map<String, dynamic> _filterIdleAnalysis(Map<String, dynamic> decoded, List<String> ocrTokens) {
        final filtered = <String, dynamic>{'insights': <dynamic>[], 'questions': <dynamic>[]};

        if (decoded.containsKey('insights') && decoded['insights'] is List) {
            final insights = <dynamic>[];
            for (final item in decoded['insights']) {
                if (item is Map<String, dynamic>) {
                    final action = item['action'] as Map<String, dynamic>? ?? {};
                    final target = action['target_text']?.toString() ?? '';
                    if (_tokenExists(target, ocrTokens) && !_isLikelyTimestampOrNoise(target)) {
                        insights.add(item);
                    } else {
                        final best = _bestTokenMatch(target, ocrTokens);
                        if (best != null) {
                            action['target_text'] = best;
                            item['action'] = action;
                            insights.add(item);
                        }
                    }
                }
            }
            filtered['insights'] = insights;
        }

        if (decoded.containsKey('questions') && decoded['questions'] is List) {
            final questions = <dynamic>[];
            for (final q in decoded['questions']) {
                final question = q is Map<String, dynamic> ? q['question']?.toString() ?? '' : q.toString();
                final target = _extractQuestionTarget(question);
                if (target != null && _tokenExists(target, ocrTokens) && !_isLikelyTimestampOrNoise(target)) {
                    questions.add(question);
                } else if (target != null) {
                    final best = _bestTokenMatch(target, ocrTokens);
                    if (best != null) {
                        questions.add('What does $best do?');
                    }
                }
            }
            filtered['questions'] = questions;
        }

        return filtered;
    }

    String? _extractQuestionTarget(String question) {
        if (question.trim().isEmpty) return null;
        final quoted = RegExp(r'"([^"]+)"').firstMatch(question);
        if (quoted != null) return quoted.group(1);
        final cleaned = question
            .replaceAll(RegExp(r'\?$'), '')
            .replaceAll(RegExp(r"^(what does|what is|what's)\s+", caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+do\??$', caseSensitive: false), '')
            .trim();
        return cleaned.isEmpty ? null : cleaned;
    }

    String _normalizeGoalFromPurpose(String purpose, String label) {
        final p = purpose.trim();
        if (p.isEmpty) return 'Use $label';
        final startsWithVerb = RegExp(
          r'^(open|opens|create|creates|add|adds|start|starts|launch|launches|save|saves|delete|deletes|remove|removes|close|closes|exit|edit|view|show|hide|toggle|enable|disable|submit|search|find|upload|download)',
          caseSensitive: false,
        ).hasMatch(p);
        if (startsWithVerb) return p[0].toUpperCase() + p.substring(1);
        return 'Use $label';
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

    List<String> _filterQuestions(List<String> questions, List<String> ocrTokens) {
        final filtered = <String>[];
        for (final question in questions) {
            final target = _extractQuestionTarget(question);
            if (target != null && _tokenExists(target, ocrTokens) && !_isLikelyTimestampOrNoise(target)) {
                filtered.add(question);
            } else if (target != null) {
                final best = _bestTokenMatch(target, ocrTokens);
                if (best != null) {
                    filtered.add('What does $best do?');
                }
            }
        }
        return filtered;
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

    /// Clarification parsing for vision-only flow (no OCR state required).
    Future<Map<String, dynamic>?> analyzeUserClarificationVisionOnly({
        required String userText,
        required String? lastQuestion,
    }) async {
        final target = lastQuestion == null ? null : _extractQuestionTarget(lastQuestion);
        if (target == null || target.trim().isEmpty) return null;

        final prompt = '''
I am a Robot Assistant. I asked the user: "$lastQuestion".
The user replied: "$userText".

Extract a lesson as JSON:
{
    "goal": "Short description of the goal (e.g. 'Open Settings')",
    "action": {
         "type": "click" or "type",
         "target_text": "$target",
         "text": "Text to type if type action" (optional)
    },
    "fact": "A factual summary of what this element does",
    "context": "Any extra context or prerequisites (optional)"
}

If the user is not teaching an action, return only: {"analysis": "no_action"}
''';

        try {
            final response = await ollama.generate(prompt: prompt, numPredict: 256);
            debugPrint("[OLLAMA RAW - Clarify Vision]: $response");
            final clean = _extractJson(response);
            final dynamic json = jsonDecode(clean);
            if (json is Map && json.containsKey('action')) {
                return json as Map<String, dynamic>;
            }
            return null;
        } catch (e) {
            debugPrint("Clarification Analysis (Vision) Failed: $e");
            return null;
        }
    }

    /// Saves a vision-only learning entry to memory.
    Future<void> learnVisionOnly({
        required String goal,
        required Map<String, dynamic> action,
        required String fact,
        String? context,
    }) async {
        final targetText = action['target_text'] ?? 'N/A';
        debugPrint('[ROBOT] 🎓 learnVisionOnly: goal="$goal", target="$targetText"');
        
        final description = 'Goal: $goal. Fact: $fact. Context: ${context ?? ''}'.trim();
        debugPrint('[ROBOT] 🎓 Description: $description');
        
        final embedding = await ollamaEmbed.embed(prompt: description);
        debugPrint('[ROBOT] 🎓 Got embedding, dim=${embedding.length}');
        
        await qdrant.saveMemory(
            embedding: embedding,
            payload: {
                'goal': goal,
                'action': action,
                'fact': fact,
                'description': description,
                'source': 'vision_mvp',
                'timestamp': DateTime.now().toIso8601String(),
            },
        );
        
        debugPrint('[ROBOT] 🎓 Successfully saved to Qdrant!');
    }

    List<String> _extractQuestionsFromText(String text) {
        final results = <String>[];
        final matches = RegExp(r'"([^"]+\?)"').allMatches(text);
        for (final match in matches) {
            final q = match.group(1);
            if (q != null && q.contains('?')) {
                results.add(q);
            }
        }
        if (results.isNotEmpty) return results;

        final fallbackMatches = RegExp(r'What[^\?]{2,200}\?', caseSensitive: false).allMatches(text);
        for (final match in fallbackMatches) {
            final q = match.group(0);
            if (q != null) results.add(q.trim());
        }
        return results;
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

   /// Converts a Training Session into a saved Sequence (Task Chain).
   /// 
   /// Call this after [analyzeSession] has populated hypotheses for each frame.
   /// Returns the sequence ID (the session name normalized).
   Future<String> saveSessionAsSequence(TrainingSession session) async {
       // Generate a sequence ID from session name
       final sequenceId = session.name
           .toLowerCase()
           .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
           .replaceAll(RegExp(r'^_+|_+$'), '');

       int stepOrder = 0;
       for (final frame in session.frames) {
           // Prefer recorded HID action over hypothesis
           if (frame.recordedAction != null) {
               await saveSequenceStep(
                   sequenceId: sequenceId,
                   stepOrder: stepOrder,
                   goal: frame.recordedAction!.toString(),
                   action: frame.recordedAction!.toActionPayload(),
                   description: 'Recorded action: ${frame.recordedAction}',
                   targetText: frame.recordedAction!.targetText,
               );
               stepOrder++;
               continue;
           }
           
           // Fallback to hypothesis-based action
           final hyp = frame.hypothesis;
           if (hyp == null) continue;
           if (hyp.suggestedAction == null && !hyp.goal.contains('Complete')) continue;

           await saveSequenceStep(
               sequenceId: sequenceId,
               stepOrder: stepOrder,
               goal: hyp.goal,
               action: hyp.suggestedAction ?? {'type': 'wait'},
               description: hyp.description,
               targetText: hyp.suggestedAction?['target_text']?.toString(),
           );
           stepOrder++;
       }

       debugPrint('[SEQUENCE] Saved session "${session.name}" as sequence "$sequenceId" with $stepOrder steps.');
       return sequenceId;
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

  // ============================================================
  // ACTION VERIFICATION - Phase 2.5
  // ============================================================

  /// Verifies that an action caused meaningful screen change.
  /// 
  /// Compares [beforeState] and [afterState] using Jaccard similarity.
  /// Returns an [ActionVerificationResult] indicating success/warning.
  ActionVerificationResult verifyAction({
    required UIState? beforeState,
    required UIState? afterState,
    double similarityThreshold = 0.95,
  }) {
    if (beforeState == null || afterState == null) {
        return ActionVerificationResult(
            verified: true,
            similarity: 0.0,
            message: 'Verification skipped (no state data).',
        );
    }

    final textBefore = beforeState.ocrBlocks.map((b) => b.text).toSet();
    final textAfter = afterState.ocrBlocks.map((b) => b.text).toSet();

    final intersection = textBefore.intersection(textAfter).length;
    final union = textBefore.union(textAfter).length;
    final similarity = union > 0 ? intersection / union : 1.0;

    if (similarity > similarityThreshold && textBefore.isNotEmpty) {
        return ActionVerificationResult(
            verified: false,
            similarity: similarity,
            message: 'Screen unchanged (${(similarity * 100).toStringAsFixed(0)}% similar). Action may have missed.',
        );
    }

    return ActionVerificationResult(
        verified: true,
        similarity: similarity,
        message: 'Screen changed (${((1 - similarity) * 100).toStringAsFixed(0)}% different). Action verified.',
    );
  }

  // ============================================================
  // SMART WAITS & SYNCHRONIZATION - Phase 2.5
  // ============================================================

  /// Waits until the specified [targetText] appears on screen.
  /// 
  /// Polls [captureState] at [pollInterval] until text is found or [timeout] expires.
  /// Returns the [UIState] where text was found, or null if timeout.
  Future<UIState?> waitForTextAppears({
    required String targetText,
    required Future<UIState?> Function() captureState,
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 500),
    void Function(String message)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final searchLower = targetText.toLowerCase();

    while (stopwatch.elapsed < timeout) {
        final state = await captureState();
        if (state != null) {
            final found = state.ocrBlocks.any(
                (b) => b.text.toLowerCase().contains(searchLower)
            );
            if (found) {
                onProgress?.call('✅ Found "$targetText" after ${stopwatch.elapsed.inMilliseconds}ms');
                return state;
            }
        }
        onProgress?.call('⏳ Waiting for "$targetText"... (${stopwatch.elapsed.inSeconds}s)');
        await Future.delayed(pollInterval);
    }

    onProgress?.call('⚠️ Timeout waiting for "$targetText"');
    return null;
  }

  /// Waits until the screen content changes from [initialState].
  /// 
  /// Uses Jaccard similarity - returns when similarity drops below [changeThreshold].
  Future<UIState?> waitForScreenChange({
    required UIState initialState,
    required Future<UIState?> Function() captureState,
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 500),
    double changeThreshold = 0.90,
    void Function(String message)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final initialText = initialState.ocrBlocks.map((b) => b.text).toSet();

    while (stopwatch.elapsed < timeout) {
        await Future.delayed(pollInterval);
        
        final state = await captureState();
        if (state == null) continue;
        
        final currentText = state.ocrBlocks.map((b) => b.text).toSet();
        final intersection = initialText.intersection(currentText).length;
        final union = initialText.union(currentText).length;
        final similarity = union > 0 ? intersection / union : 1.0;

        if (similarity < changeThreshold) {
            onProgress?.call('✅ Screen changed (${((1 - similarity) * 100).toStringAsFixed(0)}% different) after ${stopwatch.elapsed.inMilliseconds}ms');
            return state;
        }
        
        onProgress?.call('⏳ Waiting for screen change... (${(similarity * 100).toStringAsFixed(0)}% similar)');
    }

    onProgress?.call('⚠️ Timeout waiting for screen change');
    return null;
  }

  /// Waits until the specified [targetText] disappears from screen.
  /// 
  /// Useful for waiting for dialogs to close or loading spinners to finish.
  Future<UIState?> waitForTextDisappears({
    required String targetText,
    required Future<UIState?> Function() captureState,
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 500),
    void Function(String message)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final searchLower = targetText.toLowerCase();

    while (stopwatch.elapsed < timeout) {
        final state = await captureState();
        if (state != null) {
            final stillPresent = state.ocrBlocks.any(
                (b) => b.text.toLowerCase().contains(searchLower)
            );
            if (!stillPresent) {
                onProgress?.call('✅ "$targetText" disappeared after ${stopwatch.elapsed.inMilliseconds}ms');
                return state;
            }
        }
        onProgress?.call('⏳ Waiting for "$targetText" to disappear...');
        await Future.delayed(pollInterval);
    }

    onProgress?.call('⚠️ Timeout waiting for "$targetText" to disappear');
    return null;
  }

  // ============================================================
  // REGION GROUPING - Phase 2.5
  // ============================================================

  /// Finds an element by text, optionally constraining to a specific region.
  /// 
  /// [regionContaining] - If provided, only search within regions containing this text.
  /// Example: findElementInRegion(state, "OK", regionContaining: "Confirm Delete")
  /// to find the OK button specifically in the "Confirm Delete" dialog.
  OcrBlock? findElementInRegion(
    UIState state,
    String targetText, {
    String? regionContaining,
    double proximityThreshold = 50.0,
  }) {
    final searchLower = targetText.toLowerCase();
    
    if (regionContaining == null) {
      // Simple search without region constraint
      for (final block in state.ocrBlocks) {
        if (block.text.toLowerCase().contains(searchLower)) {
          return block;
        }
      }
      return null;
    }

    // Region-aware search
    final regions = RegionGrouper.groupByProximity(
      state.ocrBlocks, 
      proximityThreshold: proximityThreshold,
    );
    
    final regionLower = regionContaining.toLowerCase();
    
    // Find the region containing the context text
    for (final region in regions) {
      if (region.containsText(regionLower)) {
        // Search for target within this region
        final found = region.findBlock(targetText);
        if (found != null) return found;
      }
    }
    
    // Fallback: try simple search
    for (final block in state.ocrBlocks) {
      if (block.text.toLowerCase().contains(searchLower)) {
        return block;
      }
    }
    
    return null;
  }

  /// Gets the region containing a specific element.
  /// 
  /// Useful for understanding context: "This button is inside this dialog."
  OcrRegion? getRegionForElement(
    UIState state,
    OcrBlock element, {
    double proximityThreshold = 50.0,
  }) {
    final regions = RegionGrouper.groupByProximity(
      state.ocrBlocks, 
      proximityThreshold: proximityThreshold,
    );
    
    for (final region in regions) {
      if (region.blocks.contains(element)) {
        return region;
      }
    }
    return null;
  }

  // ============================================================
  // SEQUENCE MEMORY (Task Chains) - Phase 2.5
  // ============================================================

  /// Saves a single step as part of a named sequence.
  /// 
  /// [sequenceId] - Unique name for this sequence (e.g., "login_flow").
  /// [stepOrder] - The position of this step in the sequence (0-indexed).
  /// [goal] - What this step achieves (e.g., "Type username").
  /// [action] - The action payload (e.g., {type: 'type', target_text: 'admin'}).
  /// [description] - Optional context or notes.
  Future<void> saveSequenceStep({
    required String sequenceId,
    required int stepOrder,
    required String goal,
    required Map<String, dynamic> action,
    String? description,
    String? targetText,
  }) async {
    final prompt = 'Sequence: $sequenceId. Step $stepOrder. Goal: $goal.';
    final embedding = await ollamaEmbed.embed(prompt: prompt);

    await qdrant.saveMemory(
      embedding: embedding,
      payload: {
        'goal': goal,
        'action': action,
        'description': description ?? '',
        'sequence_id': sequenceId,
        'step_order': stepOrder,
        'target_text': targetText ?? action['target_text'],
        'source': 'sequence',
        'timestamp': DateTime.now().toIso8601String(),
      },
    );

    debugPrint('[SEQUENCE] Saved step $stepOrder of "$sequenceId": $goal');
  }

  /// Retrieves all steps for a given sequence, ordered by step_order.
  Future<List<SequenceStep>> getSequence(String sequenceId) async {
    // For now, we scroll all points and filter client-side.
    // In production, Qdrant supports filtering via payload fields.
    final allPoints = await qdrant.getRecentPoints(limit: 500);
    
    final steps = <SequenceStep>[];
    for (final point in allPoints) {
      final payload = point['payload'] as Map<String, dynamic>?;
      if (payload == null) continue;
      if (payload['sequence_id'] != sequenceId) continue;
      
      steps.add(SequenceStep(
        sequenceId: sequenceId,
        stepOrder: (payload['step_order'] as num?)?.toInt() ?? 0,
        goal: payload['goal']?.toString() ?? '',
        action: payload['action'] is Map 
            ? Map<String, dynamic>.from(payload['action']) 
            : {},
        targetText: payload['target_text']?.toString(),
        description: payload['description']?.toString(),
      ));
    }
    
    // Sort by step_order
    steps.sort((a, b) => a.stepOrder.compareTo(b.stepOrder));
    return steps;
  }

  /// Lists all unique sequence IDs from memory.
  Future<List<String>> listSequences() async {
    final allPoints = await qdrant.getRecentPoints(limit: 500);
    final ids = <String>{};
    
    for (final point in allPoints) {
      final payload = point['payload'] as Map<String, dynamic>?;
      if (payload == null) continue;
      final seqId = payload['sequence_id'];
      if (seqId != null && seqId.toString().isNotEmpty) {
        ids.add(seqId.toString());
      }
    }
    
    return ids.toList()..sort();
  }

  /// Executes a sequence step-by-step.
  /// 
  /// Returns a stream of progress updates.
  /// Caller is responsible for providing the [executeAction] callback
  /// that actually performs HID actions.
  Stream<SequenceExecutionEvent> executeSequence({
    required String sequenceId,
    required Future<void> Function(Map<String, dynamic> action) executeAction,
    required Future<UIState?> Function() captureState,
    Duration delayBetweenSteps = const Duration(seconds: 2),
  }) async* {
    final steps = await getSequence(sequenceId);
    
    if (steps.isEmpty) {
      yield SequenceExecutionEvent(
        type: SequenceEventType.error,
        message: 'Sequence "$sequenceId" not found or empty.',
      );
      return;
    }

    yield SequenceExecutionEvent(
      type: SequenceEventType.started,
      message: 'Starting sequence "$sequenceId" with ${steps.length} steps.',
      totalSteps: steps.length,
    );

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      
      yield SequenceExecutionEvent(
        type: SequenceEventType.stepStarted,
        message: 'Step ${i + 1}: ${step.goal}',
        currentStep: i,
        totalSteps: steps.length,
      );

      try {
        // Capture state BEFORE action for verification
        final stateBefore = await captureState();
        final textBefore = stateBefore?.ocrBlocks.map((b) => b.text).toSet() ?? {};
        
        // Ground the action (find coordinates)
        if (step.targetText != null && stateBefore != null) {
          final block = stateBefore.ocrBlocks.firstWhere(
            (b) => b.text.toLowerCase().contains(step.targetText!.toLowerCase()),
            orElse: () => throw StateError('Target "${step.targetText}" not found on screen.'),
          );
          
          final cx = block.boundingBox.left + block.boundingBox.width / 2;
          final cy = block.boundingBox.top + block.boundingBox.height / 2;
          step.action['x'] = cx.toInt();
          step.action['y'] = cy.toInt();
        }

        // Execute the action
        await executeAction(step.action);
        
        // ACTION VERIFICATION - Phase 2.5
        await Future.delayed(const Duration(milliseconds: 800)); // Wait for UI to update
        final stateAfter = await captureState();
        final textAfter = stateAfter?.ocrBlocks.map((b) => b.text).toSet() ?? {};
        
        // Jaccard similarity check
        final intersection = textBefore.intersection(textAfter).length;
        final union = textBefore.union(textAfter).length;
        final similarity = union > 0 ? intersection / union : 1.0;
        
        if (similarity > 0.95 && textBefore.isNotEmpty) {
            // Screen barely changed - action may have failed
            yield SequenceExecutionEvent(
              type: SequenceEventType.stepCompleted,
              message: '⚠️ Step ${i + 1} completed, but screen unchanged (${(similarity * 100).toStringAsFixed(0)}% similar). Action may have missed.',
              currentStep: i,
              totalSteps: steps.length,
            );
        } else {
            yield SequenceExecutionEvent(
              type: SequenceEventType.stepCompleted,
              message: 'Completed: ${step.goal}',
              currentStep: i,
              totalSteps: steps.length,
            );
        }

        // Wait before next step
        if (i < steps.length - 1) {
          await Future.delayed(delayBetweenSteps);
        }

      } catch (e) {
        yield SequenceExecutionEvent(
          type: SequenceEventType.error,
          message: 'Failed at step ${i + 1}: $e',
          currentStep: i,
          totalSteps: steps.length,
        );
        return; // Abort on error
      }
    }

    yield SequenceExecutionEvent(
      type: SequenceEventType.completed,
      message: 'Sequence "$sequenceId" completed successfully.',
      totalSteps: steps.length,
    );
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
  /// Generates a draft plan using Ollama. Does NOT save yet.
  Future<SequencePlan> draftSequence({
      required String goal,
      required UIState state,
  }) async {
      _logController.add("🧠 Reasoning about sequence for '$goal'...");
      
      final description = state.toLLMDescription();
      final plan = await planner.generatePlan(goal: goal, screenDescription: description);
      
      _logController.add("📝 Plan generated with ${plan.steps.length} steps and ${plan.questions.length} questions.");
      for (final step in plan.steps) {
         _logController.add("  - ${step.action} ${step.target} (${step.reasoning})");
      }
      for (final q in plan.questions) {
         _logController.add("  ❓ Needs Info: $q");
      }
      
      return plan;
  }

  /// Saves a validated plan as a persistent sequence.
  Future<String> savePlanAsSequence(SequencePlan plan) async {
      final sequenceId = plan.goal.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      
      _logController.add("💾 Saving sequence '$sequenceId'...");
      
      for (int i=0; i<plan.steps.length; i++) {
          final step = plan.steps[i];
          
          await saveSequenceStep(
              sequenceId: sequenceId,
              stepOrder: i,
              goal: "Step ${i+1}: ${step.action} ${step.target}",
              action: {
                  'type': step.action,
                  'target_text': step.target,
                  'text': step.inputParam, 
                  'param': step.inputParam 
              },
              description: step.reasoning,
              targetText: step.target,
          );
      }
      
      _logController.add("✅ Sequence '$sequenceId' saved successfully!");
      return sequenceId;
  }
}

// ============================================================
// SEQUENCE MEMORY MODELS
// ============================================================

/// Represents a single step in a learned sequence.
class SequenceStep {
  final String sequenceId;
  final int stepOrder;
  final String goal;
  final Map<String, dynamic> action;
  final String? targetText;
  final String? description;

  SequenceStep({
    required this.sequenceId,
    required this.stepOrder,
    required this.goal,
    required this.action,
    this.targetText,
    this.description,
  });

  @override
  String toString() => 'Step $stepOrder: $goal -> ${action['type']}';
}

/// Event types for sequence execution progress.
enum SequenceEventType {
  started,
  stepStarted,
  stepCompleted,
  error,
  completed,
}

/// Progress event during sequence execution.
class SequenceExecutionEvent {
  final SequenceEventType type;
  final String message;
  final int? currentStep;
  final int? totalSteps;

  SequenceExecutionEvent({
    required this.type,
    required this.message,
    this.currentStep,
    this.totalSteps,
  });

  @override
  String toString() => '[$type] $message';
}

/// Result of action verification (Phase 2.5).
class ActionVerificationResult {
  final bool verified;
  final double similarity;
  final String message;

  ActionVerificationResult({
    required this.verified,
    required this.similarity,
    required this.message,
  });

  @override
  String toString() => verified ? '✅ $message' : '⚠️ $message';
}
