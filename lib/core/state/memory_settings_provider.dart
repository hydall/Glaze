import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'shared_prefs_provider.dart';

part 'memory_settings_provider.freezed.dart';
part 'memory_settings_provider.g.dart';

@freezed
abstract class MemoryGlobalSettings with _$MemoryGlobalSettings {
  const factory MemoryGlobalSettings({
    @Default(true) bool enabled,
    @Default('fast') String memoryMode,
    @Default(true) bool autoCreateEnabled,
    @Default(false) bool autoGenerateEnabled,
    @Default(7) int maxInjectedEntries,
    @Default(true) bool memoryExcerptingEnabled,
    @Default('hybrid') String memoryPackingMode,
    @Default(500) int memoryExcerptTokensPerChunk,
    @Default(2) int memoryExcerptChunksPerEntry,
    @Default(3) int chunkFirstTopEntries,
    @Default(1) int chunkFirstTopChunks,
    int? maxInjectedTokens,
    @Default('auto') String memoryBudgetPreset,
    @Default(15) int autoCreateInterval,
    @Default(4) int autoCreateLagMessages,
    @Default(true) bool useDelayedAutomation,
    @Default('hard_block') String injectionTarget,
    @Default(3) int batchSize,
    @Default(1) int parallelJobs,
    @Default(false) bool vectorSearchEnabled,
    @Default(0.6) double vectorThreshold,
    @Default('glaze') String keyMatchMode,
    @Default('detailed_beats') String promptPreset,
    @Default(true) bool diversityAware,
    @Default(0.15) double diversityPenalty,
    @Default(true) bool recencyBoost,
    @Default(100) double recencyHalfLifeDays,
    @Default(true) bool importanceBoost,
    @Default(0.5) double importanceWeight,
    @Default(true) bool sourceWindowExclusion,
    @Default(false) bool factualContinuityGuardEnabled,
    @Default(true) bool queryIncludeAssistant,
    @Default(6) int queryRecentTurns,
    @Default(1500) int queryMaxChars,
    @Default(3) int cadenceInterval,
    @Default(false) bool consolidationEnabled,
    @Default(5) int consolidationThreshold,
    @Default([]) List<Map<String, dynamic>> customPrompts,
  }) = _MemoryGlobalSettings;

  factory MemoryGlobalSettings.fromJson(Map<String, dynamic> json) =>
      _$MemoryGlobalSettingsFromJson(_migrateInjectionTargetInPlace(json));
}

/// Translates the legacy `summary_block` / `summary_macro` enum values
/// (pre-{{memory}}-split) to `hard_block` / `macro` in-place. The old
/// values were misleadingly named because the "summary" prefix was
/// about *where* memory goes, not about the summary feature itself.
Map<String, dynamic> _migrateInjectionTargetInPlace(Map<String, dynamic> json) {
  final raw = json['injectionTarget'];
  if (raw == 'summary_block') {
    return {...json, 'injectionTarget': 'hard_block'};
  }
  if (raw == 'summary_macro') {
    return {...json, 'injectionTarget': 'macro'};
  }
  return json;
}

final memoryGlobalSettingsProvider =
    StateNotifierProvider<MemoryGlobalSettingsNotifier, MemoryGlobalSettings>(
      (ref) => MemoryGlobalSettingsNotifier(ref),
    );

class MemoryGlobalSettingsNotifier extends StateNotifier<MemoryGlobalSettings> {
  final Ref _ref;
  MemoryGlobalSettingsNotifier(this._ref) : super(const MemoryGlobalSettings());

  Future<void> load() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString('memorySettings');
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        state = MemoryGlobalSettings.fromJson(json);
      } catch (_) {}
    }
  }

  Future<void> save(MemoryGlobalSettings settings) async {
    state = settings;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString('memorySettings', jsonEncode(settings.toJson()));
  }
}
