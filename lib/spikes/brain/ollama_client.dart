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
    List<String>? images, 
    int numPredict = 128,
    double temperature = 0.2,
  }) async {
    final url = baseUrl.resolve('/api/generate');

    final request = http.Request('POST', url);
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode({
      'model': model,
      'prompt': prompt,
      'stream': true, // [FIX] Re-enable streaming now that firewall is fixed
      if (images != null) 'images': images,
      'options': {
        'num_predict': numPredict,
        'temperature': temperature,
      },
    });

    final loopedClient = http.Client();
    try {
      final streamedResponse = await loopedClient.send(request).timeout(const Duration(seconds: 300));
      
      if (streamedResponse.statusCode < 200 || streamedResponse.statusCode >= 300) {
         final body = await streamedResponse.stream.bytesToString();
         throw StateError('Ollama HTTP ${streamedResponse.statusCode}: $body');
      }

      final buffer = StringBuffer();
      
      await for (final chunk in streamedResponse.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (chunk.trim().isEmpty) continue;
          try {
              final json = jsonDecode(chunk);
              if (json['response'] != null) {
                  buffer.write(json['response']);
              }
          } catch (e) {
              // ignore parse errors for partial chunks
          }
      }
      
      return buffer.toString();

    } finally {
      loopedClient.close();
    }
  }

  Future<List<double>> embed({
    required String prompt,
  }) async {
    final url = baseUrl.resolve('/api/embeddings');
    final response = await _http.post(
      url,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'prompt': prompt,
      }),
    ).timeout(const Duration(seconds: 30)); 

    if (response.statusCode != 200) {
      throw StateError('Ollama embed failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body);
    final embedding = (json['embedding'] as List).cast<double>();
    return embedding;
  }

  Future<bool> ping() async {
    try {
      final url = baseUrl.resolve('/');
      final response = await _http.get(url).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _http.close();
  }
}
