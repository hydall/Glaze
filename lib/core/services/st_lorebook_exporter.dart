import '../models/lorebook.dart';

/// Map a Glaze entry position to the SillyTavern integer convention
/// (0 = before char, 1 = after char, 4 = at depth / @D).
///
/// `matchGlobal` / `worldInfoAfter` have no dedicated ST slot — they follow the
/// global injection position, which ST represents as "after char".
int glazePositionToST(String position) {
  switch (position) {
    case 'worldInfoBefore':
      return 0;
    case 'lorebooksMacro':
      return 4;
    default:
      return 1;
  }
}

/// Emit a SillyTavern World Info book (`{name, entries: {"0": {...}}}`) from a
/// Glaze [Lorebook] for `.json` export.
///
/// Glaze-only fields ride along in the non-standard `glazeMetadata` block so
/// `importSTLorebook` can restore them losslessly; everything top-level follows
/// the ST shape (see `docs/` — same conventions as `glazeLorebookToTavernJson`
/// in the Janitor catalog service).
Map<String, dynamic> glazeLorebookToSTJson(Lorebook lb) {
  final entries = <String, dynamic>{};
  for (var i = 0; i < lb.entries.length; i++) {
    final e = lb.entries[i];
    entries['$i'] = {
      'uid': i,
      'key': e.keys,
      'keysecondary': e.secondaryKeys,
      'comment': e.comment,
      'content': e.content,
      'constant': e.constant,
      'selective': e.selectiveLogic != 4,
      'selectiveLogic': e.selectiveLogic,
      'order': e.order,
      'position': glazePositionToST(e.position),
      'disable': !e.enabled,
      'probability': e.probability,
      'useProbability': true,
      'preventRecursion': e.preventRecursion,
      'excludeRecursion': false,
      'delayUntilRecursion': e.delayUntilRecursion,
      'group': e.group,
      'groupWeight': e.groupProminence,
      'sticky': e.sticky,
      'cooldown': e.cooldown,
      'delay': e.delay,
      'scanDepth': e.scanDepth,
      'caseSensitive': e.caseSensitive,
      'matchWholeWords': e.matchWholeWords,
      'useGroupScoring': e.useGroupScoring,
      if (e.characterFilter != null)
        'characterFilter': {
          'isExclude': e.characterFilter!.isExclude,
          'names': e.characterFilter!.names,
          'tags': <String>[],
        },
      'glazeMetadata': {
        'position': e.position,
        'vectorSearch': e.vectorSearch,
        'useKeywordSearch': e.useKeywordSearch,
        'ignoreBudget': e.ignoreBudget,
        if (e.characterFilter != null)
          'characterFilter': {
            'names': e.characterFilter!.names,
            'isExclude': e.characterFilter!.isExclude,
          },
      },
    };
  }
  return {'name': lb.name, 'entries': entries};
}
