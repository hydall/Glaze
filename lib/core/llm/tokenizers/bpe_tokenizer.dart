import 'dart:convert';
import 'dart:typed_data';

import 'bpe_tables.dart';
import 'pre_tokenizer.dart';
import 'text_normalizer.dart';

/// A HuggingFace-compatible BPE model that only counts tokens.
///
/// Covers the two BPE flavours real tokenizers ship: byte-level (GPT-4o,
/// Llama 3, Qwen, DeepSeek, Mistral Tekken, Claude, Command-R) and
/// SentencePiece-style character BPE with byte fallback (Gemma / Gemini). Ids
/// are real vocabulary ids, so results match the reference implementation
/// piece for piece; token text itself is never materialized.
class BpeTokenizer {
  BpeTokenizer({
    required this.spec,
    required this.vocab,
    required this.merges,
    required this.byteIds,
    required this.byteFallbackIds,
  }) : byteLevel = spec.byteLevel,
       ignoreMerges = spec.ignoreMerges,
       fuseUnk = spec.fuseUnk,
       unkId = spec.unkId,
       _normalizer = TextNormalizer.fromSpec(spec.normalizer),
       _preTokenizer = PreTokenizer.fromSpec(spec.preTokenizer);

  final BpeSpec spec;
  final VocabTable vocab;
  final MergeTable merges;

  /// Byte-level: vocabulary id of each byte's printable stand-in.
  final Int32List byteIds;

  /// Byte fallback: vocabulary id of each `<0xXX>` token, or -1.
  final Int32List byteFallbackIds;

  final bool byteLevel;
  final bool ignoreMerges;
  final bool fuseUnk;
  final int unkId;
  final TextNormalizer? _normalizer;
  final PreTokenizer? _preTokenizer;

  int count(String text) {
    if (text.isEmpty) return 0;
    final normalized = _normalizer?.apply(text) ?? text;
    final pieces = _preTokenizer?.split([normalized]) ?? [normalized];
    var total = 0;
    for (final piece in pieces) {
      if (piece.isEmpty) continue;
      total += byteLevel ? _countByteLevel(piece) : _countChars(piece);
    }
    return total;
  }

  int _countByteLevel(String piece) {
    final bytes = utf8.encode(piece);
    if (bytes.length == 1) return 1;
    if (ignoreMerges) {
      var h = fnv64Start();
      for (final b in bytes) {
        h = fnv64Add(h, byteLevelChar(b));
      }
      if (vocab.lookup(fnv64Finish(h)) >= 0) return 1;
    }
    final ids = List<int>.generate(bytes.length, (i) => byteIds[bytes[i]]);
    return _merge(ids);
  }

  int _countChars(String piece) {
    if (ignoreMerges && vocab.lookupText(piece) >= 0) return 1;
    final ids = <int>[];
    var lastWasUnk = false;
    for (final rune in piece.runes) {
      final char = String.fromCharCode(rune);
      final id = vocab.lookupText(char);
      if (id >= 0) {
        ids.add(id);
        lastWasUnk = false;
        continue;
      }
      if (byteFallbackIds[0] >= 0) {
        for (final b in utf8.encode(char)) {
          ids.add(byteFallbackIds[b]);
        }
        lastWasUnk = false;
        continue;
      }
      if (fuseUnk && lastWasUnk) continue;
      ids.add(unkId);
      lastWasUnk = true;
    }
    return _merge(ids);
  }

  int _merge(List<int> ids) {
    if (ids.length < 2) return ids.length;
    return ids.length <= _naiveLimit ? _mergeNaive(ids) : _mergeHeap(ids);
  }

  static const _naiveLimit = 48;

  int _mergeNaive(List<int> ids) {
    final ranks = merges.ranks;
    final merged = merges.merged;
    while (ids.length > 1) {
      var bestSlot = -1;
      var bestRank = 0x7fffffff;
      var bestPos = -1;
      for (var i = 0; i < ids.length - 1; i++) {
        final left = ids[i];
        final right = ids[i + 1];
        if (left < 0 || right < 0) continue;
        final slot = merges.find(left, right);
        if (slot >= 0 && ranks[slot] < bestRank) {
          bestRank = ranks[slot];
          bestSlot = slot;
          bestPos = i;
        }
      }
      if (bestSlot < 0) break;
      ids[bestPos] = merged[bestSlot];
      ids.removeAt(bestPos + 1);
    }
    return ids.length;
  }

