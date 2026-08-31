import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/studio_regex.dart';
import 'shared_prefs_provider.dart';

const studioRegexStorageKey = 'gz_studio_regex_scripts';

class StudioRegexNotifier extends AsyncNotifier<List<StudioRegex>> {
  @override
  Future<List<StudioRegex>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString(studioRegexStorageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (entry) => StudioRegex.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist(List<StudioRegex> entries) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(
      studioRegexStorageKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  Future<void> addRegex(StudioRegex entry) async {
    final updated = [...?state.value, entry];
    state = AsyncData(updated);
    await _persist(updated);
  }

  Future<void> updateRegex(StudioRegex entry) async {
    final updated = [
      for (final current in state.value ?? const <StudioRegex>[])
        if (current.script.id == entry.script.id) entry else current,
    ];
    state = AsyncData(updated);
    await _persist(updated);
  }

  Future<void> removeRegex(String id) async {
    final updated = (state.value ?? const <StudioRegex>[])
        .where((entry) => entry.script.id != id)
        .toList();
    state = AsyncData(updated);
    await _persist(updated);
  }
}

final studioRegexProvider =
    AsyncNotifierProvider<StudioRegexNotifier, List<StudioRegex>>(
      StudioRegexNotifier.new,
    );
