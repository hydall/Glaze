import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/cleaner_settings.dart';
import '../models/ledger_settings.dart';
import '../models/memory_book_api_settings.dart';
import '../models/memory_pipeline_settings.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_agent_settings.dart';
import 'shared_prefs_provider.dart';

/// Global pipeline LLM settings, persisted in SharedPreferences under the
/// 'pipelineSettings' key. Loaded once at startup. This is a singleton global —
/// the same [PipelineSettings] instance applies to every chat session.
///
/// The JSON format changed from flat (all fields at the root level) to nested
/// (fields grouped under `studioAgent`, `cleaner`, `ledger`, `memoryPipeline`,
/// `memoryBookApi` sub-objects). The [load] method handles both formats
/// idempotently — flat JSON is migrated to nested on first load and persisted
/// back so subsequent loads read the nested format directly.
final pipelineSettingsProvider =
    StateNotifierProvider<PipelineSettingsNotifier, PipelineSettings>(
      (ref) => PipelineSettingsNotifier(ref),
    );

class PipelineSettingsNotifier extends StateNotifier<PipelineSettings> {
  final Ref _ref;
  PipelineSettingsNotifier(this._ref) : super(const PipelineSettings());

  Future<void> load() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final raw = prefs.getString('pipelineSettings');
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        state = _parseSettingsJson(json);
        // Persist back if migration occurred (flat → nested).
        final encoded = jsonEncode(state.toJson());
        if (encoded != raw) {
          await prefs.setString('pipelineSettings', encoded);
        }
      } catch (_) {}
    }
  }

  Future<void> save(PipelineSettings settings) async {
    state = settings;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString('pipelineSettings', jsonEncode(settings.toJson()));
  }

  /// Parses the SharedPreferences JSON into [PipelineSettings], handling both
  /// the new nested format and the legacy flat format.
  ///
  /// **Nested format** (current): JSON has `studioAgent`, `cleaner`, `ledger`,
  /// `memoryPipeline`, `memoryBookApi` sub-objects — parsed directly via
  /// [PipelineSettings.fromJson].
  ///
  /// **Flat format** (legacy): All fields at the root level. Each sub-model's
  /// `fromJson` picks up its own fields from the flat map and uses `@Default`
  /// values for the rest — extra keys are silently ignored. The legacy
  /// `sidecar*` → `aux*` rename is applied first.
  PipelineSettings _parseSettingsJson(Map<String, dynamic> json) {
    // Already nested — parse directly.
    if (json.containsKey('studioAgent')) {
      return PipelineSettings.fromJson(json);
    }

    // Legacy flat format — migrate sidecar → aux, then partition into
    // sub-models. Each sub-model's fromJson reads only its own fields from
    // the flat map; unknown keys are ignored by freezed's generated decoder.
    final migrated = _migrateLegacySidecarJson(json);
    return PipelineSettings(
      studioAgent: StudioAgentSettings.fromJson(migrated),
      cleaner: CleanerSettings.fromJson(migrated),
      ledger: LedgerSettings.fromJson(migrated),
      memoryPipeline: MemoryPipelineSettings.fromJson(migrated),
      memoryBookApi: MemoryBookApiSettings.fromJson(migrated),
    );
  }

  /// Migrates very old installs that use `sidecar*` keys to the current
  /// `aux*` naming. Idempotent — uses `putIfAbsent` so already-migrated JSON
  /// is untouched.
  Map<String, dynamic> _migrateLegacySidecarJson(Map<String, dynamic> json) {
    final migrated = Map<String, dynamic>.from(json);
    migrated.putIfAbsent('auxSource', () => migrated['sidecarSource']);
    migrated.putIfAbsent('auxModel', () => migrated['sidecarModel']);
    migrated.putIfAbsent('auxEndpoint', () => migrated['sidecarEndpoint']);
    migrated.putIfAbsent('auxApiKey', () => migrated['sidecarApiKey']);
    migrated.putIfAbsent('auxTimeoutMs', () => migrated['sidecarTimeoutMs']);
    return migrated;
  }
}
