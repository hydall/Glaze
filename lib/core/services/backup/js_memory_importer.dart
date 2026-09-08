import 'dart:convert';

import 'package:drift/drift.dart';

import '../../db/app_db.dart';
import '../../utils/time_helpers.dart';
import 'type_converters.dart';

class JsMemoryImporter with TypeConverters {
  final AppDatabase db;

  JsMemoryImporter(this.db);

  Future<void> importMemoryBooks(String charId, dynamic memoryBooksRaw) async {
    if (memoryBooksRaw is Map) {
      await _importMemoryBooksFromMap(charId, memoryBooksRaw);
    } else if (memoryBooksRaw is List) {
      final sessionId = '${charId}_1';
      await _importMemoryBookEntries(charId, sessionId, memoryBooksRaw, {}, null);
    }
  }

  Future<void> importMemoryDrafts(String charId, dynamic pendingDraftsRaw) async {
    if (pendingDraftsRaw is! Map) return;
    for (final entry in pendingDraftsRaw.entries) {
      final sessionIdx = entry.key;
      final drafts = entry.value;
      if (drafts is! List) continue;
      final sessionId = '${charId}_$sessionIdx';
      await _importMemoryDraftsForSession(sessionId, drafts);
    }
  }

  Future<void> _importMemoryBooksFromMap(
      String charId, Map<dynamic, dynamic> memoryBooksRaw) async {
    for (final mbEntry in memoryBooksRaw.entries) {
      final mbSessionIdx = mbEntry.key;
      final mbData = mbEntry.value;
      if (mbData is! Map) continue;

      final mbFullSessionId = '${charId}_$mbSessionIdx';
      final rawEntries = mbData['entries'];
      final rawSettings =
          mbData['settings'] is Map ? mbData['settings'] as Map : <String, dynamic>{};

      if (rawEntries is List) {
        await _importMemoryBookEntries(
            charId, mbFullSessionId, rawEntries, rawSettings, mbData);
      }

      final rawDrafts = mbData['pendingDrafts'];
      if (rawDrafts is List) {
        await _importMemoryDraftsForSession(
            mbFullSessionId, rawDrafts);
      }
    }
  }

  Future<void> _importMemoryBookEntries(
      String charId,
      String sessionId,
      List<dynamic> rawEntries,
      Map<dynamic, dynamic> rawSettings,
      Map<dynamic, dynamic>? mbData) async {
    final entries = <Map<String, dynamic>>[];
    for (final e in rawEntries) {
      if (e is! Map) continue;
      entries.add({
        'id': e['id']?.toString() ?? '',
        'title': e['title'] is String
            ? e['title'] as String
            : (e['name'] is String ? e['name'] as String : ''),
        'keys': e['keys'] is List
            ? List<String>.from((e['keys'] as List).whereType<String>())
            : <String>[],
        'glazeKeys': e['glazeKeys'] is List
            ? List<String>.from((e['glazeKeys'] as List).whereType<String>())
            : <String>[],
        'content':
            e['content'] is String ? e['content'] as String : '',
        'rawContent': e['rawContent'] is String
            ? e['rawContent'] as String
            : null,
        'status': e['status'] is String
            ? e['status'] as String
            : 'active',
        'vectorSearch': e['vectorSearch'] == true,
        'messageIds': e['messageIds'] is List
            ? List<String>.from(
                (e['messageIds'] as List).whereType<String>())
            : <String>[],
        'messageRange': e['messageRange'] is Map
            ? _convertMessageRange(e['messageRange'] as Map)
            : null,
        'source': e['source'] is String
            ? e['source'] as String
            : 'manual',
        'createdAt': toInt(e['createdAt']),
        'updatedAt': toInt(e['updatedAt']) ?? 0,
        'generatedAt': toInt(e['generatedAt']),
      });
    }

    final settings = _parseMemorySettings(rawSettings);

    await db.into(db.memoryBookRows).insertOnConflictUpdate(
          MemoryBookRowsCompanion.insert(
            sessionId: sessionId,
            entriesJson: Value(jsonEncode(entries)),
            settingsJson: Value(jsonEncode(settings)),
            lastProcessedMessageCount: Value(toInt(mbData?['automation']
                        is Map
                    ? (mbData!['automation'] as Map)[
                        'lastProcessedMessageCount']
                    : null) ??
                0),
            updatedAt: Value(toInt(mbData?['updatedAt']) ??
                currentTimestampSeconds()),
          ),
        );
  }

