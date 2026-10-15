import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/presets/preset_list_provider.dart';
import '../application/sync_repo_interfaces.dart';
import '../models/preset.dart';
import '../state/db_provider.dart';
import '../state/shared_prefs_provider.dart';
import '../utils/id_generator.dart';
import 'featured_presets.dart';

const _seededKey = 'defaultPresetsSeeded';
const _featuredSeededKey = 'featuredPresetsSeeded_v2';

/// The user's custom preset list order (see `PresetListNotifier`).
const _presetOrderKey = 'presetOrder';

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
///
/// An update never discards the user's work: when the stored preset no longer
/// matches the bundled revision it was seeded from, it is kept under a new id
/// as "Old `name`", next to the updated one.
Future<void> seedFeaturedPresets(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  var wrote = false;
  try {
    await syncFeaturedPresets(
      prefs: prefs,
      repo: ref.read(presetRepoProvider),
      onWrite: () => wrote = true,
    );
  } finally {
    // Seeding runs in the background, so the preset list (Tools card, desktop
    // sidebar, chat preset resolution) may already have loaded the library
    // without these presets and would keep that until the next launch.
    if (wrote) ref.invalidate(presetListProvider);
  }
}

/// The body of [seedFeaturedPresets], without Riverpod. [onWrite] fires on
/// each write to [repo], so a run that fails halfway still refreshes the list.
@visibleForTesting
Future<void> syncFeaturedPresets({
  required SharedPreferences prefs,
  required SyncPresetStore repo,
  void Function()? onWrite,
}) async {
  final firstRun = prefs.getBool(_featuredSeededKey) != true;
  for (final f in featuredPresets) {
    final revisionKey = _featuredRevisionKey(f.id);
    final existing = await repo.getById(f.id);
    if (existing == null) {
      // A first run seeds everything; a later run leaves a deleted preset
      // deleted instead of resurrecting it.
      if (firstRun) {
        await repo.put(await loadFeaturedPreset(f));
        await prefs.setInt(revisionKey, f.revision);
        onWrite?.call();
      }
      continue;
    }
    // An install seeded before revisions were tracked counts as revision 1.
    final seededRevision = prefs.getInt(revisionKey) ?? 1;
    if (f.revision > seededRevision) {
      // Loaded before anything is written, so a bad asset cannot leave a kept
      // copy behind that the next launch would duplicate.
      final updated = await loadFeaturedPreset(f);
      if (!await _matchesPreviousRevision(existing, f)) {
        await _keepOldCopy(prefs, repo, existing, f);
        onWrite?.call();
      }
      await repo.put(updated);
      onWrite?.call();
    }
    await prefs.setInt(revisionKey, f.revision);
  }

  await prefs.setBool(_featuredSeededKey, true);
}

/// Whether replacing [existing] with the update loses nothing the user did to
/// the previous bundled revision of [f]: every editable block (its text and
/// switch) and every regex in it is one that revision shipped.
///
/// Not an exact comparison on purpose. The same bundled preset reached
/// installs through different importers (the Vue app's migration among them),
/// which leave their own block ids, depths, ordering and regex flags behind,
/// so only what the user can actually author is compared. A preset that
/// shipped no previous revision is always replaced.
Future<bool> _matchesPreviousRevision(Preset existing, FeaturedPreset f) async {
  final asset = f.previousJsonAsset;
  if (asset == null) return true;
  final shipped = _authoredParts(await loadFeaturedPreset(f, jsonAsset: asset));
  for (final part in _authoredParts(existing)) {
    if (!shipped.remove(part)) return false;
  }
  return true;
}

List<String> _authoredParts(Preset p) => [
  for (final b in p.blocks)
    if (!b.isStatic)
      jsonEncode(['block', b.name, b.role, b.content, b.enabled]),
  for (final r in p.regexes)
    jsonEncode(['regex', r.name, r.regex, r.replacement, r.disabled]),
];

/// Saves the user's edited [existing] under a fresh id as "Old `name`" with
/// the previous cover, and places it right after the featured preset in a
/// custom list order.
Future<void> _keepOldCopy(
  SharedPreferences prefs,
  SyncPresetStore repo,
  Preset existing,
  FeaturedPreset f,
) async {
  final copy = existing.copyWith(
    id: generateId(),
    name: 'Old ${f.name}',
    imagePath: existing.imagePath ?? f.previousImageAsset ?? f.imageAsset,
  );
  await repo.put(copy);

  final raw = prefs.getString(_presetOrderKey);
  if (raw == null) return;
  try {
    final order = (jsonDecode(raw) as List).cast<String>();
    final at = order.indexOf(f.id);
    if (at < 0) return;
    order.insert(at + 1, copy.id);
    await prefs.setString(_presetOrderKey, jsonEncode(order));
  } catch (_) {
    // An unreadable order is the list's problem; the copy is already saved.
  }
}
