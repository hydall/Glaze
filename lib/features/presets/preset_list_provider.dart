import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/preset.dart';
import '../../core/services/featured_presets.dart';
import '../../core/services/preset_image_paths.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/sync_deletion_tracker.dart';
import '../../core/utils/time_helpers.dart';

final presetListProvider =
    AsyncNotifierProvider<PresetListNotifier, List<Preset>>(
      PresetListNotifier.new,
    );

class PresetListNotifier extends AsyncNotifier<List<Preset>> {
  @override
  Future<List<Preset>> build() async {
    final presets = await ref.watch(presetRepoProvider).getAll();
    return _applyOrder(presets);
  }

  Future<void> add(Preset preset) async {
    await ref.read(presetRepoProvider).put(preset);
    ref.invalidateSelf();
  }

  Future<void> updatePreset(Preset preset) async {
    await ref.read(presetRepoProvider).put(preset);
    ref.invalidateSelf();
  }

  Future<Preset?> getPresetById(String id) async {
    return ref.read(presetRepoProvider).getById(id);
  }

  /// Creates an independent copy of [preset] with a fresh id and a "(copy)"
  /// suffixed name. Blocks and regexes are carried over unchanged (their ids
  /// are scoped to the owning preset). Returns the new preset.
  Future<Preset> clone(Preset preset) async {
    final newId = generateId();
    final copy = preset.copyWith(
      id: newId,
      name: '${preset.name} (copy)',
      // A featured preset resolves its cover from its fixed id, which the copy
      // no longer has — pin the bundled asset so the clone keeps the artwork.
      imagePath:
          await _copyCoverForClone(preset.imagePath, newId) ??
          featuredPresetImageAsset(preset.id),
      createdAt: currentTimestampSeconds(),
    );
    await ref.read(presetRepoProvider).put(copy);
    ref.invalidateSelf();
    return copy;
  }

  /// Gives the clone its own copy of a file-based cover, so that replacing or
  /// removing the image on either preset cannot delete the other's file.
  /// Bundled asset covers are shared as-is (there is no file to own), and a
  /// failed copy falls back to sharing the source path rather than dropping the
  /// artwork.
  Future<String?> _copyCoverForClone(String? sourcePath, String newId) async {
    if (sourcePath == null || sourcePath.isEmpty) return null;
    if (isPresetAssetImage(sourcePath)) return sourcePath;
    try {
      final storage = await ref.read(imageStorageProvider.future);
      final abs = storage.absolutePath(sourcePath);
      if (abs == null) return sourcePath;
      final file = File(abs);
      if (!await file.exists()) return sourcePath;
      final storageId = presetImageStorageId(newId, currentTimestampSeconds());
      await storage.saveAvatar(storageId, await file.readAsBytes());
      return presetImageRelativePath(storageId, 'png');
    } catch (_) {
      return sourcePath;
    }
  }

  Future<void> remove(String id) async {
    await ref.read(presetRepoProvider).delete(id);
    await SyncDeletionTracker.record('theme_presets', id);
    ref.invalidateSelf();
  }

  Future<List<Preset>> _applyOrder(List<Preset> presets) async {
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final raw = prefs.getString('presetOrder');
      if (raw == null) return presets;
      final order = (jsonDecode(raw) as List).cast<String>();
      if (order.isEmpty) return presets;
      final orderMap = <String, int>{};
      for (int i = 0; i < order.length; i++) {
        orderMap[order[i]] = i;
      }
      final sorted = List<Preset>.from(presets)..sort((a, b) {
        final ai = orderMap[a.id] ?? 999999;
        final bi = orderMap[b.id] ?? 999999;
        return ai.compareTo(bi);
      });
      return sorted;
    } catch (_) {
      return presets;
    }
  }
}