  Map<String, dynamic> _parseMemorySettings(Map<dynamic, dynamic> rawSettings) {
    return <String, dynamic>{
      'enabled': rawSettings['enabled'] == true,
      'autoCreateEnabled': rawSettings['autoCreateEnabled'] == true,
      'autoGenerateEnabled':
          rawSettings['autoGenerateEnabled'] == true,
      'maxInjectedEntries':
          toInt(rawSettings['maxInjectedEntries']) ?? 7,
      'memoryExcerptingEnabled':
          rawSettings['memoryExcerptingEnabled'] != false,
      'autoCreateInterval':
          toInt(rawSettings['autoCreateInterval']) ?? 15,
      'autoCreateLagMessages':
          toInt(rawSettings['autoCreateLagMessages']) ?? 4,
      'useDelayedAutomation':
          rawSettings['useDelayedAutomation'] == true,
      'injectionTarget': _migrateInjectionTarget(
        rawSettings['injectionTarget'] is String
            ? rawSettings['injectionTarget'] as String
            : null,
      ),
      'batchSize': toInt(rawSettings['batchSize']) ?? 3,
      'vectorSearchEnabled':
          rawSettings['vectorSearchEnabled'] == true,
      'keyMatchMode': rawSettings['keyMatchMode'] is String
          ? rawSettings['keyMatchMode'] as String
          : 'glaze',
      'generationSource': rawSettings['generationSource'] is String
          ? rawSettings['generationSource'] as String
          : 'current',
      'generationModel': rawSettings['generationModel'] is String
          ? rawSettings['generationModel'] as String
          : '',
      'generationEndpoint':
          rawSettings['generationEndpoint'] is String
              ? rawSettings['generationEndpoint'] as String
              : '',
      'generationApiKey': rawSettings['generationApiKey'] is String
          ? rawSettings['generationApiKey'] as String
          : '',
    };
  }

  Future<void> _importMemoryDraftsForSession(
      String sessionId, List<dynamic> rawDrafts) async {
    final drafts = <Map<String, dynamic>>[];
    for (final d in rawDrafts) {
      if (d is! Map) continue;
      drafts.add({
        'id': d['id']?.toString() ?? '',
        'title': d['title'] is String ? d['title'] as String : '',
        'content': d['content'] is String ? d['content'] as String : '',
        'keys': d['keys'] is List
            ? List<String>.from((d['keys'] as List).whereType<String>())
            : <String>[],
        'glazeKeys': d['glazeKeys'] is List
            ? List<String>.from((d['glazeKeys'] as List).whereType<String>())
            : <String>[],
        'vectorSearch': d['vectorSearch'] == true,
        'messageIds': d['messageIds'] is List
            ? List<String>.from((d['messageIds'] as List).whereType<String>())
            : <String>[],
        'messageRange': d['messageRange'] is Map
            ? _convertMessageRange(d['messageRange'] as Map)
            : null,
        'status': d['status'] is String ? d['status'] as String : 'pending_generation',
        'source': d['source'] is String ? d['source'] as String : '',
        'createdAt': toInt(d['createdAt']) ?? 0,
        'updatedAt': toInt(d['updatedAt']) ?? 0,
        'generatedAt': toInt(d['generatedAt']),
        'error': d['error'] is String ? d['error'] as String : null,
      });
    }

    final existing = await (db.select(db.memoryBookRows)
          ..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();
    if (existing != null) {
      await (db.update(db.memoryBookRows)
            ..where((t) => t.sessionId.equals(sessionId)))
          .write(MemoryBookRowsCompanion(
        pendingDraftsJson: Value(jsonEncode(drafts)),
      ));
    } else {
      await db.into(db.memoryBookRows).insertOnConflictUpdate(
            MemoryBookRowsCompanion.insert(
              sessionId: sessionId,
              pendingDraftsJson: Value(jsonEncode(drafts)),
            ),
          );
    }
  }

  Map<String, dynamic>? _convertMessageRange(Map<dynamic, dynamic> raw) {
    if (raw.containsKey('start') && raw.containsKey('end')) {
      return {
        'start': toInt(raw['start']) ?? 0,
        'end': toInt(raw['end']) ?? 0,
      };
    }
    return null;
  }
}

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro`. The old values
/// were misleadingly named because the "summary" prefix was about
/// *where* memory goes, not about the summary feature itself.
String _migrateInjectionTarget(String? raw) {
  if (raw == 'summary_block') return 'hard_block';
  if (raw == 'summary_macro') return 'macro';
  return raw ?? 'hard_block';
}
