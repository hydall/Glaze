import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/db_provider.dart';
import '../state/shared_prefs_provider.dart';
import 'featured_presets.dart';

const _seededKey = 'defaultPresetsSeeded';
const _featuredSeededKey = 'featuredPresetsSeeded_v1';

/// The preset a first run lands on.
///
/// Shino is one of the featured presets the app ships and the one it ships to
/// be used. The old first-run preset, "Default Chat", was a bare skeleton
/// assembled in this file — a main prompt, an NSFW block and a one-line
/// jailbreak — that happened to sort first and so became what a new install
/// generated with without anyone choosing it. It is no longer created.
const defaultPresetId = 'default_shino';

/// The preset to make active on a first run, or null to leave the choice
/// alone.
///
/// [alreadySeeded] is the first-run flag; [activePresetId] is what the user is
/// already set to. A restored backup and a migration from the Vue app both
/// write an active preset and can both leave the flag clear, so an existing
/// choice always wins — this only ever fills a blank.
String? defaultPresetChoice({
  required bool alreadySeeded,
  required String? activePresetId,
}) {
  if (alreadySeeded) return null;
  if (activePresetId != null && activePresetId.isNotEmpty) return null;
  return defaultPresetId;
}

/// Writes a first run's active preset, before the app reads the preference.
///
/// Runs from `main()` rather than as one of the app's startup tasks so that by
/// the time `loadActiveSelections` reads `activePresetId` the value is simply
/// there, exactly as it is for an install that already has one. Deciding it
/// later means publishing into `activePresetIdProvider` while the router is
/// building its first routes, and a provider going dirty at that point leaves
/// Riverpod's refresh to land inside a build — which the framework refuses.
///
/// Runs exactly once per install: after the flag is written the active preset
/// is the user's own and is never touched here again.
Future<void> applyFirstRunPresetChoice({SharedPreferences? preferences}) async {
  final prefs = preferences ?? await SharedPreferences.getInstance();
  final choice = defaultPresetChoice(
    alreadySeeded: prefs.getBool(_seededKey) == true,
    activePresetId: prefs.getString('activePresetId'),
  );
  // Stamped either way: an install that arrived with a preset of its own has
  // had its first run, and there is nothing here to redo.
  await prefs.setBool(_seededKey, true);
  if (choice == null) return;
  await prefs.setString('activePresetId', choice);
}

/// Seeds the standard "featured" presets from hydall/Glaze (Shino, Fawnie,
/// MicroCot, Renri) with their cover images. Runs once (own storage key) so
/// existing installs pick them up too, and never clobbers a copy the user may
/// already have under the same id.
Future<void> seedFeaturedPresets(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  if (prefs.getBool(_featuredSeededKey) == true) return;

  final repo = ref.read(presetRepoProvider);
  for (final f in featuredPresets) {
    if (await repo.getById(f.id) != null) continue;
    await repo.put(await loadFeaturedPreset(f));
  }

  await prefs.setBool(_featuredSeededKey, true);
}
