import 'dart:convert';

import '../models/character_knowledge_fact.dart';
import '../models/knowledge_cleanup.dart';
import 'json_repair.dart';

class KnowledgeCleanupParser {
  const KnowledgeCleanupParser();

  bool hasValidBlock(String output) => _decodeOps(output) != null;

  List<KnowledgeCleanupOp> parse({
    required String output,
    required List<CharacterKnowledgeFact> offeredFacts,
    required String reviewText,
  }) {
    final decodedOps = _decodeOps(output);
    if (decodedOps == null) return const [];

    final factIds = offeredFacts.map((fact) => fact.id).toSet();
    final entityKeys = <String>{
      for (final fact in offeredFacts) fact.knowerKey,
      for (final fact in offeredFacts) fact.subjectKey,
    };
    final normalizedReview = reviewText.toLowerCase();
    final result = <KnowledgeCleanupOp>[];
    for (final rawOp in decodedOps.take(50)) {
      if (rawOp is! Map) continue;
      final op = rawOp['op']?.toString();
      if (op == 'retract') {
        final id = rawOp['factId']?.toString() ?? '';
        if (factIds.contains(id)) result.add(KnowledgeCleanupOp.retract(id));
        continue;
      }
      if (op != 'rename_entity') continue;
      final from = rawOp['fromKey']?.toString() ?? '';
      final to = rawOp['toKey']?.toString() ?? '';
      final name = rawOp['canonicalName']?.toString().trim() ?? '';
      final validKey = RegExp(r'^entity:[a-z0-9_:-]+$');
      if (!entityKeys.contains(from) ||
          !_isResolvableAliasKey(from) ||
          !validKey.hasMatch(to) ||
          from == to ||
          name.isEmpty ||
          name.length > 100 ||
          !normalizedReview.contains(name.toLowerCase())) {
        continue;
      }
      result.add(
        KnowledgeCleanupOp.renameEntity(
          fromKey: from,
          toKey: to,
          canonicalName: name,
        ),
      );
    }
    return result;
  }

  List<dynamic>? _decodeOps(String output) {
    final match = RegExp(
      r'<glaze_knowledge_cleanup>([\s\S]*?)</glaze_knowledge_cleanup>',
    ).firstMatch(output);
    if (match == null) return null;
    final raw = extractJsonObject(match.group(1) ?? '');
    if (raw == null) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(repairJson(raw));
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['ops'] is! List) return null;
    return decoded['ops'] as List;
  }

  bool _isResolvableAliasKey(String key) => RegExp(
    r'(unknown|unidentified|stranger|woman|man|girl|boy|person|figure|netrunner|merc|неизвест|незнаком|женщин|мужчин|девуш|парень|человек|фигура|нетраннер|наёмник|наемник)',
    caseSensitive: false,
  ).hasMatch(key);
}
