import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:physical_visual_tester/robot/robot_service.dart';
import 'package:physical_visual_tester/vision/ocr_models.dart';
import 'package:physical_visual_tester/spikes/brain/ollama_client.dart';
import 'package:physical_visual_tester/spikes/brain/qdrant_service.dart';

void main() {
  test('Analyze Knowledge Coverage for File Explorer Mock', () async {
    // 1. Setup Service (Mocking Qdrant/Ollama locally not strictly necessary if we query real)
    // But for this test, we want to QUERY the real Qdrant to see what we hit.
    
    // We assume the local servers are running as per previous steps.
    final robot = RobotService(
       ollama: OllamaClient(baseUrl: Uri.parse('http://localhost:11434'), model: 'llama3.2:3b'),
       ollamaEmbed: OllamaClient(baseUrl: Uri.parse('http://localhost:11434'), model: 'nomic-embed-text'),
       qdrant: QdrantService(baseUrl: Uri.parse('http://localhost:6333'), collectionName: 'pvt_memory'),
    );

    // 2. Mock OCR Data for "file_explorer_window.png"
    // Ideally we'd use the real image and real OCR, but we can simulate the "Text" inputs
    // that ML Kit would find on that image.
    final mockOcrTexts = [
        "File Explorer", "Quick access", "Desktop", "Downloads", "Documents", "Pictures",
        "This PC", "Local Disk (C:)", "Network", "Search Quick access", "File", "Home", "Share", "View"
    ];

    print("🔍 Analyzing ${mockOcrTexts.length} UI elements against Knowledge Base...");
    
    int greenCount = 0;
    int redCount = 0;
    
    for (final text in mockOcrTexts) {
        // Construct a dummy UIState context
        final state = UIState(
            ocrBlocks: [OcrBlock(text: text, boundingBox: const BoundingBox(left:0,top:0,right:0,bottom:0))], 
            imageWidth: 100, imageHeight: 100, 
            derived: const DerivedFlags(hasModalCandidate: false, hasErrorCandidate: false, modalKeywords: []), 
            createdAt: DateTime.now()
        );

        // We use the exact same logic as the App: fetchKnownInteractiveElements
        // But since that method returns a Set<String> of *all* knowns on screen,
        // we might want to query individually to get specific "confidence".
        
        // Match the seeding format:
        // "Goal: {goal}. Screen: {description}\nPrerequisites: {prereqs}. Action: Click {target}"
        
        // Since we don't know the exact description/prereqs used in seeding (as it varies),
        // we construct a "Best Guess" query that includes the relevant keywords.
        // Or better, we search for the GOAL directly if we can infer it.
        
        // Let's try to match the "Goal" we expect.
        // E.g. for "Quick access", the goal is "Go to Quick Access".
        // The embedded text was: "Goal: Go to Quick Access. Screen: ... Action: Click Quick access"
        
        // So a query like "Goal: Open Quick Access" should work if the model is semantic.
        // But to be safer, we include the action text in the query too.
        
        final queryPrompt = "Goal: Interact with '$text'. Action: Click $text";
           
        try {
           final embedding = await robot.ollamaEmbed.embed(prompt: queryPrompt);
           final memories = await robot.qdrant.search(queryEmbedding: embedding, limit: 1);
           
           if (memories.isNotEmpty) {
               final score = memories.first['score'] as double;
               final payload = memories.first['payload'];
               final goal = payload['goal'];
               
               if (score > 0.85) {
                   print("✅ [GREEN] '$text' -> Known as '$goal' (Score: ${score.toStringAsFixed(2)})");
                   greenCount++;
               } else {
                   print("xC [RED]   '$text' -> Low Confidence (Best: '$goal' @ ${score.toStringAsFixed(2)})");
                   redCount++;
               }
           } else {
               print("❌ [RED]   '$text' -> No Memory Found");
               redCount++;
           }
        } catch (e) {
           print("⚠️ Error checking '$text': $e");
           redCount++;
        }
    }
    
    print("\n📊 FINAL SCORE for 'file_explorer_window.png'");
    print("---------------------------------------");
    print("Green Boxes (Known): $greenCount");
    print("Red Boxes (Unknown): $redCount");
    print("Knowledge Coverage : ${((greenCount / mockOcrTexts.length) * 100).toStringAsFixed(1)}%");
  });
}
