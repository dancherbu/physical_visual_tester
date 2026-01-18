import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../spikes/brain/ollama_client.dart';
import 'robot_service.dart';
import '../vision/ocr_models.dart';

class OfflineTrainer {
  final RobotService robot;
  final Function(String) onLog;

  OfflineTrainer({required this.robot, required this.onLog});

  /// Main entry point to run the offline training batch.
  Future<void> runTraining() async {
    onLog("🚀 Starting Offline Training...");

    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final Map<String, dynamic> manifestMap = json.decode(manifestContent);
    
    // Filter for mock images
    final imagePaths = manifestMap.keys
        .where((key) => key.startsWith('assets/mock/') && 
               (key.endsWith('.png') || key.endsWith('.jpg')))
        .toList();

    onLog("📸 Found ${imagePaths.length} mock images.");

    for (final path in imagePaths) {
      await _trainOnImage(path);
    }

    onLog("✅ Offline Training Complete!");
  }

  Future<void> _trainOnImage(String assetPath) async {
    onLog("Processing: $assetPath...");
    
    try {
      // 1. Get raw bytes for Ollama
      final byteData = await rootBundle.load(assetPath);
      final bytes = byteData.buffer.asUint8List();
      final base64Image = base64Encode(bytes);

      // 2. Ask Ollama to extracting Knowledge (Description + Actions + Prerequisites)
      final prompt = '''
      Analyze this UI screen screenshot.
      
      Part 1: GLOBAL CONTEXT (Prerequisites)
      - Identify the Window Date/Time if visible.
      - Identify the Active Application (Window Title).
      - Identify the URL if it's a browser.
      - Identify any specific state (e.g. "Login Page", "Empty File", "Dashboard").
      
      Part 2: ACTIONABLE ELEMENTS
      - List every clickable button, link, or input field.
      - For each, infer the USER GOAL (e.g. "Log In", "Open Settings", "Type Text").
      - Infer the ACTION (click/type) and TARGET TEXT.
      
      OUTPUT JSON FORMAT ONLY:
      {
        "description": "A detailed description of the screen context...",
        "prerequisites": ["App: Notepad", "File: Empty"],
        "actions": [
          {
            "goal": "Save the file",
            "action": {"type": "click", "target_text": "File > Save"},
            "fact": "Opens the save dialog"
          }
        ]
      }
      ''';

      onLog("   ...Sending to Ollama (Vision)...");
      final response = await robot.ollama.generate(
        prompt: prompt,
        images: [base64Image],
        numPredict: 512, // Allow verbose output
      );
      
      final cleanJson = _extractJson(response);
      final data = jsonDecode(cleanJson);

      if (data is Map<String, dynamic>) {
        final description = data['description']?.toString() ?? "Unknown Screen";
        final prerequisites = (data['prerequisites'] as List?)?.cast<String>() ?? [];
        final actions = (data['actions'] as List?) ?? [];

        onLog("   ...Found ${actions.length} learnable actions. Context: $prerequisites");

        // 3. Save each action as a memory
        int savedCount = 0;
        
        // Create a dummy UIState for the signature
        final dummyState = UIState(
          ocrBlocks: [], // We don't have real OCR from asset without running ML Kit
          imageWidth: 0, 
          imageHeight: 0, 
          derived: const DerivedFlags(hasModalCandidate: false, hasErrorCandidate: false, modalKeywords: []), 
          createdAt: DateTime.now()
        );

        for (final item in actions) {
           if (item is Map<String, dynamic>) {
             final goal = item['goal']?.toString();
             final action = item['action'] as Map<String, dynamic>?;
             
             if (goal != null && action != null) {
               await robot.learn(
                 state: dummyState, // Ignored due to overrideDescription
                 goal: goal,
                 action: action,
                 prerequisites: prerequisites,
                 factualDescription: item['fact']?.toString(),
                 overrideDescription: "$description\nPrerequisites: ${prerequisites.join(', ')}",
               );
               savedCount++;
             }
           }
        }
        onLog("   ✅ Learned $savedCount skills from $assetPath.");
      }

    } catch (e) {
      onLog("   ❌ Error processing $assetPath: $e");
    }
  }

  String _extractJson(String response) {
      final start = response.indexOf('{');
      final end = response.lastIndexOf('}');
      if (start != -1 && end != -1) {
        return response.substring(start, end + 1);
      }
      return "{}";
  }
}
