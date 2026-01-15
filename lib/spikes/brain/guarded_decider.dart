import 'dart:convert';

import '../../vision/ocr_models.dart';
import 'ollama_client.dart';
import 'pvt_actions.dart';

class GuardedDecider {
  GuardedDecider({required this.ollama});

  final OllamaClient ollama;

  /// Calls the LLM ONLY when explicitly invoked.
  ///
  /// Guardrails:
  /// - strict JSON-only
  /// - allow-listed actions
  /// - retry once on invalid JSON
  Future<DecisionResult> decideNext({
    required String goal,
    required UIState uiState,
    required List<Map<String, Object?>> recentActions,
  }) async {
    final prompt = _buildPrompt(
      goal: goal,
      uiState: uiState,
      recentActions: recentActions,
    );

    final text = await ollama.generate(
      prompt: prompt,
      numPredict: 160,
      temperature: 0.2,
    );

    final parsed = _tryParseAction(text);
    if (parsed != null) {
      return DecisionResult(action: parsed, raw: text, retried: false);
    }

    final retryText = await ollama.generate(
      prompt: _buildRetryPrompt(prompt: prompt, badOutput: text),
      numPredict: 160,
      temperature: 0.2,
    );

    final retryParsed = _tryParseAction(retryText);
    if (retryParsed == null) {
      throw FormatException(
        'Invalid JSON from LLM after retry. Raw: ${_truncate(retryText, 400)}',
      );
    }

    return DecisionResult(action: retryParsed, raw: retryText, retried: true);
  }

  PvtAction? _tryParseAction(String s) {
    final trimmed = s.trim();
    try {
      final decoded = jsonDecode(trimmed);
      return PvtAction.parseStrict(decoded);
    } catch (_) {
      return null;
    }
  }

  String _buildPrompt({
    required String goal,
    required UIState uiState,
    required List<Map<String, Object?>> recentActions,
  }) {
    final recent = recentActions.take(5).toList(growable: false);

    // Keep the prompt small: include only top N OCR blocks by area.
    final blocks = [...uiState.ocrBlocks]
      ..sort((a, b) => b.boundingBox.area.compareTo(a.boundingBox.area));
    final topBlocks = blocks.take(30).map((b) => b.toJson()).toList();

    final compactUiState = {
      'created_at': uiState.createdAt.toIso8601String(),
      'image': {
        'width': uiState.imageWidth,
        'height': uiState.imageHeight,
      },
      'derived': uiState.derived.toJson(),
      'ocr_blocks': topBlocks,
    };

    return '''You are a safe UI automation assistant.

Goal: ${goal.trim()}

You will be given the current UIState from OCR and a short history of recent actions.
Return ONLY valid JSON with NO extra text. Do not use markdown.

Allowed actions: ${PvtAction.allowList.join(', ')}

Schema (example keys):
${PvtAction.schemaDescription()}

Rules:
- Prefer NOOP if uncertain.
- Prefer CLICK only when the target text is present in OCR.
- If a modal/error is likely, prefer clicking a safe button like OK/Close/Cancel/Retry.
- Never invent UI text; use OCR blocks.

Recent actions (most recent first):
${const JsonEncoder.withIndent('  ').convert(recent)}

UIState:
${const JsonEncoder.withIndent('  ').convert(compactUiState)}
''';
  }

  String _buildRetryPrompt({required String prompt, required String badOutput}) {
    return '''$prompt

Your previous output was invalid.
You MUST output JSON only, matching the schema and allow-list.

Bad output:
${_truncate(badOutput, 1200)}
''';
  }

  String _truncate(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }
}

class DecisionResult {
  const DecisionResult({
    required this.action,
    required this.raw,
    required this.retried,
  });

  final PvtAction action;
  final String raw;
  final bool retried;
}
