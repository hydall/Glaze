import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/models/api_config.dart';
import '../../core/llm/embedding_request_gate.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';

final activeApiPresetIdProvider = StateProvider<String?>((ref) => null);

final _activeIdInitializedProvider = Provider<bool>((ref) => false);

final activeApiConfigProvider = Provider<ApiConfig?>((ref) {
  final list = ref.watch(apiListProvider).value;
  final id = ref.watch(activeApiPresetIdProvider);
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
    }
    return configs;
  }

  Future<void> put(ApiConfig config) async {
    await ref.read(apiConfigRepoProvider).put(config);
    ref.invalidateSelf();
  }

  void setEmbeddingEnabled(String id, bool enabled) {
    EmbeddingRequestGate.setEnabled(enabled);
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
