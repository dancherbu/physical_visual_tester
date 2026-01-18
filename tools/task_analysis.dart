import 'dart:convert';
import 'dart:io';

import '../lib/spikes/brain/ollama_client.dart';
import '../lib/spikes/brain/qdrant_service.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final filePath = options['file'] ?? 'assets/tasks/login_tasks.txt';
  final ollamaUrl = options['ollama'] ?? 'http://localhost:11434';
  final qdrantUrl = options['qdrant'] ?? 'http://localhost:6333';
  final collection = options['collection'] ?? 'pvt_memory';
  final chatModel = options['model'] ?? 'llama3.2:3b';
  final embedModel = options['embed'] ?? 'nomic-embed-text';
  final threshold = double.tryParse(options['threshold'] ?? '') ?? 0.85;
  final noRerank = options['no-rerank'] == 'true';
  final noNormalize = options['no-normalize'] == 'true';

  final taskFile = File(filePath);
  if (!taskFile.existsSync()) {
    stderr.writeln('Task file not found: $filePath');
    exit(1);
  }

  final rawText = await taskFile.readAsString();
  final tasks = rawText
      .split('\n')
      .map((l) => l.trim().replaceAll(RegExp(r'^[\d\-\.\s]+'), ''))
      .where((l) => l.isNotEmpty)
      .toList();
  final limit = int.tryParse(options['limit'] ?? '') ?? tasks.length;

  final ollama = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: chatModel);
  final embedder = OllamaClient(baseUrl: Uri.parse(ollamaUrl), model: embedModel);
  final qdrant = QdrantService(baseUrl: Uri.parse(qdrantUrl), collectionName: collection);

  final results = <Map<String, dynamic>>[];
  int totalSteps = 0;
  int knownSteps = 0;

  final limitedTasks = tasks.take(limit).toList();

  for (final task in limitedTasks) {
    final steps = await _decomposeTask(ollama, task);
    final stepResults = <Map<String, dynamic>>[];
    bool taskKnown = true;

    for (final step in steps) {
      totalSteps++;
      final normalized = noNormalize ? step : await _normalizeStep(ollama, step);
      final embedding = await embedder.embed(prompt: normalized);
      final matches = await qdrant.search(queryEmbedding: embedding, limit: 5);

      double score = 0.0;
      Map<String, dynamic>? selected;
      if (matches.isNotEmpty) {
        selected = noRerank ? null : await _rerankMatch(ollama, step, matches);
        final picked = selected ?? matches.first;
        score = (picked['score'] as num).toDouble();
        selected = picked;
      }

      final isKnown = score >= threshold;
      if (isKnown) {
        knownSteps++;
      } else {
        taskKnown = false;
      }

      stepResults.add({
        'step': step,
        'confidence': score,
        'known': isKnown,
        if (selected != null) 'match': selected['payload'],
      });
    }

    results.add({
      'task': task,
      'known': taskKnown,
      'steps': stepResults,
    });
  }

  final confidence = totalSteps == 0 ? 100 : ((knownSteps / totalSteps) * 100).round();
  final summary = {
    'taskFile': filePath,
    'threshold': threshold,
    'tasks': limitedTasks.length,
    'stepsTotal': totalSteps,
    'stepsKnown': knownSteps,
    'confidencePercent': confidence,
    'results': results,
  };

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
  ollama.close();
  embedder.close();
}

Future<List<String>> _decomposeTask(OllamaClient ollama, String instruction) async {
  final prompt = '''
Break down this instruction into atomic UI actions (click, type, open).
Instruction: "$instruction"

Format as JSON List of strings. Example: ["Click Chrome", "Type Google.com", "Press Enter"]
''';

  try {
    final response = await ollama.generate(prompt: prompt, numPredict: 120);
    final clean = _extractJson(response);
    final decoded = jsonDecode(clean);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
    }
  } catch (_) {}

  return [instruction];
}

Future<String> _normalizeStep(OllamaClient ollama, String step) async {
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

Future<Map<String, dynamic>?> _rerankMatch(
  OllamaClient ollama,
  String step,
  List<Map<String, dynamic>> matches,
) async {
  final candidates = <Map<String, dynamic>>[];
  for (int i = 0; i < matches.length; i++) {
    final m = matches[i];
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
{"best_index": <index>, "confidence": <0.0-1.0>}
''';

  try {
    final response = await ollama.generate(prompt: prompt, numPredict: 120);
    final clean = _extractJson(response);
    final decoded = jsonDecode(clean);
    if (decoded is Map<String, dynamic>) {
      final idx = (decoded['best_index'] as num?)?.toInt();
      final confidence = (decoded['confidence'] as num?)?.toDouble();
      if (idx != null && idx >= 0 && idx < matches.length) {
        final selected = Map<String, dynamic>.from(matches[idx]);
        if (confidence != null && confidence.isFinite) {
          selected['score'] = confidence;
        }
        return selected;
      }
    }
  } catch (_) {}
  return null;
}

String _extractJson(String response) {
  final codeBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
  final match = codeBlockRegex.firstMatch(response);
  if (match != null) {
    response = match.group(1) ?? response;
  }

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

  if (index == -1) return '[]';
  String clean = response.substring(index);

  int end = -1;
  if (clean.startsWith('[')) {
    end = clean.lastIndexOf(']');
  } else {
    end = clean.lastIndexOf('}');
  }

  if (end != -1) {
    return clean.substring(0, end + 1);
  }
  if (clean.startsWith('[')) return '$clean]';
  if (clean.startsWith('{')) return '$clean}';
  return clean;
}

Map<String, String> _parseArgs(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) continue;
    final key = arg.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      options[key] = args[i + 1];
      i++;
    } else {
      options[key] = 'true';
    }
  }
  return options;
}
