import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import 'db_provider.dart';
import 'active_selection_provider.dart';
import 'global_regex_provider.dart';
import 'studio_feature_provider.dart';

final activeRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  // Every dependency is subscribed here, before the first await. A `ref`
  // touched after one belongs to a build that a changed dependency may already
  // have replaced — and the Studio switch changes precisely then, as it comes
  // out of its loading window.
  final repo = ref.watch(presetRepoProvider);
  // Awaited, not read. The global scripts load from SharedPreferences, and on a
  // cold start that has not finished by the time anything asks for this list:
  // reading `.value` then yielded null and dropped every global script from a
  // list whose whole promise is that it has resolved. The chat's first paint
  // asks exactly once, so what it gets here is what the reader sees.
  final globalScripts = ref.watch(globalRegexProvider.future);
  // A chat preset and an agentic (Studio) preset are mutually exclusive: the
  // master switch is the flag that says which kind is in effect, and with
  // Studio on there is no active chat preset at all — its scripts belong to a
  // prompt this turn never builds. Settled rather than read, for the same
  // reason the global scripts are awaited: the switch reads `false` until
  // SharedPreferences answers, and the first paint asks exactly once.
  final studioSettled = ref.watch(studioFeatureSettledProvider.future);
  final activeId = ref.watch(activePresetIdProvider);

  final studioEnabled = await studioSettled;
  final presets = await repo.getAll();
  final preset = activeId != null
      ? presets.where((p) => p.id == activeId).firstOrNull
      : (presets.isNotEmpty ? presets.first : null);
  final presetRegexes = studioEnabled
      ? <PresetRegex>[]
      : (preset?.regexes.where((r) => !r.disabled).toList() ?? <PresetRegex>[]);
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
