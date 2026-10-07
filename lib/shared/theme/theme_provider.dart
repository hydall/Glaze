import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'theme_preset.dart';
import 'theme_preset_storage.dart';

const _kDefaultPresetId = 'default';
const _kDefaultPreset = ThemePreset(id: _kDefaultPresetId, name: 'Default');

/// Theme state. [selectedPresetId] is the theme picked in the theme list;
/// while [followSystem] is on, the slot for the device brightness overrides
/// it. [activePreset] is the one that ends up on screen.
class ThemeSettings {
  final bool followSystem;

  /// The device brightness.
  final Brightness platformBrightness;
  final String selectedPresetId;
  final String lightPresetId;
  final String darkPresetId;
  final Color accentColor;
  final ThemePreset activePreset;
  final List<ThemePreset> presets;
  final bool ignoreCustomFont;

  const ThemeSettings({
    this.followSystem = false,
    this.platformBrightness = Brightness.dark,
    this.selectedPresetId = _kDefaultPresetId,
    this.lightPresetId = _kDefaultPresetId,
    this.darkPresetId = _kDefaultPresetId,
    this.accentColor = const Color(0xFFC42A4A),
    this.activePreset = _kDefaultPreset,
    this.presets = const [_kDefaultPreset],
    this.ignoreCustomFont = false,
  });

  /// The brightness the app renders in: the active theme's own type. The
  /// built-ins have no editable type, so they follow the device while the
  /// slots do and stay dark otherwise, as they always have.
  Brightness get brightness {
    if (activePreset.isBuiltIn) {
      return followSystem ? platformBrightness : Brightness.dark;
    }
    return activePreset.brightnessOn(platformBrightness);
  }

  bool get isDark => brightness == Brightness.dark;

  String slotPresetId(Brightness slot) =>
      slot == Brightness.dark ? darkPresetId : lightPresetId;

  ThemePreset slotPreset(Brightness slot) =>
      _presetOrDefault(presets, slotPresetId(slot));

  ThemeSlots get slots => ThemeSlots(
    followSystem: followSystem,
    lightPresetId: lightPresetId,
    darkPresetId: darkPresetId,
  );

  ThemeSettings copyWith({
    bool? followSystem,
    Brightness? platformBrightness,
    String? selectedPresetId,
    String? lightPresetId,
    String? darkPresetId,
    Color? accentColor,
    ThemePreset? activePreset,
    List<ThemePreset>? presets,
    bool? ignoreCustomFont,
  }) => ThemeSettings(
    followSystem: followSystem ?? this.followSystem,
    platformBrightness: platformBrightness ?? this.platformBrightness,
    selectedPresetId: selectedPresetId ?? this.selectedPresetId,
    lightPresetId: lightPresetId ?? this.lightPresetId,
    darkPresetId: darkPresetId ?? this.darkPresetId,
    accentColor: accentColor ?? this.accentColor,
    activePreset: activePreset ?? this.activePreset,
    presets: presets ?? this.presets,
    ignoreCustomFont: ignoreCustomFont ?? this.ignoreCustomFont,
  );
}

ThemePreset _presetOrDefault(List<ThemePreset> presets, String id) {
  ThemePreset? fallback;
  for (final p in presets) {
    if (p.id == id) return p;
    if (p.id == _kDefaultPresetId) fallback = p;
  }
  return fallback ?? (presets.isEmpty ? _kDefaultPreset : presets.first);
}

class ThemeNotifier extends StateNotifier<ThemeSettings> {
  ThemePresetStore? _storage;
  final Future<ThemePresetStore> Function() _storageFactory;
  final Duration _persistenceDebounce;
  final Future<void> Function(Duration) _delay;
  final Completer<void> _ready = Completer<void>();
  Future<void> _writeTail = Future<void>.value();
  List<ThemePreset>? _pendingPresets;
  Object? _persistenceError;
  StackTrace? _persistenceErrorStack;
  Object? _initializationError;
  StackTrace? _initializationErrorStack;
  int _debounceEpoch = 0;
  bool _disposed = false;

