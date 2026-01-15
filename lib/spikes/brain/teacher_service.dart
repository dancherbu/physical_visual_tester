import 'package:flutter/foundation.dart';
import '../../vision/ocr_models.dart';
import 'ollama_client.dart';
import 'qdrant_service.dart';

class TeacherService {
  TeacherService({
    required this.ollama,
    required this.qdrant,
  });

  final OllamaClient ollama;
  final QdrantService qdrant;

  /// Learns a new task:
  /// 1. Generates an embedding for the visual [state].
  /// 2. Saves the {Embedding, Action, Goal} tuple to Memory (Qdrant).
  Future<void> learnTask({
    required UIState state,
    required String goal, // e.g., "Click File Menu"
    required Map<String, dynamic> action, // e.g., {'type': 'click', 'x': 0.1, 'y': 0.2}
  }) async {
    // 1. Describe the state for the LLM/Embedder
    final description = state.toLLMDescription();
    
    // 2. Generate Embedding (Vector)
    final embedding = await ollama.embed(prompt: description);

    // 3. Save to Qdrant
    // Payload includes the raw OCR/State for debugging + the executable action
    final payload = {
      'goal': goal,
      'action': action,
      'description': description,
      'original_state': state.toJson(), // Optional: might be too big?
      'timestamp':  DateTime.now().toIso8601String(),
    };

    await qdrant.saveMemory(
      embedding: embedding,
      payload: payload,
    );
  }

  /// Asks Ollama to label the action based on the visual context.
  Future<String> suggestLabel({
    required OcrBlock block,
    List<String>? debugImages, // Base64 of the screen/crop
  }) async {
    final text = block.text.replaceAll('\n', ' ').trim();
    
    // 1. If we have images (Vision Model available like LLaVA)
    if (debugImages != null && debugImages.isNotEmpty) {
      try {
        final prompt = 'I am clicking the UI element with text "$text". '
            'Based on the image, what action am I performing? '
            'Keep it very short (e.g. "Click File Menu", "Submit Form").';
            
        final response = await ollama.generate(
          prompt: prompt,
          images: debugImages,
          numPredict: 20, // Short answer
        );
        
        return response.trim().replaceAll('"', '');
      } catch (e) {
        // Fallback if Vision fails
        debugPrint('Vision suggestion failed: $e');
      }
    }

    // 2. Text-only Heuristics / LLM
    // We can use a smaller text model to guess based on the text content.
    final prompt = 'I clicked a button labeled "$text". '
        'Suggest a short name for this action (max 4 words). '
        'Examples: "Open Settings", "Click Submit", "Select Profile".';

    try {
      final response = await ollama.generate(prompt: prompt, numPredict: 15);
      return response.trim().replaceAll('"', '');
    } catch (_) {
      // 3. Fallback: simple echo
      return 'Click $text';
    }
  }

  /// Recalls specific actions for a given state and goal.
  /// (This is the "Student" mode logic, included here for completeness/testing)
  Future<List<Map<String, dynamic>>> recall({
    required UIState currentState,
    required String goal,
  }) async {
     final description = currentState.toLLMDescription();
     final embedding = await ollama.embed(prompt: description);
     
     // TODO: We probably want to search by (ImageState + Goal) combined?
     // For now, we search by Image Similarity, then filter/rank by Goal? 
     // Or we embed the Goal into the vector too? 
     // "Teacher" model usually embeds (State + Goal). 
     // But simplistic start: Embed State. Search. Filter by Goal in payload?
     
     // Better approach for Qdrant: 
     // Vector = Embed(State). 
     // Filter = Payload value "goal" == goal.
     
     final results = await qdrant.search(
       queryEmbedding: embedding,
       // TODO: Add filter for 'goal' match if QdrantService supports it
     );
     
     return results;
  }
  /// Asks Ollama to scan the full image and list important elements.
  /// Returns a list of labels that likely correspond to actionable buttons/menus.
  Future<List<String>> suggestActionableFeatures(String base64Image) async {
    const prompt = 'Look at this software interface. '
        'List the text labels of the 10 most important actionable buttons, tabs, or menus you see. '
        'Output purely as a comma-separated list. Example: File, Edit, Save, Search, Settings.';

    try {
      final response = await ollama.generate(
        prompt: prompt,
        images: [base64Image],
        numPredict: 64, // Sufficient for a list
        temperature: 0.1, // Deterministic
      );
      
      // Cleanup response
      final clean = response.replaceAll(RegExp(r'[\[\]"\.]'), '');
      final items = clean.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      return items;
    } catch (e) {
      debugPrint('Auto-discovery failed: $e');
      return [];
    }
  }
}
