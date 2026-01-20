import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import '../lib/robot/robot_service.dart';
import '../lib/spikes/brain/ollama_client.dart';
import '../lib/spikes/brain/qdrant_service.dart';
import '../lib/vision/ocr_models.dart';

void main(List<String> args) async {
  final options = _parseArgs(args);
  final imagePath = options['image'] ?? 'assets/mock/file_explorer_window.png';
  final ollamaUrl = options['ollama'] ?? 'http://localhost:11434';
  final qdrantUrl = options['qdrant'] ?? 'http://localhost:6333';
  final model = options['model'] ?? 'llama3.2-vision';
  final embedModel = options['embed'] ?? 'nomic-embed-text';
  final collection = options['collection'] ?? 'pvt_memory_poc';
  final visionOnly = (options['vision-only'] ?? 'true').toLowerCase() == 'true';
  final minQuestions = int.tryParse(options['min-questions'] ?? '20') ?? 20;

  final imageFile = File(imagePath);
  if (!imageFile.existsSync()) {
    stderr.writeln('Image not found: $imagePath');
    exit(1);
  }

  final bytes = await imageFile.readAsBytes();
  final base64Image = base64Encode(bytes);
  UIState? state;
  if (!visionOnly) {
    final decoded = img.decodeImage(bytes);
    final width = decoded?.width ?? 1;
    final height = decoded?.height ?? 1;

    final ocrText = await _runTesseract(imagePath);
    if (ocrText.trim().isEmpty) {
      stderr.writeln('⚠️ OCR returned empty text. Results may be filtered.');
    }

    state = UIState(
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
  }

  final ollama = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: model);
  final embedder = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: embedModel);
  final qdrant = QdrantService(baseUrl: Uri.parse(qdrantUrl), collectionName: collection);
  final robot = RobotService(ollama: ollama, ollamaEmbed: embedder, qdrant: qdrant);

  stdout.writeln('Running idle analysis (visionOnly=$visionOnly) with model=$model, collection=$collection');
  final stopwatch = Stopwatch()..start();
  final result = visionOnly
      ? await robot.analyzeIdlePageVisionOnly(
          imageBase64: base64Image,
          minQuestions: minQuestions,
        )
      : await robot.analyzeIdlePage(state!, imageBase64: base64Image);
  stopwatch.stop();
  stdout.writeln('Elapsed: ${stopwatch.elapsed.inMilliseconds} ms');

  stdout.writeln('--- Messages ---');
  final capped = result.messages.take(minQuestions).toList();
  for (final msg in capped) {
    stdout.writeln(msg);
  }

  stdout.writeln('--- Learned Items ---');
  for (final item in result.learnedItems) {
    stdout.writeln(item);
  }

  ollama.close();
  embedder.close();
}

Future<String> _runTesseract(String imagePath) async {
  try {
    final result = await Process.run(
      'tesseract',
      [imagePath, 'stdout', '-l', 'eng'],
    );
    if (result.exitCode != 0) {
      stderr.writeln('Tesseract failed: ${result.stderr}');
      return '';
    }
    return result.stdout.toString();
  } catch (e) {
    stderr.writeln('OCR error: $e');
    return '';
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final options = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final parts = arg.substring(2).split('=');
    if (parts.isEmpty) continue;
    final key = parts.first.trim();
    final value = parts.length > 1 ? parts.sublist(1).join('=').trim() : 'true';
    options[key] = value;
  }
  return options;
}
