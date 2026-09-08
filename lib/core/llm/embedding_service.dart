import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import 'embedding_request_gate.dart';

class EmbeddingConfig {
  final String endpoint;
  final String apiKey;
  final String model;
  final int maxChunkTokens;

  const EmbeddingConfig({
    required this.endpoint,
    this.apiKey = '',
    this.model = '',
    this.maxChunkTokens = 8192,
  });
}

/// Resolves a raw embedding endpoint into the concrete `/embeddings` URL.
///
/// Mirrors the chat transport's `normalizeEndpoint`: trims whitespace and
/// prepends `https://` when no scheme is present. Without the scheme a
/// separate embedding endpoint entered as `api.host/v1` becomes a malformed
/// scheme-less URL that iOS's HTTP stack rejects — which is why embeddings
/// failed on iPhone whenever the vector endpoint differed from the (already
/// schemed) chat endpoint, yet worked when both were shared.
String resolveEmbeddingEndpoint(String endpoint) {
  var normalized = endpoint.trim();
  if (normalized.isEmpty) return normalized;
  if (!normalized.startsWith(RegExp(r'https?://', caseSensitive: false))) {
    normalized = 'https://$normalized';
  }
  if (RegExp(r'/embeddings/?$', caseSensitive: false).hasMatch(normalized)) {
    return normalized;
  }
  return '${normalized.replaceFirst(RegExp(r'/+$'), '')}/embeddings';
}

String embeddingModelSignature(EmbeddingConfig config) {
  final endpoint = config.endpoint.trim();
  final model = config.model.trim();
  return '${endpoint.isEmpty ? '<endpoint>' : endpoint}|${model.isEmpty ? '<model>' : model}';
}

Map<String, dynamic> embeddingMetadataForConfig(
  EmbeddingConfig config,
  List<List<double>> vectors, {
  List<String>? hints,
  List<Map<String, dynamic>>? chunks,
  Map<String, dynamic> extra = const {},
}) {
  final metadata = <String, dynamic>{...extra};
  if (hints != null) metadata['hints'] = hints;
  if (chunks != null) metadata['chunks'] = chunks;
  metadata['embeddingModel'] = config.model.trim();
  metadata['embeddingEndpoint'] = config.endpoint.trim();
  metadata['embeddingSignature'] = embeddingModelSignature(config);
  metadata['embeddingDimension'] = vectors.isEmpty ? 0 : vectors.first.length;
  return metadata;
}

class RateLimitException implements Exception {
  final int retryAfter;
  RateLimitException(this.retryAfter);
  @override
  String toString() => 'Rate limited. Retry after ${retryAfter}s';
}

class EmbeddingChunk {
  final String text;
  final List<double> vector;

  const EmbeddingChunk({required this.text, required this.vector});
}

/// Caches embedding results for a short window so repeat calls during
/// a single generation (memory + lorebook + macro lookup often share
/// queries) hit the cache instead of the network. Entries expire after
/// [ttl] and the cache is bounded by [maxEntries] LRU.
class _EmbeddingCache {
  static const Duration ttl = Duration(seconds: 60);
  static const int maxEntries = 100;

  final LinkedHashMap<String, _Entry> _store = LinkedHashMap();

  String _key(String text, EmbeddingConfig config) =>
      '${config.endpoint}|${config.model}|${text.hashCode}|$text';

  List<double>? get(String text, EmbeddingConfig config) {
    final entry = _store[_key(text, config)];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.createdAt) > ttl) {
      _store.remove(_key(text, config));
      return null;
    }
    // Refresh recency: move-to-end on hit (LRU semantics).
    _store.remove(_key(text, config));
    _store[_key(text, config)] = entry;
    return entry.vector;
  }

  void put(String text, EmbeddingConfig config, List<double> vector) {
    final key = _key(text, config);
    _store.remove(key);
    _store[key] = _Entry(DateTime.now(), vector);
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}

class _Entry {
  final DateTime createdAt;
  final List<double> vector;
  _Entry(this.createdAt, this.vector);
}

