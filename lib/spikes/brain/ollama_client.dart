import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

    if (images != null && images.isNotEmpty) {
      // [DEBUG] Vision model request logging
      debugPrint('[OLLAMA VISION] 🖼️ GENERATE REQUEST');
      debugPrint('[OLLAMA VISION]   model: $model');
      debugPrint('[OLLAMA VISION]   prompt_len: ${prompt.length} chars');
      debugPrint('[OLLAMA VISION]   prompt_preview: ${prompt.substring(0, prompt.length > 200 ? 200 : prompt.length)}...');
      debugPrint('[OLLAMA VISION]   images: ${images.length} image(s)');
      for (var i = 0; i < images.length; i++) {
        debugPrint('[OLLAMA VISION]   image[$i] base64_len: ${images[i].length} chars');
      }
      debugPrint('[OLLAMA VISION]   numPredict: $numPredict, temperature: $temperature');
      
      final stopwatch = Stopwatch()..start();
      
      final response = await _retryRequest(() async {
        final client = http.Client();
        try {
          return await client
              .post(
                url,
                headers: {
                  'content-type': 'application/json',
                  'connection': 'close',
                },
                body: jsonEncode({
                  'model': model,
                  'prompt': prompt,
                  'stream': false,
                  'images': images,
                  'options': {
                    'num_predict': numPredict,
                    'temperature': temperature,
                  },
                }),
              )
              .timeout(const Duration(seconds: 600));
        } finally {
          client.close();
        }
      });
      
      stopwatch.stop();
      debugPrint('[OLLAMA VISION] ⏱️ Response received in ${stopwatch.elapsed.inSeconds}s');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[OLLAMA VISION] ❌ HTTP ERROR: ${response.statusCode}');
        debugPrint('[OLLAMA VISION]   body: ${response.body}');
        throw StateError('Ollama HTTP ${response.statusCode}: ${response.body}');
      }

      final json = jsonDecode(response.body);
      final result = json['response']?.toString() ?? '';
      
      debugPrint('[OLLAMA VISION] ✅ RESPONSE SUCCESS');
      debugPrint('[OLLAMA VISION]   response_len: ${result.length} chars');
      debugPrint('[OLLAMA VISION]   response_preview: ${result.substring(0, result.length > 500 ? 500 : result.length)}');
      
      return result;
    }

    final request = http.Request('POST', url);
    request.headers['content-type'] = 'application/json';
    request.body = jsonEncode({
      'model': model,
      'prompt': prompt,
      'stream': true, // [FIX] Re-enable streaming now that firewall is fixed
      'options': {
        'num_predict': numPredict,
        'temperature': temperature,
      },
    });

    return _retryRequest(() async {
      final loopedClient = http.Client();
      try {
        final streamedResponse = await loopedClient.send(request).timeout(const Duration(seconds: 12));

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
          } catch (_) {
            // ignore parse errors for partial chunks
          }
        }

        return buffer.toString();
      } finally {
        loopedClient.close();
      }
    });
  }

  Future<List<double>> embed({
    required String prompt,
  }) async {
    debugPrint('[OLLAMA] 🔤 EMBED: model=$model, prompt_len=${prompt.length}');
    final url = baseUrl.resolve('/api/embeddings');
    final response = await _retryRequest(() async {
      final client = http.Client();
      try {
        return await client
            .post(
              url,
              headers: {
                'content-type': 'application/json',
                'connection': 'close',
              },
              body: jsonEncode({
                'model': model,
                'prompt': prompt,
              }),
            )
            .timeout(const Duration(seconds: 30));
      } finally {
        client.close();
      }
    });

    if (response.statusCode != 200) {
      debugPrint('[OLLAMA] ❌ EMBED FAILED: ${response.statusCode} ${response.body}');
      throw StateError('Ollama embed failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body);
    final embedding = (json['embedding'] as List).cast<double>();
    
    if (embedding.isEmpty) {
        debugPrint('[OLLAMA] ❌ EMBED returned EMPTY embedding!');
        throw StateError("Ollama returned empty embedding for model '$model'.");
    }
    
    debugPrint('[OLLAMA] ✅ EMBED SUCCESS: dim=${embedding.length}');
    return embedding;
  }

  Future<T> _retryRequest<T>(
    Future<T> Function() action, {
    int maxAttempts = 2,
    Duration baseDelay = const Duration(milliseconds: 500),
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on StateError {
        rethrow;
      } on TimeoutException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: baseDelay.inMilliseconds * attempt));
      }
    }
    if (lastError != null) {
      throw lastError!;
    }
    throw StateError('Ollama request failed.');
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