  ThemeNotifier({
    ThemePresetStore? storage,
    Future<ThemePresetStore> Function()? storageFactory,
    this._persistenceDebounce = const Duration(milliseconds: 300),
    Future<void> Function(Duration)? delay,
    Brightness? platformBrightness,
  }) : assert(storage == null || storageFactory == null),
       _storageFactory =
           storageFactory ??
           (storage != null
               ? (() async => storage)
               : ThemePresetStorage.create),
       _delay = delay ?? Future<void>.delayed,
       super(
         ThemeSettings(
           platformBrightness:
               platformBrightness ??
               PlatformDispatcher.instance.platformBrightness,
         ),
       ) {
    _init();
  }

  Future<void> _init() async {
    try {
      _storage = await _storageFactory();
      if (_disposed) return;
      await _load();
    } catch (error, stackTrace) {
      _initializationError = error;
      _initializationErrorStack = stackTrace;
    } finally {
      _ready.complete();
    }
  }

  Future<void> _awaitReady() async {
    await _ready.future;
    final error = _initializationError;
    if (error != null) {
      Error.throwWithStackTrace(error, _initializationErrorStack!);
    }
  }

  Future<void> _load() async {
    final storage = _storage;
    if (storage == null) return;
    final presets = await storage.loadAll();
    final activeId = await storage.loadActiveId();
    final slots = await storage.loadSlots();
    if (_disposed) return;
    state = _resolve(
      state.copyWith(
        presets: presets,
        selectedPresetId: activeId,
        followSystem: slots?.followSystem ?? false,
        // Until the slots are first set, both start on the current theme.
        lightPresetId: slots?.lightPresetId ?? activeId,
        darkPresetId: slots?.darkPresetId ?? activeId,
      ),
    );
  }

  ThemeSettings _resolve(ThemeSettings s) {
    final id = s.followSystem
        ? s.slotPresetId(s.platformBrightness)
        : s.selectedPresetId;
    final active = _presetOrDefault(s.presets, id);
    return s.copyWith(activePreset: active, accentColor: active.accent);
  }

  Future<void> _saveSlots() =>
      _sequenceWrite(() => _storage!.saveSlots(state.slots));

  /// Fed by the app root whenever the device switches light/dark.
  void setPlatformBrightness(Brightness brightness) {
    if (_disposed || brightness == state.platformBrightness) return;
    state = _resolve(state.copyWith(platformBrightness: brightness));
  }

  Future<void> setFollowSystem(bool value) async {
    await _awaitReady();
    if (_disposed) return;
    state = _resolve(state.copyWith(followSystem: value));
    await _saveSlots();
  }

  /// Picks the theme for the device's light or dark mode.
  Future<void> setSlotPreset(Brightness slot, String id) async {
    await _awaitReady();
    if (_disposed) return;
    state = _resolve(
      slot == Brightness.dark
          ? state.copyWith(darkPresetId: id)
          : state.copyWith(lightPresetId: id),
    );
    await _saveSlots();
  }

  Future<void> setAccentColor(Color color) async {
    state = state.copyWith(accentColor: color);
  }

  /// Shows [preset]. While following the device it goes into the slot of the
  /// current device brightness, so the tap is never a no-op.
  Future<void> applyPreset(ThemePreset preset) async {
    await _awaitReady();
    if (_disposed) return;
    var next = state.copyWith(selectedPresetId: preset.id);
    if (next.followSystem) {
      next = state.platformBrightness == Brightness.dark
          ? next.copyWith(darkPresetId: preset.id)
          : next.copyWith(lightPresetId: preset.id);
    }
    state = _resolve(next);
    await _sequenceWrite(() => _storage!.setActive(preset.id));
    if (state.followSystem) await _saveSlots();
  }

  /// Back to the factory theme: Default, without following the device.
  Future<void> resetToDefault() async {
    await _awaitReady();
    if (_disposed) return;
    state = _resolve(
      state.copyWith(
        followSystem: false,
        selectedPresetId: _kDefaultPresetId,
        lightPresetId: _kDefaultPresetId,
        darkPresetId: _kDefaultPresetId,
      ),
    );
    await _sequenceWrite(() => _storage!.setActive(_kDefaultPresetId));
    await _saveSlots();
  }

