import 'dart:convert';
import 'dart:typed_data';

import 'bpe_tables.dart';
import 'bpe_tokenizer.dart';

/// Builds a [BpeTokenizer] from a HuggingFace `tokenizer.json`.
///
/// Parsing the JSON is the expensive part (10–30 MB of text): run it once,
/// off the UI isolate, then persist the result with [encodeTokenizerCache].
BpeTokenizer tokenizerFromHfJson(Map<String, dynamic> json) {
  final model = json['model'];
  if (model is! Map || model['type'] != 'BPE') {
    throw const FormatException('Only BPE tokenizer.json models are supported');
  }
  final rawVocab = model['vocab'] as Map;
  final vocab = <String, int>{
    for (final e in rawVocab.entries) e.key as String: (e.value as num).toInt(),
  };
  final rawMerges = model['merges'] as List? ?? const [];

  final mergeTable = MergeTable.empty(rawMerges.length);
  for (var rank = 0; rank < rawMerges.length; rank++) {
    final entry = rawMerges[rank];
    final String left;
    final String right;
    if (entry is String) {
      final space = entry.indexOf(' ');
      if (space <= 0) continue;
      left = entry.substring(0, space);
      right = entry.substring(space + 1);
    } else if (entry is List && entry.length == 2) {
      left = entry[0] as String;
      right = entry[1] as String;
    } else {
      continue;
    }
    final l = vocab[left];
    final r = vocab[right];
    final m = vocab['$left$right'];
    if (l == null || r == null || m == null) continue;
    mergeTable.add(l, r, rank, m);
  }

  final byteLevel = usesByteLevelJson(json);
  final byteIds = Int32List(256);
  for (var b = 0; b < 256; b++) {
    byteIds[b] = vocab[String.fromCharCode(byteLevelChar(b))] ?? -1;
  }
  final byteFallbackIds = Int32List(256)..fillRange(0, 256, -1);
  if (model['byte_fallback'] == true) {
    for (var b = 0; b < 256; b++) {
      final hex = b.toRadixString(16).toUpperCase().padLeft(2, '0');
      byteFallbackIds[b] = vocab['<0x$hex>'] ?? -1;
    }
  }
  final unk = model['unk_token'];
  final ignoreMerges = model['ignore_merges'] == true;

  return BpeTokenizer(
    spec: BpeSpec(
      byteLevel: byteLevel,
      ignoreMerges: ignoreMerges,
      fuseUnk: model['fuse_unk'] == true,
      unkId: unk is String ? (vocab[unk] ?? -1) : -1,
      normalizer: json['normalizer'],
      preTokenizer: json['pre_tokenizer'],
    ),
    vocab: VocabTable.build(_lookupVocab(vocab, byteLevel, ignoreMerges)),
    merges: mergeTable,
    byteIds: byteIds,
    byteFallbackIds: byteFallbackIds,
  );
}

/// The part of the vocabulary counting ever looks up by text. Byte-level
/// models start from [BpeTokenizer.byteIds] and only need whole pieces for
/// `ignore_merges`; character-level models need single characters. Dropping
/// the rest keeps the table a fraction of the full vocabulary.
Map<String, int> _lookupVocab(
  Map<String, int> vocab,
  bool byteLevel,
  bool ignoreMerges,
) {
  if (ignoreMerges) return vocab;
  if (byteLevel) return const {};
  return {
    for (final e in vocab.entries)
      if (e.key.runes.length == 1) e.key: e.value,
  };
}

/// True when the tokenizer maps bytes to the GPT-2 printable alphabet before
/// BPE — declared by a ByteLevel pre-tokenizer or decoder.
bool usesByteLevelJson(Map<String, dynamic> json) {
  bool has(Object? spec) {
    if (spec is! Map) return false;
    if (spec['type'] == 'ByteLevel') return true;
    for (final key in const ['pretokenizers', 'decoders']) {
      final children = spec[key];
      if (children is List && children.any(has)) return true;
    }
    return false;
  }

  return has(json['pre_tokenizer']) || has(json['decoder']);
}

/// Bump when the cache layout or the meaning of any stored field changes;
/// older caches are then rebuilt from the downloaded source.
const int tokenizerCacheVersion = 1;

const _magic = 'GLZTOK';

