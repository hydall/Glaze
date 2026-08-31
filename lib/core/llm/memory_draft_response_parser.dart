import 'dart:convert';

import '../models/memory_book.dart';
import 'memory/memory_chunker.dart';

class MemoryDraftResponseParser {
  const MemoryDraftResponseParser._();

  static MemoryDraft parse(MemoryDraft draft, String raw, {int? nowMillis}) {
    final parsed = _parseStructured(raw) ?? _parseLegacy(raw);
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return draft.copyWith(
      content: parsed.content,
      keys: parsed.keys,
      keyParagraphs: parsed.keyParagraphs,
      status: 'pending_approval',
      generatedAt: now,
      updatedAt: now,
      error: null,
    );
  }

  static _ParsedDraft? _parseStructured(String raw) {
    var text = raw.trim();
    final fence = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['paragraphs'] is! List) return null;
      final paragraphs = <String>[];
      final keys = <String>[];
      final scopes = <String, List<int>>{};
      for (final item in decoded['paragraphs'] as List) {
        if (item is! Map) continue;
        final itemParagraphs = MemoryChunker.paragraphs(
          item['text']?.toString() ?? '',
        );
        if (itemParagraphs.isEmpty) continue;
        final paragraphIndexes = List<int>.generate(
          itemParagraphs.length,
          (index) => paragraphs.length + index,
          growable: false,
        );
        paragraphs.addAll(itemParagraphs);
        final rawKeys = item['keys'];
        if (rawKeys is! List) continue;
        for (final value in rawKeys) {
          if (value is! String) continue;
          final key = value.trim();
          if (key.isEmpty) continue;
          final canonical = _existingKey(keys, key) ?? key;
          if (!keys.contains(canonical)) keys.add(canonical);
          scopes.putIfAbsent(canonical, () => <int>[]).addAll(paragraphIndexes);
        }
      }
      if (paragraphs.isEmpty) return null;
      return _ParsedDraft(paragraphs.join('\n\n'), keys, scopes);
    } catch (_) {
      return null;
    }
  }

  static _ParsedDraft _parseLegacy(String raw) {
    var content = raw.trim();
    var keys = <String>[];
    final memoryMatch = RegExp(
      r'^Memory:\s*(.*?)(?=^Keys:|\z)',
      dotAll: true,
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw);
    final keysMatch = RegExp(
      r'^Keys:\s*(.*?)$',
      dotAll: true,
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(raw);
    if (memoryMatch != null) content = memoryMatch.group(1)!.trim();
    if (keysMatch != null) {
      keys = _dedupe(keysMatch.group(1)!.split(',').map((key) => key.trim()));
    }
    return _ParsedDraft(content, keys, const {});
  }

  static String? _existingKey(List<String> keys, String candidate) {
    final lower = candidate.toLowerCase();
    return keys.where((key) => key.toLowerCase() == lower).firstOrNull;
  }

  static List<String> _dedupe(Iterable<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.isNotEmpty && seen.add(value.toLowerCase())) value,
    ];
  }
}

class _ParsedDraft {
  final String content;
  final List<String> keys;
  final Map<String, List<int>> keyParagraphs;

  const _ParsedDraft(this.content, this.keys, this.keyParagraphs);
}
