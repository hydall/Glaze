import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../db/app_db.dart';
import '../models/memory_book.dart';
import 'tokenizer.dart';

class MemoryCatalogBuilder {
  const MemoryCatalogBuilder._();

  static List<MemoryCatalogRowsCompanion> build(
    MemoryBook book, {
    required int nowSeconds,
  }) {
    return book.entries
        .map((entry) => buildRow(book.sessionId, entry, nowSeconds: nowSeconds))
        .toList(growable: false);
  }

  static MemoryCatalogRowsCompanion buildRow(
    String sessionId,
    MemoryEntry entry, {
    required int nowSeconds,
  }) {
    final sourceHash = entry.sourceHash.isNotEmpty
        ? entry.sourceHash
        : _hash({'content': entry.content});
    final revision = _hash({
      'content': entry.content,
      'keys': entry.keys,
      'status': entry.status,
      'sourceHash': sourceHash,
      'messageRange': entry.messageRange?.toJson(),
      'importance': entry.importance,
      'temporallyBlind': entry.temporallyBlind,
      'arc': entry.arc,
      'kind': entry.kind,
    });

    return MemoryCatalogRowsCompanion.insert(
      id: '$sessionId::${entry.id}',
      chatSessionId: sessionId,
      memoryEntryId: entry.id,
      entryRevision: Value(revision),
      sourceHash: Value(sourceHash),
      title: Value(entry.title),
      keysJson: Value(jsonEncode(entry.keys)),
      entitiesJson: const Value('[]'),
      locationsJson: entry.arc.isEmpty
          ? const Value('[]')
          : Value(jsonEncode([entry.arc])),
      topicsJson: entry.kind.isEmpty
          ? const Value('[]')
          : Value(jsonEncode([entry.kind])),
      messageRangeStart: Value(entry.messageRange?.start),
      messageRangeEnd: Value(entry.messageRange?.end),
      importance: Value(entry.importance),
      temporallyBlind: Value(entry.temporallyBlind),
      tokenCount: Value(estimateTokens(entry.content)),
      abstractText: Value(_abstract(entry.content)),
      status: Value(entry.status),
      stale: const Value(false),
      createdAt: Value(nowSeconds),
      updatedAt: Value(nowSeconds),
    );
  }

  static String _abstract(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 320) return normalized;
    return '${normalized.substring(0, 317).trimRight()}...';
  }

  static String _hash(Map<String, dynamic> json) {
    return sha256.convert(utf8.encode(jsonEncode(json))).toString();
  }
}

extension MemoryCatalogRowJson on MemoryCatalogRow {
  List<String> get keys => _decodeStringList(keysJson);
  List<String> get entities => _decodeStringList(entitiesJson);
  List<String> get locations => _decodeStringList(locationsJson);
  List<String> get topics => _decodeStringList(topicsJson);

  static List<String> _decodeStringList(String raw) {
    try {
      return (jsonDecode(raw) as List).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }
}
