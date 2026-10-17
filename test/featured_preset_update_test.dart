import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_repo_interfaces.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/services/featured_presets.dart';
import 'package:glaze_flutter/core/services/preset_seeder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores presets the way `PresetRepo` does: as their JSON.
class _MemoryPresetStore implements SyncPresetStore {
  final rows = <String, String>{};

  @override
  Future<List<Preset>> getAll() async => rows.values
      .map((r) => Preset.fromJson(jsonDecode(r) as Map<String, dynamic>))
      .toList();

  @override
  Future<Preset?> getById(String id) async {
    final row = rows[id];
    return row == null
        ? null
        : Preset.fromJson(jsonDecode(row) as Map<String, dynamic>);
  }

  @override
  Future<void> put(Preset p) async => rows[p.id] = jsonEncode(p.toJson());

  @override
  Future<void> delete(String id) async => rows.remove(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final renri = featuredPresets.firstWhere((f) => f.id == 'default_renri');

  /// An install that already had its first run, holding [stored] as Renri
  /// from before revisions were tracked.
  Future<(SharedPreferences, _MemoryPresetStore)> install(
    Preset stored, {
    List<String>? order,
  }) async {
    SharedPreferences.setMockInitialValues({
      'featuredPresetsSeeded_v2': true,
      'presetOrder': ?(order == null ? null : jsonEncode(order)),
    });
    final store = _MemoryPresetStore();
    await store.put(stored);
    return (await SharedPreferences.getInstance(), store);
  }

  Future<Preset> previousRenri() =>
      loadFeaturedPreset(renri, jsonAsset: renri.previousJsonAsset);

  test('an untouched Renri is replaced by the update', () async {
    final (prefs, store) = await install(await previousRenri());

    await syncFeaturedPresets(prefs: prefs, repo: store);

    final all = await store.getAll();
    expect(all, hasLength(1));
    expect(
      jsonEncode(all.single.toJson()),
      jsonEncode((await loadFeaturedPreset(renri)).toJson()),
    );
    expect(prefs.getInt('featuredPresetRev_default_renri'), renri.revision);
  });

  test('importer differences alone do not count as an edit', () async {
    // The Vue migration left its own ids, depths and block order behind.
    final previous = await previousRenri();
    final reimported = previous.copyWith(
      blocks: [
        for (final (i, b) in previous.blocks.reversed.indexed)
          b.isStatic ? b : b.copyWith(id: 'vue$i', depth: 4),
      ],
      regexes: [
        for (final r in previous.regexes)
          r.copyWith(id: '${r.id}x', markdownOnly: !r.markdownOnly),
      ],
      createdAt: 29170397297,
    );
    final (prefs, store) = await install(reimported);

    await syncFeaturedPresets(prefs: prefs, repo: store);

    expect(await store.getAll(), hasLength(1));
  });

  test('a toggled block counts as an edit', () async {
    final previous = await previousRenri();
    final toggled = previous.copyWith(
      blocks: [
        for (final b in previous.blocks)
          b.name == '☆ infoboard' ? b.copyWith(enabled: !b.enabled) : b,
      ],
    );
    final (prefs, store) = await install(toggled);

    await syncFeaturedPresets(prefs: prefs, repo: store);

    final names = (await store.getAll()).map((p) => p.name);
    expect(names, unorderedEquals(['Renri', 'Old Renri']));
  });

  test('an edited Renri is kept next to the update as Old Renri', () async {
    final previous = await previousRenri();
    final edited = previous.copyWith(
      blocks: [
        for (final b in previous.blocks)
          b.id == 'main' ? b.copyWith(content: 'my own main prompt') : b,
      ],
    );
    final (prefs, store) = await install(
      edited,
      order: ['default_shino', 'default_renri', 'mine'],
    );

    await syncFeaturedPresets(prefs: prefs, repo: store);
    // A later launch leaves both alone.
    await syncFeaturedPresets(prefs: prefs, repo: store);

    final all = await store.getAll();
    expect(all, hasLength(2));
    final updated = all.firstWhere((p) => p.id == 'default_renri');
    expect(
      jsonEncode(updated.toJson()),
      jsonEncode((await loadFeaturedPreset(renri)).toJson()),
    );

    final old = all.firstWhere((p) => p.id != 'default_renri');
    expect(old.name, 'Old Renri');
    expect(old.imagePath, 'assets/presets/renri_old.jpg');
    expect(
      old.blocks.firstWhere((b) => b.id == 'main').content,
      'my own main prompt',
    );

    final order = (jsonDecode(prefs.getString('presetOrder')!) as List)
        .cast<String>();
    expect(order, ['default_shino', 'default_renri', old.id, 'mine']);
  });
}
