import '../../../core/application/sync_repo_interfaces.dart';
import '../../../core/models/studio_config.dart';

typedef ActiveStudioPresetReader = Future<String> Function();
typedef ActiveStudioPresetWriter = Future<void> Function(String presetId);
typedef StudioPresetClock = int Function();

class StudioPresetMutationResult {
  final StudioPreset preset;
  final List<StudioPreset> presets;

  const StudioPresetMutationResult({
    required this.preset,
    required this.presets,
  });
}

/// Coordinates Studio preset persistence and the global active selection.
class StudioPresetWorkflowService {
  final SyncStudioPresetStore _store;
  final ActiveStudioPresetReader _readActivePresetId;
  final ActiveStudioPresetWriter _writeActivePresetId;
  final StudioPresetClock _clock;

  const StudioPresetWorkflowService(
    this._store,
    this._readActivePresetId,
    this._writeActivePresetId,
    this._clock,
  );

  Future<List<StudioPreset>> loadPresets() async {
    final presets = await _store.getAll();
    presets.sort((a, b) => a.name.compareTo(b.name));
    return presets;
  }

  Future<void> selectPreset(String presetId) => _writeActivePresetId(presetId);

  Future<StudioPresetMutationResult?> createPreset({
    required String name,
    required List<StudioPreset> availablePresets,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return null;

    final activePresetId = await _readActivePresetId();
    final source =
        availablePresets
            .where((preset) => preset.id == activePresetId)
            .firstOrNull ??
        availablePresets.firstOrNull;
    if (source == null) return null;

    final now = _clock();
    final preset = source.copyWith(
      id: 'studio_$now',
      name: trimmedName,
      blocks: [...source.blocks],
      agentEnabled: {...source.agentEnabled},
      updatedAt: now,
    );
    return _persistAndSelect(preset);
  }

  Future<StudioPresetMutationResult?> importPreset({
    required StudioPreset imported,
    required String name,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return null;

    final now = _clock();
    final preset = imported.copyWith(
      id: 'studio_$now',
      name: trimmedName,
      updatedAt: now,
    );
    return _persistAndSelect(preset);
  }

  Future<List<StudioPreset>> deletePreset(String presetId) async {
    await _store.delete(presetId);
    final presets = await loadPresets();
    if (await _readActivePresetId() == presetId) {
      await _writeActivePresetId('default');
    }
    return presets;
  }

  Future<StudioPresetMutationResult> _persistAndSelect(
    StudioPreset preset,
  ) async {
    await _store.put(preset);
    final presets = await loadPresets();
    await _writeActivePresetId(preset.id);
    return StudioPresetMutationResult(preset: preset, presets: presets);
  }
}
