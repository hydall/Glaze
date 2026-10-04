import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/studio_config.dart';
import 'db_provider.dart';

/// Global singleton for the active Studio preset.
///
/// The value is loaded before consumers continue via
/// `ref.read(activeStudioPresetProvider.future)`, so generation cannot briefly
/// fall back to `default` while SharedPreferences is still loading.
const activeStudioPresetKey = 'activeStudioPresetId';

final activeStudioPresetProvider =
    AsyncNotifierProvider<ActiveStudioPresetNotifier, String>(
      ActiveStudioPresetNotifier.new,
    );

class ActiveStudioPresetNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    // Opening the DB runs schema migration 67, which copies the latest legacy
    // per-session preset into SharedPreferences before dropping that column.
    final db = ref.read(appDbProvider);
    await db.customSelect('SELECT 1').getSingle();
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(activeStudioPresetKey) ?? 'default';
  }

  Future<void> set(String presetId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activeStudioPresetKey, presetId);
    state = AsyncData(presetId);
  }
}

/// The Studio preset a turn actually runs: the one [activeStudioPresetProvider]
/// names, falling back to the seeded `default` row when that id no longer
/// resolves.
///
/// This must mirror `StudioTurnConfigResolver.resolve` exactly. Anything that
/// reads or writes a preset's API slots (`cheapApiConfigId`,
/// `expensiveApiConfigId`, `cleanerApiConfigId`, `ledgerApiConfigId`) has to go
/// through the same preset generation reads — editing `default` while a turn
/// runs a different preset silently drops the binding, leaving the global model
/// override pointed at whatever connection the turn falls back to.
final studioPresetProvider = FutureProvider<StudioPreset?>((ref) async {
  final repo = ref.watch(studioPresetRepoProvider);
  final activeId = await ref.watch(activeStudioPresetProvider.future);
  return await repo.getById(activeId) ?? await repo.getDefault();
});
