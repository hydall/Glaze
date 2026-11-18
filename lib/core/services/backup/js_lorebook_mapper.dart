import '../../models/lorebook.dart';
import 'type_converters.dart';

mixin JsLorebookMapper on TypeConverters {
  String mapLorebookPosition(dynamic pos) {
    if (pos is String) return pos;
    if (pos is int) {
      return switch (pos) {
        0 => 'worldInfoBefore',
        1 => 'worldInfoAfter',
        2 => 'worldInfoBefore',
        3 => 'worldInfoAfter',
        4 => 'at_depth',
        _ => 'worldInfoBefore',
      };
    }
    return 'worldInfoBefore';
  }

  Map<String, dynamic> mapJsLorebookEntry(Map<String, dynamic> e) {
    final keys = toStringList(e['keys'] ?? e['key']);
    final secondaryKeys = toStringList(
        e['secondaryKeys'] ?? e['secondary_keys'] ?? e['keysecondary']);

    var enabled = e['enabled'] as bool?;
    if (enabled == null) {
      final disabled = e['disable'] as bool? ?? false;
      enabled = !disabled;
    }

    final position = mapLorebookPosition(e['position']);

    final charFilter = e['characterFilter'] ?? e['character_filter'];
    LorebookCharacterFilter? filter;
    if (charFilter is Map) {
      final names = charFilter['names'];
      filter = LorebookCharacterFilter(
        names: names is List ? names.map((n) => n.toString()).toList() : [],
        isExclude: charFilter['isExclude'] as bool? ?? false,
      );
    } else if (charFilter is List) {
      filter = LorebookCharacterFilter(
        names: charFilter.map((n) => n.toString()).toList(),
      );
    }

    return {
      'id': (e['uid'] ?? e['id'] ?? DateTime.now().millisecondsSinceEpoch)
          .toString(),
      'comment': e['comment'] ?? e['name'] ?? '',
      'enabled': enabled,
      'constant': e['constant'] as bool? ?? false,
      'keys': keys,
      'secondaryKeys': secondaryKeys,
      'selectiveLogic': e['selectiveLogic'] ?? e['selective_logic'] ?? 5,
      'content': e['content'] ?? '',
      'position': position,
      'order': toInt(e['order'] ?? e['insertion_order']) ?? 100,
      'scanDepth': toInt(e['scanDepth'] ?? e['scan_depth']),
      'caseSensitive': e['caseSensitive'] ?? e['case_sensitive'] ?? false,
      'matchWholeWords':
          e['matchWholeWords'] ?? e['match_whole_words'] ?? false,
      'probability': toDouble(e['probability']) ?? 100.0,
      'preventRecursion':
          e['preventRecursion'] ?? e['prevent_recursion'] ?? false,
      'sticky': toInt(e['sticky']) ?? 0,
      'cooldown': toInt(e['cooldown']) ?? 0,
      'delay': toInt(e['delay']) ?? 0,
      'group': e['group'] ?? '',
      'groupProminence':
          toInt(e['groupProminence'] ?? e['group_prominence']) ?? 100,
      'characterFilter': filter?.toJson(),
      'ignoreBudget': e['ignoreBudget'] ?? false,
      'vectorSearch': e['vectorSearch'] ?? e['vector_search'] ?? false,
      'useKeywordSearch':
          e['useKeywordSearch'] ?? e['use_keyword_search'] ?? true,
      'delayUntilRecursion':
          e['delayUntilRecursion'] ?? e['delay_until_recursion'] ?? false,
      'useGroupScoring':
          e['useGroupScoring'] ?? e['use_group_scoring'] ?? false,
    };
  }
}
