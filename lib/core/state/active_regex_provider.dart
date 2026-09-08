import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preset.dart';
import 'db_provider.dart';
import 'active_selection_provider.dart';
import 'global_regex_provider.dart';

final activeRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  final repo = ref.watch(presetRepoProvider);
  final presets = await repo.getAll();
  final activeId = ref.watch(activePresetIdProvider);
  final preset = activeId != null
      ? presets.where((p) => p.id == activeId).firstOrNull
      : (presets.isNotEmpty ? presets.first : null);
  final presetRegexes =
      preset?.regexes.where((r) => !r.disabled).toList() ?? <PresetRegex>[];
  final globalRegexes =
      ref
          .watch(globalRegexProvider)
          .value
          ?.where((r) => !r.disabled)
          .toList() ??
      <PresetRegex>[];
  return [...presetRegexes, ...globalRegexes];
});

final displayRegexesProvider = FutureProvider<List<PresetRegex>>((ref) async {
  final all = await ref.watch(activeRegexesProvider.future);
  return all.where((r) => r.ephemerality.contains(1) && !r.promptOnly).toList();
});
