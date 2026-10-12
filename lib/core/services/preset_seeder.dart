import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/presets/preset_list_provider.dart';
import '../state/db_provider.dart';
import '../state/shared_prefs_provider.dart';
import 'featured_presets.dart';

const _seededKey = 'defaultPresetsSeeded';
const _featuredSeededKey = 'featuredPresetsSeeded_v2';

/// Per-preset revision last written by the seeder, so a shipped update to a
/// bundled preset can be told apart from a preset the user has kept.
String _featuredRevisionKey(String id) => 'featuredPresetRev_$id';

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
/// MicroCot, Renri, NoriMyn) with their cover images, and refreshes any whose
/// bundled revision has moved on since it was last written.
///
/// The global flag marks the first run: a preset missing on an install that
/// already had its first run is one the user deleted, so it is not put back.
/// After that, a preset still in the library is refreshed when its bundled
/// [FeaturedPreset.revision] is newer than the one the seeder last wrote — the
/// way a shipped update to a bundled preset reaches existing installs.
Future<void> seedFeaturedPresets(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  final firstRun = prefs.getBool(_featuredSeededKey) != true;
  final repo = ref.read(presetRepoProvider);
  var wrote = false;

  try {
    for (final f in featuredPresets) {
      final revisionKey = _featuredRevisionKey(f.id);
      final existing = await repo.getById(f.id);
      if (existing == null) {
        // A first run seeds everything; a later run leaves a deleted preset
        // deleted instead of resurrecting it.
        if (firstRun) {
          await repo.put(await loadFeaturedPreset(f));
          await prefs.setInt(revisionKey, f.revision);
          wrote = true;
        }
        continue;
      }
      // An install seeded before revisions were tracked counts as revision 1.
      final seededRevision = prefs.getInt(revisionKey) ?? 1;
      if (f.revision > seededRevision) {
        await repo.put(await loadFeaturedPreset(f));
        wrote = true;
      }
      await prefs.setInt(revisionKey, f.revision);
    }

    await prefs.setBool(_featuredSeededKey, true);
  } finally {
    // Seeding runs in the background, so the preset list (Tools card, desktop
    // sidebar, chat preset resolution) may already have loaded the library
    // without these presets and would keep that until the next launch.
    if (wrote) ref.invalidate(presetListProvider);
  }
}
