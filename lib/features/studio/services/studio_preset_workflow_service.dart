import '../../../core/application/sync_repo_interfaces.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_validation.dart';
import '../../../core/utils/sync_deletion_tracker.dart';

typedef ActiveStudioPresetReader = Future<String> Function();
typedef ActiveStudioPresetWriter = Future<void> Function(String presetId);
typedef StudioPresetClock = int Function();

class StudioPresetMutationResult {
  final StudioPreset preset;
  final List<StudioPreset> presets;
  final List<StudioPresetValidationIssue> validationIssues;

  const StudioPresetMutationResult({
    required this.preset,
    required this.presets,
    this.validationIssues = const [],
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
      id: await _freeId(now),
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
      id: await _freeId(now),
      name: trimmedName,
      updatedAt: now,
    );
    return _persistAndSelect(preset);
  }

  /// Id for a new preset, derived from the clock but guaranteed not to collide
  /// with an existing one. The clock ticks in seconds, so importing several
  /// files in one go used to hand every preset the same id — each `put`
  /// overwrote the previous one and only the last import survived.
  Future<String> _freeId(int seconds) async {
    final taken = {for (final preset in await _store.getAll()) preset.id};
    var stamp = seconds;
    while (taken.contains('studio_$stamp')) {
      stamp++;
    }
    return 'studio_$stamp';
  }

  Future<List<StudioPreset>> deletePreset(String presetId) async {
    await _store.delete(presetId);
    await SyncDeletionTracker.record('studio_preset', presetId);
    final presets = await loadPresets();
    if (await _readActivePresetId() == presetId) {
      await _writeActivePresetId('default');
    }
    return presets;
  }

  Future<StudioPresetMutationResult> _persistAndSelect(
    StudioPreset preset,
  ) async {
    final validationIssues = StudioPresetValidator.validate(preset);
    if (StudioPresetValidator.hasErrors(validationIssues)) {
      final messages = validationIssues
          .where(
            (issue) => issue.severity == StudioPresetValidationSeverity.error,
          )
          .map((issue) => issue.message)
          .join(' ');
      throw FormatException('Invalid Studio preset: $messages');
    }
    await _store.put(preset);
    final presets = await loadPresets();
    await _writeActivePresetId(preset.id);
    return StudioPresetMutationResult(
      preset: preset,
      presets: presets,
      validationIssues: validationIssues,
    );
  }
}
