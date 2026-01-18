
import 'package:flutter_test/flutter_test.dart';
import 'package:physical_visual_tester/robot/robot_service.dart';
import 'package:physical_visual_tester/robot/training_model.dart';
import 'package:physical_visual_tester/spikes/brain/ollama_client.dart';
import 'package:physical_visual_tester/spikes/brain/qdrant_service.dart';
import 'package:physical_visual_tester/vision/ocr_models.dart';
// import 'package:mockito/mockito.dart';
import 'dart:ui'; // For Offset (need flutter_test for this usually, or just mock)

// Simple Fake Qdrant
class FakeQdrant extends QdrantService {
  FakeQdrant() : super(baseUrl: Uri.parse('http://fake'), collectionName: 'fake');
  
  @override
  Future<List<Map<String, dynamic>>> search({required List<double> queryEmbedding, int limit = 1}) async {
    // Always return "Click Start" memory
    return [
      {
        'score': 0.95,
        'payload': {
           'goal': 'Open Start Menu',
           'action': {
               'type': 'click',
               'target_text': 'Start'
           }
        }
      }
    ];
  }
}

// Simple Fake Ollama (Stub)
class FakeOllama extends OllamaClient {
   FakeOllama() : super(baseUrl: Uri.parse('http://fake'), model: 'fake');
   @override
   Future<List<double>> embed({required String prompt}) async => [0.1, 0.2];
}

void main() {
  test('Robot Decision Grounding Test', () async {
      final robot = RobotService(
        ollama: FakeOllama(),
        ollamaEmbed: FakeOllama(),
        qdrant: FakeQdrant(),
      );
      
      // SCENARIO 1: Screen MISSING "Start" button
      // Only has "Recycle Bin"
      final wrongScreen = UIState(
          ocrBlocks: [
             OcrBlock(text: "Recycle Bin", boundingBox: BoundingBox(left: 0, top: 0, right: 100, bottom: 100))
          ],
          imageWidth: 1920,
          imageHeight: 1080, derived: DerivedFlags(hasModalCandidate: false, hasErrorCandidate: false, modalKeywords: []), createdAt: DateTime.now()
      );
      
      final decision1 = await robot.think(state: wrongScreen, currentGoal: "Open Start Menu");
      
      print("Decision 1 (Wrong Screen): ${decision1.reasoning}");
      expect(decision1.isConfident, false, reason: "Should fail because 'Start' is missing");
      expect(decision1.reasoning, contains("cannot find it"));

      // SCENARIO 2: Screen HAS "Start" button
      final correctScreen = UIState(
          ocrBlocks: [
             OcrBlock(text: "Start", boundingBox: BoundingBox(left: 50, top: 1000, right: 100, bottom: 1050))
             // Center X = 75, Y = 1025
          ],
          imageWidth: 1920,
          imageHeight: 1080, derived: DerivedFlags(hasModalCandidate: false, hasErrorCandidate: false, modalKeywords: []), createdAt: DateTime.now()
      );
      
      final decision2 = await robot.think(state: correctScreen, currentGoal: "Open Start Menu");
      
      print("Decision 2 (Correct Screen): ${decision2.reasoning}");
      expect(decision2.isConfident, true, reason: "Should succeed because 'Start' is present");
      expect(decision2.action!['x'], 75);
      expect(decision2.action!['y'], 1025);
  });
}
