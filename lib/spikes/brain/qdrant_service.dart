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

    if (resp.statusCode == 404) {
      // Auto-create collection and retry
      await createCollection();
      return saveMemory(embedding: embedding, payload: payload);
    }

    if (resp.statusCode >= 300) {
      throw StateError('Qdrant save failed: ${resp.body}');
    }
  }

  /// Creates the collection with standard configuration (768 dim, Cosine)
  Future<void> createCollection() async {
    final url = baseUrl.resolve('/collections/$collectionName');
    final body = jsonEncode({
      "vectors": {
        "size": 768, // nomic-embed-text dimension
        "distance": "Cosine"
      }
    });

    final resp = await _http.put(
        url,
        headers: {'content-type': 'application/json'},
        body: body
    );

    if (resp.statusCode >= 300) {
        throw StateError("Failed to create collection: ${resp.body}");
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

    if (resp.statusCode == 404) {
        return []; // Collection missing means no results
    }

    if (resp.statusCode >= 300) {
      throw StateError('Qdrant search failed: ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    final result = decoded['result'] as List;
    return result.cast<Map<String, dynamic>>();
  }

  Future<bool> ping() async {
    try {
      final url = baseUrl.resolve('/collections');
      final response = await _http.get(url).timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> getCollectionInfo() async {
    final url = baseUrl.resolve('/collections/$collectionName');
    final resp = await _http.get(url);
    
    // [FIX] If collection doesn't exist (e.g. after wipe), return empty stats
    if (resp.statusCode == 404) {
        return {'points_count': 0, 'vectors_count': 0};
    }

    if (resp.statusCode >= 300) {
      throw StateError('Qdrant info failed: ${resp.body}');
    }
    final json = jsonDecode(resp.body);
    return json['result'] as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getRecentPoints({int limit = 50}) async {
    final url = baseUrl.resolve('/collections/$collectionName/points/scroll');
    // Scroll doesn't support Sort strictly, but we can fetch a batch and sort client-side
    // because IDs are timestamps. Is this scalable? No. But good for "Tester".
    final body = jsonEncode({
      'limit': limit,
      'with_payload': true,
      'with_vector': false,
    });

    final resp = await _http.post(
      url,
      headers: {'content-type': 'application/json'},
      body: body,
    );

    if (resp.statusCode >= 300) {
        // If collection doesn't exist yet, return empty
        if (resp.statusCode == 404) return [];
        throw StateError('Qdrant scroll failed: ${resp.body}');
    }
    
    final json = jsonDecode(resp.body);
    final points = (json['result']['points'] as List).cast<Map<String, dynamic>>();
    
    // Sort by ID descending (Timestamp)
    points.sort((a, b) {
        final idA = a['id'] is int ? a['id'] as int : 0;
        final idB = b['id'] is int ? b['id'] as int : 0;
        return idB.compareTo(idA); 
    });
    
    return points;
  }
  
  Future<void> deleteCollection() async {
      final url = baseUrl.resolve('/collections/$collectionName');
      final resp = await _http.delete(url);
      if (resp.statusCode >= 300) {
          throw StateError('Failed to delete collection: ${resp.body}');
      }
  }

  Future<void> ensureCollectionExists() async {
      final url = baseUrl.resolve('/collections/$collectionName');
      final resp = await _http.get(url);
      if (resp.statusCode == 404) {
          await createCollection();
      }
  }
}

