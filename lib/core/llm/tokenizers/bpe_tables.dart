import 'dart:typed_data';

/// 64-bit FNV-1a over UTF-16 code units.
///
/// Token strings are never kept in memory: a vocabulary of 250k strings costs
/// tens of megabytes as Dart objects, while their hashes fit in one typed list.
/// A collision between two distinct tokens is ~1e-9 for the largest vocabulary
/// Glaze loads, and would at worst miscount a single token.
int fnv64(String s) {
  var h = _fnvOffset;
  for (var i = 0; i < s.length; i++) {
    h = (h ^ s.codeUnitAt(i)) * _fnvPrime;
  }
  return h == 0 ? 1 : h;
}

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;

/// Incremental form of [fnv64] for callers that build the hashed text one code
/// unit at a time (the byte-level alphabet) without allocating the string.
int fnv64Start() => _fnvOffset;
int fnv64Add(int h, int codeUnit) => (h ^ codeUnit) * _fnvPrime;
int fnv64Finish(int h) => h == 0 ? 1 : h;

/// Load factor 0.7: most BPE lookups are misses (the pair never merges), and
/// linear probing's miss cost climbs steeply past that.
int _capacityFor(int count) => count * 10 ~/ 7 + 7;

int _slot(int key, int capacity) {
  var x = key;
  x = (x ^ (x >>> 33)) * 0xff51afd7ed558ccd;
  x = x ^ (x >>> 33);
  return (x & 0x7fffffffffffffff) % capacity;
}

/// Token text hash → token id, open addressing over typed lists.
class VocabTable {
  VocabTable._(this.keys, this.ids);

  factory VocabTable.build(Map<String, int> vocab) {
    final cap = _capacityFor(vocab.length);
    final table = VocabTable._(Int64List(cap), Int32List(cap));
    vocab.forEach((token, id) => table._put(fnv64(token), id));
    return table;
  }

  factory VocabTable.fromLists(Int64List keys, Int32List ids) =>
      VocabTable._(keys, ids);

  final Int64List keys;
  final Int32List ids;

  void _put(int hash, int id) {
    final cap = keys.length;
    var i = _slot(hash, cap);
    while (keys[i] != 0 && keys[i] != hash) {
      i = i + 1 == cap ? 0 : i + 1;
    }
    keys[i] = hash;
    ids[i] = id;
  }

  /// The id of the token whose text hashes to [hash], or -1.
  int lookup(int hash) {
    final cap = keys.length;
    var i = _slot(hash, cap);
    while (true) {
      final k = keys[i];
      if (k == hash) return ids[i];
      if (k == 0) return -1;
      i = i + 1 == cap ? 0 : i + 1;
    }
  }

  int lookupText(String token) => lookup(fnv64(token));
}

/// Merge rules: (left id, right id) → (rank, merged id).
class MergeTable {
  MergeTable._(this.keys, this.ranks, this.merged);

  factory MergeTable.empty(int count) {
    final cap = _capacityFor(count);
    return MergeTable._(Int64List(cap), Int32List(cap), Int32List(cap));
  }

  factory MergeTable.fromLists(
    Int64List keys,
    Int32List ranks,
    Int32List merged,
  ) => MergeTable._(keys, ranks, merged);

  final Int64List keys;
  final Int32List ranks;
  final Int32List merged;

  /// Ids fit in 24 bits (the largest vocabulary is 262k); +1 keeps key 0 free
  /// as the empty-slot marker.
  static int _key(int left, int right) => ((left << 24) | right) + 1;

  /// Registers a merge. The first registration of a pair wins, matching the
  /// HuggingFace loader, which keeps the earliest rank for duplicate merges.
  void add(int left, int right, int rank, int mergedId) {
    final key = _key(left, right);
    final cap = keys.length;
    var i = _slot(key, cap);
    while (keys[i] != 0) {
      if (keys[i] == key) return;
      i = i + 1 == cap ? 0 : i + 1;
    }
    keys[i] = key;
    ranks[i] = rank;
    merged[i] = mergedId;
  }

  /// Slot of the merge for (left, right), or -1 when the pair never merges.
  int find(int left, int right) {
    final key = _key(left, right);
    final cap = keys.length;
    var i = _slot(key, cap);
    while (true) {
      final k = keys[i];
      if (k == key) return i;
      if (k == 0) return -1;
      i = i + 1 == cap ? 0 : i + 1;
    }
  }
}