  /// Same merge order as the naive loop (lowest rank, then leftmost), in
  /// O(n log n) — SentencePiece-style models have no pre-tokenizer, so a
  /// whole message arrives as one piece.
  int _mergeHeap(List<int> ids) {
    final n = ids.length;
    if (n >= _posLimit) return n;
    final next = Int32List(n);
    final prev = Int32List(n);
    final removed = Uint8List(n);
    for (var i = 0; i < n; i++) {
      next[i] = i + 1 < n ? i + 1 : -1;
      prev[i] = i - 1;
    }
    final heap = _IntHeap();
    final ranks = merges.ranks;
    final merged = merges.merged;

    void push(int pos) {
      final right = next[pos];
      if (right < 0) return;
      final left = ids[pos];
      final r = ids[right];
      if (left < 0 || r < 0) return;
      final slot = merges.find(left, r);
      if (slot >= 0) heap.push(ranks[slot] * _posLimit + pos);
    }

    for (var i = 0; i < n - 1; i++) {
      push(i);
    }
    var count = n;
    while (heap.isNotEmpty) {
      final entry = heap.pop();
      final rank = entry ~/ _posLimit;
      final pos = entry % _posLimit;
      if (removed[pos] != 0) continue;
      final right = next[pos];
      if (right < 0) continue;
      final left = ids[pos];
      final r = ids[right];
      if (left < 0 || r < 0) continue;
      final slot = merges.find(left, r);
      if (slot < 0 || ranks[slot] != rank) continue;

      ids[pos] = merged[slot];
      removed[right] = 1;
      final after = next[right];
      next[pos] = after;
      if (after >= 0) prev[after] = pos;
      count--;
      if (prev[pos] >= 0) push(prev[pos]);
      push(pos);
    }
    return count;
  }

  static const _posLimit = 1 << 22;
}

/// Everything about a tokenizer except its two tables — small enough to live
/// as JSON in the cache header.
class BpeSpec {
  const BpeSpec({
    required this.byteLevel,
    required this.ignoreMerges,
    required this.fuseUnk,
    required this.unkId,
    this.normalizer,
    this.preTokenizer,
  });

  final bool byteLevel;
  final bool ignoreMerges;
  final bool fuseUnk;
  final int unkId;

  /// Raw `tokenizer.json` specs, interpreted by [TextNormalizer.fromSpec] and
  /// [PreTokenizer.fromSpec].
  final Object? normalizer;
  final Object? preTokenizer;

  Map<String, Object?> toJson() => {
    'byteLevel': byteLevel,
    'ignoreMerges': ignoreMerges,
    'fuseUnk': fuseUnk,
    'unkId': unkId,
    'normalizer': normalizer,
    'preTokenizer': preTokenizer,
  };

  factory BpeSpec.fromJson(Map<String, dynamic> json) => BpeSpec(
    byteLevel: json['byteLevel'] as bool? ?? false,
    ignoreMerges: json['ignoreMerges'] as bool? ?? false,
    fuseUnk: json['fuseUnk'] as bool? ?? false,
    unkId: json['unkId'] as int? ?? -1,
    normalizer: json['normalizer'],
    preTokenizer: json['preTokenizer'],
  );
}

/// GPT-2's byte → printable character table: printable Latin-1 bytes map to
/// themselves, the rest to U+0100 onward in byte order.
int byteLevelChar(int byte) => _byteLevelTable[byte];

final Int32List _byteLevelTable = () {
  final table = Int32List(256);
  bool printable(int b) =>
      (b >= 0x21 && b <= 0x7E) || (b >= 0xA1 && b <= 0xAC) || b >= 0xAE;
  var extra = 0;
  for (var b = 0; b < 256; b++) {
    table[b] = printable(b) ? b : 256 + extra++;
  }
  return table;
}();

class _IntHeap {
  final List<int> _items = [];

  bool get isNotEmpty => _items.isNotEmpty;

  void push(int value) {
    _items.add(value);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_items[parent] <= value) break;
      _items[i] = _items[parent];
      i = parent;
    }
    _items[i] = value;
  }

  int pop() {
    final top = _items.first;
    final last = _items.removeLast();
    if (_items.isEmpty) return top;
    var i = 0;
    final n = _items.length;
    while (true) {
      final l = 2 * i + 1;
      if (l >= n) break;
      final r = l + 1;
      final c = r < n && _items[r] < _items[l] ? r : l;
      if (_items[c] >= last) break;
      _items[i] = _items[c];
      i = c;
    }
    _items[i] = last;
    return top;
  }
}
