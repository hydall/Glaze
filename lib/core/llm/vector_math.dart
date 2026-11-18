import 'dart:math';
import 'dart:typed_data';

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;

  double dotProduct = 0;
  double normA = 0;
  double normB = 0;

  for (int i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  final denominator = sqrt(normA) * sqrt(normB);
  if (denominator == 0) return 0;

  return dotProduct / denominator;
}

class VectorCandidate {
  final String id;
  final List<double>? vector;
  final List<VectorChunk>? vectors;
  final Map<String, dynamic> metadata;

  const VectorCandidate({
    required this.id,
    this.vector,
    this.vectors,
    this.metadata = const {},
  });
}

class VectorChunk {
  final String text;
  final List<double> vector;

  const VectorChunk({required this.text, required this.vector});
}

class TopKResult {
  final String id;
  final double score;
  final int? bestQueryChunk;
  final int? bestCandidateChunk;
  final Map<String, dynamic> metadata;

  const TopKResult({
    required this.id,
    required this.score,
    this.bestQueryChunk,
    this.bestCandidateChunk,
    this.metadata = const {},
  });
}

List<TopKResult> findTopKMulti(
  List<VectorChunk> queryChunks,
  List<VectorCandidate> candidates,
  int k, [
  double threshold = 0,
]) {
  final results = <TopKResult>[];

  for (final c in candidates) {
    double maxScore = -1;
    int? bestQC;
    int? bestCC;

    if (c.vectors != null) {
      for (int qi = 0; qi < queryChunks.length; qi++) {
        final qVec = queryChunks[qi].vector;
        for (int ci = 0; ci < c.vectors!.length; ci++) {
          final cVec = c.vectors![ci].vector;
          final score = cosineSimilarity(qVec, cVec);
          if (score > maxScore) {
            maxScore = score;
            bestQC = qi;
            bestCC = ci;
          }
        }
      }
    } else if (c.vector != null) {
      for (int qi = 0; qi < queryChunks.length; qi++) {
        final score = cosineSimilarity(queryChunks[qi].vector, c.vector!);
        if (score > maxScore) {
          maxScore = score;
          bestQC = qi;
          bestCC = null;
        }
      }
    }

    if (maxScore >= 0) {
      results.add(TopKResult(
        id: c.id,
        score: maxScore,
        bestQueryChunk: bestQC,
        bestCandidateChunk: bestCC,
        metadata: c.metadata,
      ));
    }
  }

  results.sort((a, b) => b.score.compareTo(a.score));

  return results
      .where((r) => threshold <= 0 || r.score >= threshold)
      .take(k)
      .toList();
}

List<TopKResult> findTopK(
  List<double> queryVector,
  List<VectorCandidate> candidates,
  int k, [
  double threshold = 0,
]) {
  return findTopKMulti(
    [VectorChunk(text: '', vector: queryVector)],
    candidates,
    k,
    threshold,
  );
}

List<double> bytesToVector(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final len = bytes.length ~/ 8;
  final vector = List<double>.filled(len, 0);
  for (int i = 0; i < len; i++) {
    vector[i] = data.getFloat64(i * 8, Endian.host);
  }
  return vector;
}

Uint8List vectorToBytes(List<double> vector) {
  final bytes = Uint8List(vector.length * 8);
  final data = ByteData.sublistView(bytes);
  for (int i = 0; i < vector.length; i++) {
    data.setFloat64(i * 8, vector[i], Endian.host);
  }
  return bytes;
}

List<List<double>> bytesToVectorList(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var pos = 0;

  try {
    final count = data.getUint32(pos, Endian.host);
    pos += 4;

    final result = <List<double>>[];
    for (int c = 0; c < count; c++) {
      final dim = data.getUint32(pos, Endian.host);
      pos += 4;
      final vec = List<double>.filled(dim, 0);
      for (int i = 0; i < dim; i++) {
        vec[i] = data.getFloat64(pos, Endian.host);
        pos += 8;
      }
      result.add(vec);
    }
    return result;
  } on RangeError catch (_) {
    return [];
  }
}

Uint8List vectorListToBytes(List<List<double>> vectors) {
  int totalSize = 4;
  for (final v in vectors) {
    totalSize += 4 + v.length * 8;
  }

  final bytes = Uint8List(totalSize);
  final data = ByteData.sublistView(bytes);
  var pos = 0;

  data.setUint32(pos, vectors.length, Endian.host);
  pos += 4;

  for (final v in vectors) {
    data.setUint32(pos, v.length, Endian.host);
    pos += 4;
    for (int i = 0; i < v.length; i++) {
      data.setFloat64(pos, v[i], Endian.host);
      pos += 8;
    }
  }

  return bytes;
}
