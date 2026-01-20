import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:physical_visual_tester/robot/robot_service.dart';
import 'package:physical_visual_tester/spikes/brain/ollama_client.dart';
import 'package:physical_visual_tester/spikes/brain/qdrant_service.dart';
import 'package:physical_visual_tester/vision/ocr_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowHttpOverrides();

  test('Idle analysis POC (file_explorer_window.png)', () async {
    final imagePath = 'assets/mock/file_explorer_window.png';
    final imageFile = File(imagePath);
    expect(imageFile.existsSync(), isTrue, reason: 'Missing image: $imagePath');

    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);
    final decoded = img.decodeImage(bytes);
    final width = decoded?.width ?? 1;
    final height = decoded?.height ?? 1;

    final ocrText = await _runTesseract(imagePath);
    if (ocrText.trim().isEmpty) {
      // Still proceed; OCR gate will filter outputs.
      // This is a POC test, not an assertion of OCR quality.
      // ignore: avoid_print
      print('⚠️ OCR returned empty text. Results may be filtered.');
    }

    final state = UIState(
      ocrBlocks: [
        OcrBlock(
          text: ocrText.trim(),
          boundingBox: BoundingBox(
            left: 0,
            top: 0,
            right: width.toDouble(),
            bottom: height.toDouble(),
          ),
        ),
      ],
      imageWidth: width,
      imageHeight: height,
      derived: const DerivedFlags(
        hasModalCandidate: false,
        hasErrorCandidate: false,
        modalKeywords: [],
      ),
      createdAt: DateTime.now(),
    );

    final ollamaUrl = const String.fromEnvironment('OLLAMA_URL', defaultValue: 'http://localhost:11434');
    final qdrantUrl = const String.fromEnvironment('QDRANT_URL', defaultValue: 'http://localhost:6333');
    final model = const String.fromEnvironment('OLLAMA_MODEL', defaultValue: 'llava');
    final embedModel = const String.fromEnvironment('OLLAMA_EMBED', defaultValue: 'nomic-embed-text');
    final collection = const String.fromEnvironment('QDRANT_COLLECTION', defaultValue: 'pvt_memory_poc');

    final ollama = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: model);
    final embedder = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: embedModel);
    final qdrant = QdrantService(baseUrl: Uri.parse(qdrantUrl), collectionName: collection);
    final robot = RobotService(ollama: ollama, ollamaEmbed: embedder, qdrant: qdrant);

    // ignore: avoid_print
    print('Running idle analysis with model=$model, collection=$collection');
    final result = await robot.analyzeIdlePage(
      state,
      imageBase64: base64Image,
      questionsOnly: true,
      minQuestions: 20,
    );

    // ignore: avoid_print
    print('--- Messages ---');
    for (final msg in result.messages) {
      // ignore: avoid_print
      print(msg);
    }

    // ignore: avoid_print
    print('--- Learned Items ---');
    for (final item in result.learnedItems) {
      // ignore: avoid_print
      print(item);
    }

    ollama.close();
    embedder.close();

    expect(true, isTrue); // POC-only
  }, timeout: const Timeout(Duration(minutes: 10)));
}

class _AllowHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

Future<String> _runTesseract(String imagePath) async {
  try {
    final result = await Process.run(
      'tesseract',
      [imagePath, 'stdout', '-l', 'eng'],
    );
    if (result.exitCode != 0) {
      // ignore: avoid_print
      print('Tesseract failed: ${result.stderr}');
      return '';
    }
    return result.stdout.toString();
  } catch (e) {
    // ignore: avoid_print
    print('OCR error: $e');
    return '';
  }
}
