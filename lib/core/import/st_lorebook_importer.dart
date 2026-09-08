import 'dart:convert';
import 'dart:io';

import '../utils/id_generator.dart';
import '../utils/time_helpers.dart';
import '../models/lorebook.dart';

class STLorebookImportResult {
  final Lorebook lorebook;
  final int entryCount;
  const STLorebookImportResult({required this.lorebook, required this.entryCount});
}

LorebookEntry _convertSTEntry(dynamic rawEntry, int index) {
  final e = rawEntry as Map<String, dynamic>;

  final rawKeys = e['keys'] ?? e['key'] ?? <dynamic>[];
  final rawSecondary = e['secondary_keys'] ?? e['keysecondary'] ?? <dynamic>[];

  List<String> parseKeys(dynamic v) {
    if (v is List) return v.map((k) => k.toString().trim()).where((k) => k.isNotEmpty).toList();
    if (v is String && v.isNotEmpty) return v.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    return [];
  }

  final stPosition = e['position'];
  final glazeMeta = e['glazeMetadata'] as Map<String, dynamic>?;
  final metaPosition = glazeMeta?['position'] as String?;

  String resolvePosition() {
    if (metaPosition == 'worldInfoBefore' ||
        metaPosition == 'worldInfoAfter' ||
        metaPosition == 'lorebooksMacro' ||
        metaPosition == 'matchGlobal') {
      return metaPosition!;
    }
    if (stPosition is int) {
      // ST uses 0=before/1=after, but we honour the user's global injection
      // position by default. Only map to an explicit position when the entry
      // comes from a Glaze export that already stored a canonical string value
      // (handled above via glazeMetadata). Raw ST integers → matchGlobal so
      // the entry follows the global Lorebook Settings setting.
      return 'matchGlobal';
    }
    if (stPosition is String) {
      if (['worldInfoBefore', 'worldInfoAfter', 'lorebooksMacro', 'matchGlobal'].contains(stPosition)) {
        return stPosition;
      }
    }
    return 'matchGlobal';
  }

  final rawFilter = e['characterFilter'];
  LorebookCharacterFilter? charFilter;
  if (rawFilter is List && rawFilter.isNotEmpty) {
    charFilter = LorebookCharacterFilter(
      names: rawFilter.map((n) => n.toString()).toList(),
    );
  } else if (rawFilter is String && rawFilter.isNotEmpty) {
    charFilter = LorebookCharacterFilter(names: [rawFilter]);
  }

  return LorebookEntry(
    id: (e['uid']?.toString()) ?? '${DateTime.now().millisecondsSinceEpoch}_$index',
    comment: (e['comment'] as String?) ?? '',
    enabled: e['enabled'] != false && e['disable'] != true,
    constant: (e['constant'] as bool?) ?? false,
    keys: parseKeys(rawKeys),
    secondaryKeys: parseKeys(rawSecondary),
    selectiveLogic: (e['selectiveLogic'] as int?) ?? 5,
    content: (e['content'] as String?) ?? '',
    position: resolvePosition(),
    order: (e['order'] as int?) ?? 100,
    scanDepth: e['scanDepth'] as int?,
    caseSensitive: (e['caseSensitive'] as bool?) ?? false,
    matchWholeWords: (e['matchWholeWords'] as bool?) ?? false,
    probability: (e['probability'] as int?) ?? 100,
    preventRecursion: (e['preventRecursion'] as bool?) ?? false,
    sticky: (e['sticky'] as int?) ?? 0,
    cooldown: (e['cooldown'] as int?) ?? 0,
    delay: (e['delay'] as int?) ?? 0,
    group: (e['group'] as String?) ?? '',
    groupProminence: (e['groupProminence'] as int?) ?? 100,
    characterFilter: charFilter,
    ignoreBudget: (e['ignoreBudget'] as bool?) ?? false,
    vectorSearch: (e['vectorSearch'] as bool?) ?? (e['vector_search'] as bool?) ?? false,
    useKeywordSearch: (e['useKeywordSearch'] as bool?) ?? (e['use_keyword_search'] as bool?) ?? true,
  );
}

Future<STLorebookImportResult> importSTLorebookFromFile(String filePath, {String? nameOverride}) async {
  final file = File(filePath);
  final jsonString = await file.readAsString();
  final json = jsonDecode(jsonString) as Map<String, dynamic>;
  return importSTLorebook(json, nameOverride: nameOverride ?? file.uri.pathSegments.last);
}

STLorebookImportResult importSTLorebook(Map<String, dynamic> json, {String nameOverride = 'Imported'}) {
  final entriesRaw = json['entries'] ?? <dynamic>[];

  List<dynamic> normalizedEntries;
  if (entriesRaw is List) {
    normalizedEntries = entriesRaw;
  } else if (entriesRaw is Map) {
    normalizedEntries = entriesRaw.values.toList();
  } else {
    normalizedEntries = [];
  }

  final entries = <LorebookEntry>[];
  for (int i = 0; i < normalizedEntries.length; i++) {
    entries.add(_convertSTEntry(normalizedEntries[i], i));
  }

  final id = generateId();
  final lb = Lorebook(
    id: id,
    name: (json['name'] as String?) ?? nameOverride.replaceAll('.json', ''),
    enabled: true,
    activationScope: 'global',
    entries: entries,
    updatedAt: currentTimestampSeconds(),
  );

  return STLorebookImportResult(lorebook: lb, entryCount: entries.length);
}
