import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/regex_passes.dart';
import '../models/preset.dart';
import 'db_provider.dart';
import 'active_selection_provider.dart';
import 'global_regex_provider.dart';

final activeRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  // Every dependency is subscribed here, before the first await. A `ref`
  // touched after one belongs to a build that a changed dependency may already
  // have replaced.
  final repo = ref.watch(presetRepoProvider);
  // Awaited, not read. The global scripts load from SharedPreferences, and on a
  // cold start that has not finished by the time anything asks for this list:
  // reading `.value` then yielded null and dropped every global script from a
  // list whose whole promise is that it has resolved. The chat's first paint
  // asks exactly once, so what it gets here is what the reader sees.
  final globalScripts = ref.watch(globalRegexProvider.future);
  final activeId = ref.watch(activePresetIdProvider);

  final presets = await repo.getAll();
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
  // The same answer the engine gives (see [RegexPasses]): the flags of an
  // imported script, else Glaze's own list.
  return all.where((r) => r.altersDisplay).toList();
});