/// Compact binary form of a [BpeTokenizer]: a JSON header followed by the raw
/// typed lists, 8-byte aligned so loading is a handful of buffer views.
Uint8List encodeTokenizerCache(BpeTokenizer tokenizer) {
  final meta = utf8.encode(
    jsonEncode({
      'spec': tokenizer.spec.toJson(),
      'byteIds': tokenizer.byteIds,
      'byteFallbackIds': tokenizer.byteFallbackIds,
    }),
  );
  final builder = BytesBuilder(copy: false);
  final header = ByteData(16)
    ..setUint32(8, tokenizerCacheVersion, Endian.little)
    ..setUint32(12, meta.length, Endian.little);
  final headerBytes = header.buffer.asUint8List();
  headerBytes.setRange(0, _magic.length, _magic.codeUnits);
  builder.add(headerBytes);
  builder.add(meta);
  _pad(builder);

  final sizes = ByteData(8)
    ..setUint32(0, tokenizer.vocab.keys.length, Endian.little)
    ..setUint32(4, tokenizer.merges.keys.length, Endian.little);
  builder.add(sizes.buffer.asUint8List());
  for (final list in <TypedData>[
    tokenizer.vocab.keys,
    tokenizer.vocab.ids,
    tokenizer.merges.keys,
    tokenizer.merges.ranks,
    tokenizer.merges.merged,
  ]) {
    builder.add(
      list.buffer.asUint8List(list.offsetInBytes, list.lengthInBytes),
    );
    _pad(builder);
  }
  return builder.takeBytes();
}

void _pad(BytesBuilder builder) {
  final rem = builder.length % 8;
  if (rem != 0) builder.add(Uint8List(8 - rem));
}

/// Whether [header] (the first 16 bytes of a cache file) comes from this
/// cache version.
bool isCurrentTokenizerCache(Uint8List header) {
  if (header.length < 16) return false;
  if (String.fromCharCodes(header.sublist(0, _magic.length)) != _magic) {
    return false;
  }
  return ByteData.sublistView(header).getUint32(8, Endian.little) ==
      tokenizerCacheVersion;
}

/// Inverse of [encodeTokenizerCache]. Returns null for a file from another
/// cache version or a truncated one, so the caller rebuilds it.
BpeTokenizer? decodeTokenizerCache(Uint8List bytes) {
  // Views below need 8-byte aligned offsets into their own buffer.
  final data = bytes.offsetInBytes % 8 == 0 ? bytes : Uint8List.fromList(bytes);
  if (data.length < 24) return null;
  if (String.fromCharCodes(data.sublist(0, _magic.length)) != _magic) {
    return null;
  }
  final view = ByteData.sublistView(data);
  if (view.getUint32(8, Endian.little) != tokenizerCacheVersion) return null;
  final metaLen = view.getUint32(12, Endian.little);
  var offset = 16;
  final meta =
      jsonDecode(utf8.decode(data.sublist(offset, offset + metaLen)))
          as Map<String, dynamic>;
  offset = _align(offset + metaLen);
  final vocabCap = view.getUint32(offset, Endian.little);
  final mergeCap = view.getUint32(offset + 4, Endian.little);
  offset += 8;
  final expected =
      offset +
      _align(vocabCap * 8) +
      _align(vocabCap * 4) +
      _align(mergeCap * 8) +
      _align(mergeCap * 4) * 2;
  if (data.length < expected) return null;

  final buffer = data.buffer;
  final base = data.offsetInBytes;
  Int64List i64(int count) {
    final list = buffer.asInt64List(base + offset, count);
    offset += _align(count * 8);
    return list;
  }

  Int32List i32(int count) {
    final list = buffer.asInt32List(base + offset, count);
    offset += _align(count * 4);
    return list;
  }

  final vocab = VocabTable.fromLists(i64(vocabCap), i32(vocabCap));
  final merges = MergeTable.fromLists(
    i64(mergeCap),
    i32(mergeCap),
    i32(mergeCap),
  );
  return BpeTokenizer(
    spec: BpeSpec.fromJson(meta['spec'] as Map<String, dynamic>),
    vocab: vocab,
    merges: merges,
    byteIds: Int32List.fromList((meta['byteIds'] as List).cast<int>()),
    byteFallbackIds: Int32List.fromList(
      (meta['byteFallbackIds'] as List).cast<int>(),
    ),
  );
}

int _align(int n) => (n + 7) & ~7;
