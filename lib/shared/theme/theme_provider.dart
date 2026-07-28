import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'theme_preset.dart';
import 'theme_preset_storage.dart';

class ThemeSettings {
  final ThemeMode mode;
  final Color accentColor;
  final ThemePreset activePreset;
  final List<ThemePreset> presets;
  final bool ignoreCustomFont;

  const ThemeSettings({
    this.mode = ThemeMode.dark,
    this.accentColor = const Color(0xFF7996CE),
    this.activePreset = const ThemePreset(id: 'default', name: 'Default'),
    this.presets = const [ThemePreset(id: 'default', name: 'Default')],
    this.ignoreCustomFont = false,
  });

  ThemeSettings copyWith({
    ThemeMode? mode,
    Color? accentColor,
    ThemePreset? activePreset,
    List<ThemePreset>? presets,
    bool? ignoreCustomFont,
  }) => ThemeSettings(
    mode: mode ?? this.mode,
    accentColor: accentColor ?? this.accentColor,
    activePreset: activePreset ?? this.activePreset,
    presets: presets ?? this.presets,
    ignoreCustomFont: ignoreCustomFont ?? this.ignoreCustomFont,
  );
}

class ThemeNotifier extends StateNotifier<ThemeSettings> {
  ThemePresetStorage? _storage;
  final Completer<void> _ready = Completer<void>();

  ThemeNotifier() : super(const ThemeSettings()) {
    _init();
  }

  Future<void> _init() async {
    try {
      _storage = await ThemePresetStorage.create();
      await _load();
    } finally {
      _ready.complete();
    }
  }

  Future<void> _load() async {
    if (_storage == null) return;
    final presets = await _storage!.loadAll();
    final activeId = await _storage!.loadActiveId();
    final active = presets.firstWhere(
      (p) => p.id == activeId,
      orElse: () => presets.first,
    );
    state = ThemeSettings(
      mode: state.mode,
      accentColor: active.accent,
      activePreset: active,
      presets: presets,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
  }

  Future<void> setAccentColor(Color color) async {
    state = state.copyWith(accentColor: color);
  }

  Future<void> applyPreset(ThemePreset preset) async {
    await _ready.future;
    state = state.copyWith(accentColor: preset.accent, activePreset: preset);
    await _storage?.setActive(preset.id);
  }

  Future<void> importPreset(ThemePreset preset) async {
    await _ready.future;
    await _storage?.addPreset(preset);
    final presets = await _storage?.loadAll() ?? state.presets;
    state = state.copyWith(presets: presets);
  }

  Future<ThemePreset?> importPresetFromFile(
    String path, {
    bool apply = true,
  }) async {
    final preset = await _storage?.importFromFile(path);
    if (preset == null) return null;
    await importPreset(preset);
    if (apply) {
      await applyPreset(preset);
    }
    return preset;
  }

  Future<void> deletePreset(String id) async {
    await _ready.future;
    await _storage?.removePreset(id);
    final presets = await _storage?.loadAll() ?? state.presets;
    var active = state.activePreset;
    if (active.id == id) {
      active = presets.first;
    }
    state = state.copyWith(
      presets: presets,
      activePreset: active,
      accentColor: active.accent,
    );
  }

  /// Live-update the active preset and persist it (mirrors JS auto-save on change).
  Future<void> updatePreset(ThemePreset preset) async {
    await _ready.future;
    final updated = state.presets
        .map((p) => p.id == preset.id ? preset : p)
        .toList();
    state = state.copyWith(
      activePreset: preset,
      accentColor: preset.accent,
      presets: updated,
    );
    await _storage?.saveAll(updated);
  }

  Future<void> reload() async {
    await _load();
  }

  void setIgnoreCustomFont(bool value) {
    state = state.copyWith(ignoreCustomFont: value);
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeSettings>(
  (ref) => ThemeNotifier(),
);
