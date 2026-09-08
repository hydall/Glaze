import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

void main() {
  const initial = ThemePreset(id: 'custom', name: 'Initial');

  late _FakeThemePresetStore store;
  late _ControlledDelay delay;
  late ThemeNotifier notifier;

  setUp(() async {
    store = _FakeThemePresetStore([initial]);
    delay = _ControlledDelay();
    notifier = ThemeNotifier(storage: store, delay: delay.call);
    await notifier.flushPersistence();
  });

  tearDown(() {
    notifier.dispose();
  });

  test('preset preview updates state immediately', () {
    final updated = initial.copyWith(name: 'Preview');

    unawaited(notifier.updatePreset(updated));

    expect(notifier.state.activePreset, updated);
    expect(notifier.state.presets, [updated]);
    expect(store.saveCalls, isEmpty);
  });

  test('rapid preset updates coalesce into one persistence write', () async {
    final first = initial.copyWith(name: 'First');
    final second = initial.copyWith(name: 'Second');
    final latest = initial.copyWith(name: 'Latest');

    unawaited(notifier.updatePreset(first));
    unawaited(notifier.updatePreset(second));
    unawaited(notifier.updatePreset(latest));
    delay.elapseAll();
    await pumpEventQueue();
    await notifier.flushPersistence();

    expect(store.saveCalls, [latest]);
    expect(store.durable, [latest]);
  });

  test('a slow first write cannot overwrite a newer preset', () async {
    final first = initial.copyWith(name: 'First');
    final latest = initial.copyWith(name: 'Latest');
    final firstGate = store.gateNextSave();

    unawaited(notifier.updatePreset(first));
    delay.elapseNext();
    await pumpEventQueue();
    expect(store.saveCalls, [first]);

    unawaited(notifier.updatePreset(latest));
    delay.elapseNext();
    await pumpEventQueue();
    expect(store.saveCalls, [
      first,
    ], reason: 'new write must wait for the old one');

    firstGate.complete();
    await notifier.flushPersistence();

    expect(store.saveCalls, [first, latest]);
    expect(store.durable, [latest]);
  });

  test('flush bypasses debounce and waits for durable persistence', () async {
    final latest = initial.copyWith(name: 'Latest');
    final gate = store.gateNextSave();

    unawaited(notifier.updatePreset(latest));
    var flushed = false;
    final flush = notifier.flushPersistence().then((_) => flushed = true);
    await pumpEventQueue();

    expect(store.saveCalls, [latest]);
    expect(flushed, isFalse);
    gate.complete();
    await flush;

    expect(flushed, isTrue);
    expect(store.durable, [latest]);
  });
}

class _ControlledDelay {
  final List<Completer<void>> _pending = [];

  Future<void> call(Duration _) {
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }

  void elapseNext() => _pending.removeAt(0).complete();

  void elapseAll() {
    for (final completer in _pending.toList()) {
      completer.complete();
    }
    _pending.clear();
  }
}

class _FakeThemePresetStore implements ThemePresetStore {
  _FakeThemePresetStore(this.durable);

  List<ThemePreset> durable;
  final List<ThemePreset> saveCalls = [];
  final List<Completer<void>> _saveGates = [];

  Completer<void> gateNextSave() {
    final gate = Completer<void>();
    _saveGates.add(gate);
    return gate;
  }

  @override
  Future<void> saveAll(List<ThemePreset> presets) async {
    final snapshot = List<ThemePreset>.of(presets);
    saveCalls.add(snapshot.single);
    if (_saveGates.isNotEmpty) await _saveGates.removeAt(0).future;
    durable = snapshot;
  }

  @override
  Future<List<ThemePreset>> loadAll() async => List<ThemePreset>.of(durable);

  @override
  Future<String> loadActiveId() async => durable.first.id;

  @override
  Future<void> addPreset(ThemePreset preset) async =>
      durable = [...durable, preset];

  @override
  Future<void> removePreset(String id) async =>
      durable = durable.where((preset) => preset.id != id).toList();

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<ThemePreset> importFromFile(String path) => throw UnimplementedError();
}
