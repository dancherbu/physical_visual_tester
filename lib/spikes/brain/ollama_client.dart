import 'dart:convert';

import 'package:http/http.dart' as http;

class OllamaClient {
  OllamaClient({
    required this.baseUrl,
    required this.model,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String model;
  final http.Client _http;

  Future<String> generate({
    required String prompt,
    int numPredict = 128,
    double temperature = 0.2,
  }) async {
    final url = baseUrl.resolve('/api/generate');

    final body = jsonEncode({
      'model': model,
      'prompt': prompt,
      'stream': false,
      'options': {
        'num_predict': numPredict,
        'temperature': temperature,
      },
    });

    final resp = await _http.post(
      url,
      headers: {
        'content-type': 'application/json',
      },
      body: body,
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError(
        'Ollama HTTP ${resp.statusCode}: ${resp.body}',
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw const FormatException('Unexpected Ollama response format.');
    }

    final responseText = decoded['response'];
    if (responseText is! String) {
      throw const FormatException('Ollama response missing "response" string.');
    }

    return responseText;
  }

  void close() {
    _http.close();
  }
}
