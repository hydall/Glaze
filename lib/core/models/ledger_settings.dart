import 'package:freezed_annotation/freezed_annotation.dart';

part 'ledger_settings.freezed.dart';
part 'ledger_settings.g.dart';

/// Studio Ledger settings — cadence, temperature, and token limits for the
/// mandatory internal continuity ledger.
///
/// Nested inside [PipelineSettings] under the `ledger` field. The ledger is
/// always-on when Studio is enabled — there is no enabled toggle.
/// Model/endpoint/apiKey overrides are removed — the ledger uses the Studio
/// cleaner slot (semi-expensive) via `StudioSlotResolver` (Phase 3).
@freezed
abstract class LedgerSettings with _$LedgerSettings {
  const factory LedgerSettings({
    @Default(0) int studioLedgerTimeoutMs,
    // Max tokens for the ledger LLM call. 0 = use default (2000).
    @Default(0) int studioLedgerMaxTokens,
    // Temperature for the ledger LLM call. Negative = use default (0.2).
    @Default(-1.0) double studioLedgerTemperature,
    // ── Cadence ───────────────────────────────────────────────────────────
    // Run mode: 'every_turn' | 'conditional' | 'every_n' | 'manual' |
    // 'disabled'. 'every_turn' is the default. Studio forces it on regardless
    // of this setting when StudioConfig.enabled is true; this field is only
    // consulted for non-Studio generations or when the user opts into a
    // low-power cadence inside Studio.
    @Default('every_turn') String studioLedgerRunMode,
    // Interval N assistant turns when runMode == 'every_n'. 1 = every turn.
    @Default(1) int studioLedgerIntervalN,
    // Conditional trigger — only consulted when runMode == 'conditional'.
    @Default(true) bool studioLedgerRunWhenMentionedEntitiesChanged,
  }) = _LedgerSettings;

  factory LedgerSettings.fromJson(Map<String, dynamic> json) =>
      _$LedgerSettingsFromJson(json);
}
