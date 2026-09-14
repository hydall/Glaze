import 'dart:convert';
import 'dart:io';

import '../llm/glaze_matcher.dart';
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
    if (v is String && v.isNotEmpty) return splitLorebookKeys(v);
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
  LorebookCharacterFilter? charFilter = _parseCharacterFilter(rawFilter) ??
      _parseCharacterFilter(glazeMeta?['characterFilter']);

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
    // Deliberately not `?? false`. Both are three-state on an entry — null
    // means "follow the book, then the global setting", which is what
    // `LorebookScanner` resolves (`entry.caseSensitive ?? book ?? global`) and
    // what SillyTavern means by them too. Defaulting null to false turned
    // "inherit" into an explicit "never", so an entry imported from ST stopped
    // following a global the reader had set on purpose — and did it silently,
    // since the switch reads the same either way.
    caseSensitive: e['caseSensitive'] as bool?,
    matchWholeWords: e['matchWholeWords'] as bool?,
    probability: (e['probability'] as int?) ?? 100,
    preventRecursion:
        (e['preventRecursion'] as bool?) ?? (e['excludeRecursion'] as bool?) ?? false,
    sticky: (e['sticky'] as int?) ?? 0,
    cooldown: (e['cooldown'] as int?) ?? 0,
    delay: (e['delay'] as int?) ?? 0,
    group: (e['group'] as String?) ?? '',
    groupProminence:
        (e['groupProminence'] as int?) ?? (e['groupWeight'] as int?) ?? 100,
    characterFilter: charFilter,
    ignoreBudget:
        (e['ignoreBudget'] as bool?) ?? (glazeMeta?['ignoreBudget'] as bool?) ?? false,
    vectorSearch: (e['vectorSearch'] as bool?) ??
        (e['vector_search'] as bool?) ??
        (glazeMeta?['vectorSearch'] as bool?) ??
        false,
    useKeywordSearch: (e['useKeywordSearch'] as bool?) ??
        (e['use_keyword_search'] as bool?) ??
        (glazeMeta?['useKeywordSearch'] as bool?) ??
        true,
    delayUntilRecursion: (e['delayUntilRecursion'] as bool?) ?? false,
    useGroupScoring: (e['useGroupScoring'] as bool?) ?? false,
  );
}

/// Accepts the shapes seen in the wild:
/// - ST native map: `{isExclude: bool, names: [...], tags: [...]}`
/// - Glaze `glazeMetadata` map: `{names: [...], isExclude: bool}`
/// - bare name list `[...]` or a single `'Name'` string.
LorebookCharacterFilter? _parseCharacterFilter(dynamic raw) {
  if (raw is Map) {
    final names = (raw['names'] as List?)
            ?.map((n) => n.toString())
            .where((n) => n.isNotEmpty)
            .toList() ??
        const <String>[];
    if (names.isEmpty) return null;
    return LorebookCharacterFilter(names: names, isExclude: raw['isExclude'] == true);
  }
  if (raw is List && raw.isNotEmpty) {
    return LorebookCharacterFilter(
      names: raw.map((n) => n.toString()).toList(),
    );
  }
  if (raw is String && raw.isNotEmpty) {
    return LorebookCharacterFilter(names: [raw]);
  }
  return null;
}

Future<STLorebookImportResult> importSTLorebookFromFile(String filePath, {String? nameOverride}) async {
  final file = File(filePath);
  final jsonString = await file.readAsString();
  final json = jsonDecode(jsonString) as Map<String, dynamic>;
  return importSTLorebook(json, nameOverride: nameOverride ?? file.uri.pathSegments.last);
}

/// The book-level `glazeMetadata` a Glaze export writes, when this file came
/// from one. Absent for a book written by SillyTavern itself, which is the
/// point: the settings are restored when they were ours to begin with, and a
/// foreign book keeps Glaze's defaults rather than inventing values for it.
LorebookSettings? _bookSettings(Map<String, dynamic> json) {
  final meta = json['glazeMetadata'];
  if (meta is! Map) return null;
  final settings = meta['settings'];
  if (settings is! Map) return null;
  try {
    return LorebookSettings.fromJson(
      settings.map((key, value) => MapEntry(key.toString(), value)),
    );
  } catch (_) {
    // A book written by an older or newer Glaze, whose settings no longer
    // parse. The entries are the valuable part and they are already read;
    // losing the tuning is better than losing the import.
    return null;
  }
}

String _bookDescription(Map<String, dynamic> json) {
  final meta = json['glazeMetadata'];
  if (meta is! Map) return '';
  final description = meta['description'];
  return description is String ? description : '';
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
    settings: _bookSettings(json),
    description: _bookDescription(json),
    updatedAt: currentTimestampSeconds(),
  );

  return STLorebookImportResult(lorebook: lb, entryCount: entries.length);
}
