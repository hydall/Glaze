import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/api_config.dart';
import '../../core/llm/embedding_request_gate.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';

/// SharedPreferences key holding the preset the embedding side runs on.
const kActiveEmbeddingConfigIdKey = 'activeEmbeddingConfigId';

final activeApiPresetIdProvider = StateProvider<String?>((ref) => null);

/// The preset the embedding side runs on — picked on the API screen's
/// Embeddings tab and stored apart from [activeApiPresetIdProvider].
///
/// Embeddings are a connection of their own: switching the chat preset must
/// never drag the vector index onto another endpoint, because every stored
/// vector is tied to the model that produced it. The single remaining link
/// between the two selections is this preset's "Use LLM API" toggle, which
/// `resolveEmbeddingConfig` reads to borrow the *active LLM* endpoint.
final activeEmbeddingPresetIdProvider = StateProvider<String?>((ref) => null);

final _activeIdInitializedProvider = Provider<bool>((ref) => false);

final activeApiConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(apiListProvider).value;
  final id = ref.watch(activeApiPresetIdProvider);
  if (list == null || list.isEmpty) return null;
  if (id == null) return list.first;
  return list.firstWhere((c) => c.id == id, orElse: () => list.first);
});

/// The preset every embedding request reads its settings from. Mirrors
/// [activeApiConfigProvider], but follows [activeEmbeddingPresetIdProvider] so
/// the two selections move independently.
final activeEmbeddingConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(apiListProvider).value;
  final id = ref.watch(activeEmbeddingPresetIdProvider);
  if (list == null || list.isEmpty) return null;
  if (id == null) return list.first;
  return list.firstWhere((c) => c.id == id, orElse: () => list.first);
});

final apiListProvider = AsyncNotifierProvider<ApiListNotifier, List<ApiConfig>>(
  ApiListNotifier.new,
);

class ApiListNotifier extends AsyncNotifier<List<ApiConfig>> {
  @override
  Future<List<ApiConfig>> build() async {
    final configs = await ref.watch(apiConfigRepoProvider).getAll();
    final initialized = ref.read(_activeIdInitializedProvider);
    if (!initialized) {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final savedId = prefs.getString('activeApiConfigId');
      if (savedId != null && configs.any((c) => c.id == savedId)) {
        ref.read(activeApiPresetIdProvider.notifier).state = savedId;
      }
      await _restoreEmbeddingSelection(prefs, configs, savedId);
    }
    return configs;
  }

  /// Restores the embedding preset selection — and seeds it on the first run
  /// after embeddings got a selection of their own.
  ///
  /// Embeddings used to simply follow the chat preset, so an upgrade pins them
  /// to the preset they were already running on (the saved chat one, or the
  /// first) rather than letting them keep following whatever the chat side is
  /// switched to next. A stored id pointing at a deleted preset is re-seeded
  /// the same way.
  Future<void> _restoreEmbeddingSelection(
    SharedPreferences prefs,
    List<ApiConfig> configs,
    String? savedChatId,
  ) async {
    if (configs.isEmpty) return;
    final savedId = prefs.getString(kActiveEmbeddingConfigIdKey);
    if (savedId != null && configs.any((c) => c.id == savedId)) {
      ref.read(activeEmbeddingPresetIdProvider.notifier).state = savedId;
      return;
    }
    final seed = savedChatId != null && configs.any((c) => c.id == savedChatId)
        ? savedChatId
        : configs.first.id;
    ref.read(activeEmbeddingPresetIdProvider.notifier).state = seed;
    await prefs.setString(kActiveEmbeddingConfigIdKey, seed);
  }

  Future<void> put(ApiConfig config) async {
    await ref.read(apiConfigRepoProvider).put(config);
    ref.invalidateSelf();
  }

  /// Writes several presets in one go, reloading the list once at the end.
  ///
  /// The API screen edits two presets at a time (the LLM one and, when they
  /// differ, the embedding one); saving them through [put] twice would reload
  /// the list — and flash the screen's loading state — twice per keystroke.
  Future<void> putAll(Iterable<ApiConfig> configs) async {
    final repo = ref.read(apiConfigRepoProvider);
    for (final config in configs) {
      await repo.put(config);
    }
    ref.invalidateSelf();
  }

  void setEmbeddingEnabled(String id, bool enabled) {
    // The gate is global, so only the preset the embedding side actually runs
    // on may open or close it.
    if (id == ref.read(activeEmbeddingConfigProvider)?.id) {
      EmbeddingRequestGate.setEnabled(enabled);
    }
    final configs = state.value;
    if (configs == null) return;
    state = AsyncData([
      for (final config in configs)
        if (config.id == id)
          config.copyWith(embeddingEnabled: enabled)
        else
          config,
    ]);
  }

  Future<void> remove(String id) async {
    await ref.read(apiConfigRepoProvider).delete(id);
    await SyncDeletionTracker.record('api_presets', id);
    ref.invalidateSelf();
  }
}
