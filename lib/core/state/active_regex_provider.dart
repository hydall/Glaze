import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import 'db_provider.dart';
import 'active_selection_provider.dart';
import 'global_regex_provider.dart';

final activeRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  final repo = ref.watch(presetRepoProvider);
  // Awaited, not read. The global scripts load from SharedPreferences, and on a
  // cold start that has not finished by the time anything asks for this list:
  // reading `.value` then yielded null and dropped every global script from a
  // list whose whole promise is that it has resolved. The chat's first paint
  // asks exactly once, so what it gets here is what the reader sees.
  final globalScripts = ref.watch(globalRegexProvider.future);
  final presets = await repo.getAll();
  final activeId = ref.watch(activePresetIdProvider);
  final preset = activeId != null
      ? presets.where((p) => p.id == activeId).firstOrNull
      : (presets.isNotEmpty ? presets.first : null);
  final presetRegexes =
      preset?.regexes.where((r) => !r.disabled).toList() ?? <PresetRegex>[];
  final globalRegexes = (await globalScripts)
      .where((r) => !r.disabled)
      .toList();
  return [...presetRegexes, ...globalRegexes];
});

final displayRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  final all = await ref.watch(activeRegexesProvider.future);
  // "Only Format Prompt" keeps a script out of the display pass — unless it
  // also ticks "Only Format Display", which opts it into both passes (ST ORs
  // the two flags; see [applyRegexes]).
  return all
      .where(
        (r) =>
            r.ephemerality.contains(1) && (!r.promptOnly || r.markdownOnly),
      )
      .toList();
});