class EmbeddingService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  final _EmbeddingCache _cache = _EmbeddingCache();

  Future<List<List<double>>> getEmbeddings(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    final allChunks = <List<String>>[];
    final chunkMap = <int, int>{};

    int chunkOffset = 0;
    for (int i = 0; i < texts.length; i++) {
      final chunks = _chunkText(texts[i], config.maxChunkTokens);
      allChunks.add(chunks);
      for (int j = 0; j < chunks.length; j++) {
        chunkMap[chunkOffset + j] = i;
      }
      chunkOffset += chunks.length;
    }

    final flatChunks = allChunks.expand((c) => c).toList();
    final allVectors = await _batchEmbed(
      flatChunks,
      config,
      cancelToken: cancelToken,
    );

    final result = <List<double>>[];
    int offset = 0;
    for (final chunks in allChunks) {
      if (chunks.length == 1) {
        result.add(allVectors[offset]);
      } else {
        result.add(
          _averageVectors(allVectors.sublist(offset, offset + chunks.length)),
        );
      }
      offset += chunks.length;
    }

    return result;
  }

  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    final allChunks = <String>[];
    final textChunkRanges = <_ChunkRange>[];

    for (final text in texts) {
      final chunks = _chunkText(text, config.maxChunkTokens);
      final start = allChunks.length;
      allChunks.addAll(chunks);
      textChunkRanges.add(_ChunkRange(start: start, end: allChunks.length));
    }

    final allVectors = await _batchEmbed(
      allChunks,
      config,
      cancelToken: cancelToken,
    );

    final result = <EmbeddingChunk>[];
    int offset = 0;
    for (int i = 0; i < texts.length; i++) {
      final range = textChunkRanges[i];
      final chunks = allChunks.sublist(range.start, range.end);
      final vectors = allVectors.sublist(
        range.start - offset + offset,
        range.end - offset + offset,
      );

      for (int j = 0; j < chunks.length; j++) {
        result.add(EmbeddingChunk(text: chunks[j], vector: vectors[j]));
      }
      offset = range.end;
    }

    return result;
  }

  Future<List<List<double>>> _batchEmbed(
    List<String> chunks,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    const batchSize = 32;
    final allVectors = <List<double>>[];

    for (int i = 0; i < chunks.length; i += batchSize) {
      final batch = chunks.sublist(i, (i + batchSize).clamp(0, chunks.length));

      // Split the batch into cache hits and misses so we only spend HTTP
      // budget on the misses, and slot the returned vectors back in the
      // same positions for the caller.
      final cached = <int, List<double>>{};
      final missingIndices = <int>[];
      for (int j = 0; j < batch.length; j++) {
        final hit = _cache.get(batch[j], config);
        if (hit != null) {
          cached[j] = hit;
        } else {
          missingIndices.add(j);
        }
      }

      if (missingIndices.isEmpty) {
        for (int j = 0; j < batch.length; j++) {
          allVectors.add(cached[j]!);
        }
        continue;
      }

      final missingTexts = [for (final idx in missingIndices) batch[idx]];
      final vectors = await _callEmbeddingApi(
        missingTexts,
        config,
        cancelToken: cancelToken,
      );
      final batchVectors = List<List<double>?>.filled(batch.length, null);
      for (final entry in cached.entries) {
        batchVectors[entry.key] = entry.value;
      }
      for (int k = 0; k < missingIndices.length; k++) {
        final originalIdx = missingIndices[k];
        final vector = vectors[k];
        _cache.put(batch[originalIdx], config, vector);
        batchVectors[originalIdx] = vector;
      }
      for (final vector in batchVectors) {
        if (vector != null) allVectors.add(vector);
      }

      if (i + batchSize < chunks.length) {
        if (cancelToken?.isCancelled == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    return allVectors;
  }

  Future<List<List<double>>> _callEmbeddingApi(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (texts.isEmpty) return [];

    final url = resolveEmbeddingEndpoint(config.endpoint);

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }

    final requestToken = EmbeddingRequestGate.beginRequest(cancelToken);
    try {
      if (requestToken.isCancelled) {
        throw requestToken.cancelError!;
      }
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: {'model': config.model, 'input': texts},
        options: Options(headers: headers),
        cancelToken: requestToken,
      );

      final data = response.data;
      if (data == null) throw 'Empty response';

      if (data['error'] != null) {
        final msg = data['error']['message'] ?? data['error'].toString();
        throw 'API error: $msg';
      }

      final dataList = data['data'] as List<dynamic>?;
      if (dataList == null) {
        throw 'Invalid embedding response: missing data array';
      }

      dataList.sort(
        (a, b) => ((a as Map)['index'] as int? ?? 0).compareTo(
          (b as Map)['index'] as int? ?? 0,
        ),
      );

      return dataList.map((item) {
        final embedding = (item as Map)['embedding'] as List<dynamic>;
        return embedding.map((v) => (v as num).toDouble()).toList();
      }).toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) {
        final retryAfter =
            int.tryParse(e.response?.headers.value('retry-after') ?? '') ?? 60;
        throw RateLimitException(retryAfter);
      }
      throw 'Network error: ${e.message}';
    } finally {
      EmbeddingRequestGate.endRequest(requestToken);
    }
  }

  List<String> _chunkText(String text, int maxTokens) {
    if (maxTokens <= 0 || text.isEmpty) return [text];

    final estChars = maxTokens * 4;
    if (text.length <= estChars) return [text];

    final chunks = <String>[];
    var remaining = text;

    while (remaining.isNotEmpty) {
      if (remaining.length <= estChars) {
        chunks.add(remaining);
        break;
      }

      int cutPos = remaining.lastIndexOf('\n', estChars);
      if (cutPos <= 0) {
        cutPos = remaining.lastIndexOf('. ', estChars);
      }
      if (cutPos <= 0) {
        cutPos = remaining.lastIndexOf(' ', estChars);
      }
      if (cutPos <= 0) {
        cutPos = estChars;
      }

      chunks.add(remaining.substring(0, cutPos + 1).trim());
      remaining = remaining.substring(cutPos + 1);
    }

    return chunks.where((c) => c.isNotEmpty).toList();
  }

  List<double> _averageVectors(List<List<double>> vectors) {
    if (vectors.isEmpty) return [];
    if (vectors.length == 1) return vectors.first;

    final dim = vectors.first.length;
    final result = List<double>.filled(dim, 0);

    for (final v in vectors) {
      for (int i = 0; i < dim && i < v.length; i++) {
        result[i] += v[i];
      }
    }

    for (int i = 0; i < dim; i++) {
      result[i] /= vectors.length;
    }

    return result;
  }
}

class _ChunkRange {
  final int start;
  final int end;
  const _ChunkRange({required this.start, required this.end});
}
