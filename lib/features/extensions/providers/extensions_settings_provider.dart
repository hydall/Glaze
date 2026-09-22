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

  Future<void> setActivePresetId(String? presetId) async {
    state = state.copyWith(activePresetId: presetId);
    await _save();
  }

  /// Selects the preset the sheet's controls operate on.
  Future<void> selectPreset(String? presetId) async {
    state = state.copyWith(activePresetId: presetId);
    await _save();
  }

  Future<void> update(ExtensionsSettings settings) async {
    state = settings;
    await _save();
  }
}