  Future<void> importPreset(ThemePreset preset) async {
    await _awaitReady();
    await flushPersistence();
    await _sequenceWrite(() => _storage!.addPreset(preset));
    final presets = await _storage!.loadAll();
    if (_disposed) return;
    state = _resolve(state.copyWith(presets: presets));
  }

  Future<ThemePreset?> importPresetFromFile(
    String path, {
    bool apply = true,
  }) async {
    await _awaitReady();
    final preset = await _storage!.importFromFile(path);
    await importPreset(preset);
    if (apply) {
      await applyPreset(preset);
    }
    return preset;
  }

  Future<void> deletePreset(String id) async {
    await _awaitReady();
    await flushPersistence();
    await _sequenceWrite(() => _storage!.removePreset(id));
    final presets = await _storage!.loadAll();
    if (_disposed) return;
    String keep(String slotId) => slotId == id ? _kDefaultPresetId : slotId;
    state = _resolve(
      state.copyWith(
        presets: presets,
        selectedPresetId: keep(state.selectedPresetId),
        lightPresetId: keep(state.lightPresetId),
        darkPresetId: keep(state.darkPresetId),
      ),
    );
    await _saveSlots();
  }

  /// Live-update the active preset and persist it (mirrors JS auto-save on change).
  Future<void> updatePreset(ThemePreset preset) {
    if (!_ready.isCompleted) return _updatePresetWhenReady(preset);
    final error = _initializationError;
    if (error != null) {
      return Future<void>.error(error, _initializationErrorStack);
    }
    if (_disposed) return Future<void>.value();
    _previewAndSchedulePreset(preset);
    return Future<void>.value();
  }

  Future<void> _updatePresetWhenReady(ThemePreset preset) async {
    await _awaitReady();
    if (_disposed) return;
    _previewAndSchedulePreset(preset);
  }

  void _previewAndSchedulePreset(ThemePreset preset) {
    final updated = state.presets
        .map((p) => p.id == preset.id ? preset : p)
        .toList();
    state = _resolve(state.copyWith(presets: updated));
    _pendingPresets = updated;
    final epoch = ++_debounceEpoch;
    unawaited(_persistAfterDebounce(epoch));
  }

  Future<void> _persistAfterDebounce(int epoch) async {
    try {
      await _delay(_persistenceDebounce);
    } catch (error, stackTrace) {
      _recordPersistenceError(error, stackTrace);
      return;
    }
    if (_disposed || epoch != _debounceEpoch) return;
    _enqueuePendingPresets();
  }

  void _enqueuePendingPresets() {
    final presets = _pendingPresets;
    if (presets == null) return;
    _pendingPresets = null;
    unawaited(
      _sequenceWrite(() => _storage!.saveAll(presets)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _recordPersistenceError(error, stackTrace);
      }),
    );
  }

  Future<T> _sequenceWrite<T>(Future<T> Function() write) {
    final result = _writeTail.then((_) => write());
    _writeTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _recordPersistenceError(Object error, StackTrace stackTrace) {
    _persistenceError = error;
    _persistenceErrorStack = stackTrace;
  }

  /// Persists the latest preview immediately and waits for all prior writes.
  Future<void> flushPersistence() async {
    await _awaitReady();
    ++_debounceEpoch;
    _enqueuePendingPresets();
    await _writeTail;
    final error = _persistenceError;
    if (error != null) {
      final stackTrace = _persistenceErrorStack!;
      _persistenceError = null;
      _persistenceErrorStack = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> reload() async {
    await flushPersistence();
    await _load();
  }

  void setIgnoreCustomFont(bool value) {
    state = state.copyWith(ignoreCustomFont: value);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_debounceEpoch;
    _pendingPresets = null;
    super.dispose();
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeSettings>(
  (ref) => ThemeNotifier(),
);
