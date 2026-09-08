import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks how many successful chat generations the user has run per model.
///
/// Feeds the "Top Models" block in the global (General) statistics. Persisted
/// as a single JSON map `{model: count}` in SharedPreferences so it survives
/// restarts without a schema/migration. Writes are serialized through an
/// internal chain so two near-simultaneous generations can't clobber each
/// other's read-modify-write.
class ModelUsageService {
  static const String prefsKey = 'model_usage_counts';

  Future<void> _writeChain = Future<void>.value();

  /// Increment the usage counter for [model] by one. No-op for blank models.
  Future<void> recordModelUse(String model) {
    final trimmed = model.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    _writeChain = _writeChain.then((_) => _increment(trimmed));
    return _writeChain;
  }

  Future<void> _increment(String model) async {
    final prefs = await SharedPreferences.getInstance();
    final counts = _decode(prefs.getString(prefsKey));
    counts[model] = (counts[model] ?? 0) + 1;
    await prefs.setString(prefsKey, jsonEncode(counts));
  }

  /// All recorded model usage counts, unsorted. Empty when nothing tracked yet.
  Future<Map<String, int>> getUsageCounts() async {
    final prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(prefsKey));
  }

  Map<String, int> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), (v is num) ? v.toInt() : 0),
        );
      }
    } catch (_) {
      // Corrupt value — treat as empty rather than crashing the stats sheet.
    }
    return <String, int>{};
  }
}

final modelUsageServiceProvider = Provider<ModelUsageService>(
  (ref) => ModelUsageService(),
);
