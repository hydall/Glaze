import 'dart:convert';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/extensions_settings.dart';

final extensionsSettingsProvider =
    StateNotifierProvider<ExtensionsSettingsNotifier, ExtensionsSettings>(
      (ref) => ExtensionsSettingsNotifier(),
    );

class ExtensionsSettingsNotifier extends StateNotifier<ExtensionsSettings> {
  ExtensionsSettingsNotifier() : super(const ExtensionsSettings()) {
    _load();
  }

  static const _storageKey = 'extensions_settings';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr != null) {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      state = ExtensionsSettings.fromJson(json);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(state.toJson()));
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _save();
  }

  Future<void> setActivePresetId(String? presetId) async {
    // Only update the active preset id. The master enabled flag is
    // controlled separately via setEnabled in Settings → Extensions so
    // users can keep a chosen preset but temporarily disable the feature.
    state = state.copyWith(activePresetId: presetId);
    await _save();
  }

  /// Selects a preset and ensures [enabled] is on if [presetId] is non-null.
  /// Use this from the Ext Blocks sheet so a first-time setup works
  /// without the user having to flip a separate master toggle.
  Future<void> selectPreset(String? presetId) async {
    state = state.copyWith(
      activePresetId: presetId,
      enabled: presetId != null ? true : state.enabled,
    );
    await _save();
  }

  Future<void> update(ExtensionsSettings settings) async {
    state = settings;
    await _save();
  }
}
