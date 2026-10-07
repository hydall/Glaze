import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

const _default = ThemePreset(id: 'default', name: 'Default');
const _night = ThemePreset(id: 'night', name: 'Night');
const _paper = ThemePreset(
  id: 'paper',
  name: 'Paper',
  themeMode: kThemeModeLight,
);
const _device = ThemePreset(
  id: 'device',
  name: 'Device',
  themeMode: kThemeModeSystem,
);

void main() {
  test('a theme is drawn in the type set on it', () async {
    final n = await _notifier(_MemoryStore([_default, _night, _paper]));

    await n.applyPreset(_paper);
    expect(n.state.activePreset.id, 'paper');
    expect(n.state.isDark, isFalse);

    await n.applyPreset(_night);
    expect(n.state.isDark, isTrue);
  });

  test('a "same as device" theme follows the device', () async {
    final n = await _notifier(
      _MemoryStore([_default, _device], activeId: 'device'),
    );
    expect(n.state.isDark, isFalse);

    n.setPlatformBrightness(Brightness.dark);
    expect(n.state.isDark, isTrue);
  });

  test('built-ins stay dark unless following the device', () async {
    final n = await _notifier(_MemoryStore([_default]));
    expect(n.state.isDark, isTrue);

    await n.setFollowSystem(true);
    expect(n.state.isDark, isFalse);
  });

  test('with follow on, the device brightness picks the slot', () async {
    final store = _MemoryStore([_default, _night, _paper]);
    final n = await _notifier(store);
    await n.setFollowSystem(true);
    await n.setSlotPreset(Brightness.light, 'paper');
    await n.setSlotPreset(Brightness.dark, 'night');
    expect(n.state.activePreset.id, 'paper');

    n.setPlatformBrightness(Brightness.dark);
    expect(n.state.activePreset.id, 'night');

    expect(
      store.slots,
      const ThemeSlots(
        followSystem: true,
        lightPresetId: 'paper',
        darkPresetId: 'night',
      ),
    );
  });

  test('with follow off, the slots are ignored', () async {
    final store = _MemoryStore(
      [_default, _night, _paper],
      activeId: 'night',
      slots: const ThemeSlots(
        followSystem: false,
        lightPresetId: 'paper',
        darkPresetId: 'default',
      ),
    );
    final n = await _notifier(store);

    expect(n.state.activePreset.id, 'night');
  });

  test('picking a theme while following fills the current slot', () async {
    final n = await _notifier(_MemoryStore([_default, _night]));
    await n.setFollowSystem(true);

    await n.applyPreset(_night);

    expect(n.state.lightPresetId, 'night');
    expect(n.state.darkPresetId, 'default');
    expect(n.state.activePreset.id, 'night');
  });

  test('slots start on the current theme', () async {
    final n = await _notifier(
      _MemoryStore([_default, _night], activeId: 'night'),
    );

    expect(n.state.lightPresetId, 'night');
    expect(n.state.darkPresetId, 'night');
  });

  test('deleting a theme puts Default back where it was used', () async {
    final store = _MemoryStore([_default, _night], activeId: 'night');
    final n = await _notifier(store);

    await n.deletePreset('night');

    expect(n.state.activePreset.id, 'default');
    expect(n.state.lightPresetId, 'default');
    expect(store.slots!.darkPresetId, 'default');
  });

  test('resetToDefault turns follow off and returns to Default', () async {
    final store = _MemoryStore([_default, _paper], activeId: 'paper');
    final n = await _notifier(store);
    await n.setFollowSystem(true);

    await n.resetToDefault();

    expect(n.state.followSystem, isFalse);
    expect(n.state.activePreset.id, 'default');
    expect(store.activeId, 'default');
  });
}

Future<ThemeNotifier> _notifier(
  _MemoryStore store, {
  Brightness platform = Brightness.light,
}) async {
  final n = ThemeNotifier(
    storage: store,
    platformBrightness: platform,
    persistenceDebounce: Duration.zero,
  );
  addTearDown(n.dispose);
  await n.flushPersistence();
  return n;
}

class _MemoryStore implements ThemePresetStore {
  _MemoryStore(this.presets, {this.activeId = 'default', this.slots});

  List<ThemePreset> presets;
  String activeId;
  ThemeSlots? slots;

  @override
  Future<List<ThemePreset>> loadAll() async => List.of(presets);

  @override
  Future<String> loadActiveId() async => activeId;

  @override
  Future<void> saveAll(List<ThemePreset> presets) async =>
      this.presets = List.of(presets);

  @override
  Future<void> addPreset(ThemePreset preset) async =>
      presets = [...presets.where((p) => p.id != preset.id), preset];

  @override
  Future<void> removePreset(String id) async =>
      presets = presets.where((p) => p.id != id).toList();

  @override
  Future<void> setActive(String id) async => activeId = id;

  @override
  Future<ThemeSlots?> loadSlots() async => slots;

  @override
  Future<void> saveSlots(ThemeSlots slots) async => this.slots = slots;

  @override
  Future<ThemePreset> importFromFile(String path) => throw UnimplementedError();
}
