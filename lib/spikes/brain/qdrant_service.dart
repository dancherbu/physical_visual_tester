import 'dart:convert';
import 'package:http/http.dart' as http;

class QdrantService {
  QdrantService({
    required this.baseUrl,
    required this.collectionName,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String collectionName;
  final http.Client _http;

  /// Saves a memory (Visual State + Action) to Qdrant.
  /// 
  /// [embedding] must be provided (usually generating by Ollama/Nomic).
  /// [payload] contains the Action metadata (e.g., "CLICK 'Submit'").
  Future<void> saveMemory({
    required List<double> embedding,
    required Map<String, dynamic> payload,
  }) async {
    final url = baseUrl.resolve('/collections/$collectionName/points');
    final pointId = DateTime.now().millisecondsSinceEpoch; // Simple ID generation

    final body = jsonEncode({
      'points': [
        {
          'id': pointId,
          'vector': embedding,
          'payload': payload,
        }
      ]
    });

    final resp = await _http.put(
      url,
      headers: {'content-type': 'application/json'},
      body: body,
    );

    if (resp.statusCode >= 300) {
      throw StateError('Qdrant save failed: ${resp.body}');
    }
  }

  /// Finds the most similar memory to the given [queryEmbedding].
  Future<List<Map<String, dynamic>>> search({
    required List<double> queryEmbedding,
    int limit = 3,
  }) async {
    final url = baseUrl.resolve('/collections/$collectionName/points/search');
    
    final body = jsonEncode({
      'vector': queryEmbedding,
      'limit': limit,
      'with_payload': true,
    });

    final resp = await _http.post(
      url,
      headers: {'content-type': 'application/json'},
      body: body,
    );

    if (resp.statusCode >= 300) {
      throw StateError('Qdrant search failed: ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    final result = decoded['result'] as List;
    return result.cast<Map<String, dynamic>>();
  }
}
