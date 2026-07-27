import '../../core/models/lorebook.dart';

Lorebook convertCharacterBook(
  Map<String, dynamic> bookData,
  String characterId,
) {
  final rawEntries = _normalizeEntries(bookData['entries']);
  final entries = <LorebookEntry>[];

  for (int i = 0; i < rawEntries.length; i++) {
    final rawEntry = rawEntries[i];
    if (rawEntry is! Map) continue;
    final e = Map<String, dynamic>.from(rawEntry);
    final keys = (e['keys'] as List<dynamic>?)
            ?.map((k) => k.toString())
            .toList() ??
        [];
    final secondaryKeys = (e['secondary_keys'] as List<dynamic>?)
            ?.map((k) => k.toString())
            .toList() ??
        [];

    entries.add(LorebookEntry(
      id: e['id']?.toString() ?? 'cbentry_$i',
      comment: (e['name'] as String?) ?? (e['comment'] as String?) ?? '',
      keys: keys,
      secondaryKeys: secondaryKeys,
      content: (e['content'] as String?) ?? '',
      enabled: e['enabled'] as bool? ?? true,
      constant: e['constant'] as bool? ?? false,
      position: _mapPosition(e['position']),
      order: e['insertion_order'] as int? ?? e['order'] as int? ?? 100,
      scanDepth: e['scan_depth'] as int?,
      caseSensitive: e['case_sensitive'] as bool?,
      matchWholeWords: e['match_whole_words'] as bool?,
      selectiveLogic: _mapSelectiveLogic(e['selective'] as bool?, e['selective_logic'] as int?),
      probability: _mapProbability(e),
      group: (e['group'] as String?) ?? '',
      preventRecursion: e['prevent_recursion'] as bool? ?? false,
      sticky: e['constant'] as bool? ?? false ? 1 : 0,
    ));
  }

  return Lorebook(
    id: 'charbook_${characterId}_${DateTime.now().millisecondsSinceEpoch}',
    name: (bookData['name'] as String?) ?? 'Character Book',
    enabled: false,
    activationScope: 'character',
    activationTargetId: characterId,
    entries: entries,
  );
}

int _mapProbability(Map<String, dynamic> entry) {
  final extensions = entry['extensions'];
  final extensionProbability = extensions is Map
      ? extensions['probability']
      : null;
  final probability = entry['probability'] ?? extensionProbability;
  return probability is num ? probability.round().clamp(0, 100) : 100;
}

List<dynamic> _normalizeEntries(dynamic entries) {
  if (entries is List) return entries;
  if (entries is Map) return entries.values.toList();
  return const [];
}

String _mapPosition(Object? pos) {
  if (pos is String) {
    switch (pos) {
      case 'before_char':
      case 'before_character':
      case 'worldInfoBefore':
        return 'worldInfoBefore';
      case 'after_char':
      case 'after_character':
      case 'worldInfoAfter':
        return 'worldInfoAfter';
      case 'at_depth':
      case 'lorebooksMacro':
        return 'lorebooksMacro';
      default:
        return 'worldInfoAfter';
    }
  }
  if (pos is num) {
    return _mapPositionInt(pos.toInt());
  }
  return 'worldInfoAfter';
}

String _mapPositionInt(int pos) {
  switch (pos) {
    case 0:
      return 'worldInfoBefore';
    case 1:
      return 'worldInfoAfter';
    case 2:
      return 'worldInfoBefore';
    case 3:
      return 'worldInfoAfter';
    case 4:
      return 'worldInfoBefore';
    default:
      return 'worldInfoAfter';
  }
}

int _mapSelectiveLogic(bool? selective, int? selectiveLogic) {
  if (selective != true) return 4;
  return selectiveLogic ?? 1;
}

int _reversePosition(String pos) {
  switch (pos) {
    case 'worldInfoBefore': return 0;
    case 'worldInfoAfter': return 1;
    case 'lorebooksMacro': return 2;
    default: return 1;
  }
}

Map<String, dynamic> lorebookToCharacterBookJson(Lorebook lorebook) {
  final entries = <Map<String, dynamic>>[];
  for (final e in lorebook.entries) {
    final entry = <String, dynamic>{
      'id': e.id,
      'keys': e.keys,
      'secondary_keys': e.secondaryKeys,
      'content': e.content,
      'comment': e.comment,
      'enabled': e.enabled,
      'constant': e.constant,
      'position': _reversePosition(e.position),
      'insertion_order': e.order,
      'selective_logic': e.selectiveLogic,
      'probability': e.probability,
      'group': e.group,
      'prevent_recursion': e.preventRecursion,
    };
    if (e.scanDepth != null) entry['scan_depth'] = e.scanDepth!;
    if (e.caseSensitive != null) entry['case_sensitive'] = e.caseSensitive!;
    if (e.matchWholeWords != null) {
      entry['match_whole_words'] = e.matchWholeWords!;
    }
    if (e.characterFilter != null) {
      entry['character_filter'] = {
        'names': e.characterFilter!.names,
        'is_exclude': e.characterFilter!.isExclude,
      };
    }
    entries.add(entry);
  }

  return {
    'name': lorebook.name,
    'entries': entries,
  };
}
