import 'ledger_prompt_injection_mode.dart';
import 'studio_config.dart';

const ledgerPromptInjectionPolicyIdentity = 'ledger-prompt-injection';
const ledgerPromptInjectionHeaderId = 'loom_ledger_context_group_v1';
const ledgerPromptInjectionHeaderTitle = '━📒 Ledger Context';
const ledgerPromptInjectionAlgorithmVersion = 'ledger-gap-filler-v1';

const disabledLedgerPromptInjectionPolicy = LedgerPromptInjectionPolicy(
  presetOptIn: false,
  mode: LedgerPromptInjectionMode.disabled,
);

const ledgerGapFillerTargetPresetIds = <String>{
  'loom_adapt_v1_direct_lite_native_ru_baseline',
  'loom_adapt_v1_direct_lite_anime_ru_test',
};

final class LedgerPromptInjectionPolicy {
  const LedgerPromptInjectionPolicy({
    required this.presetOptIn,
    required this.mode,
    this.algorithmVersion = ledgerPromptInjectionAlgorithmVersion,
    this.reverseScanDepth = 40,
  });

  final bool presetOptIn;
  final LedgerPromptInjectionMode mode;
  final String algorithmVersion;
  final int reverseScanDepth;

  /// A preset opt-out is authoritative regardless of the requested mode.
  LedgerPromptInjectionMode get effectiveMode =>
      presetOptIn ? mode : LedgerPromptInjectionMode.disabled;

  String get identity =>
      '$ledgerPromptInjectionPolicyIdentity/$algorithmVersion/${effectiveMode.name}/${presetOptIn ? 'opt-in' : 'opt-out'}/depth=$reverseScanDepth';

  Map<String, Object?> toJson() =>
      LedgerPromptInjectionPolicyJsonCodec.encode(this);

  factory LedgerPromptInjectionPolicy.fromJson(Map<String, dynamic> json) =>
      LedgerPromptInjectionPolicyJsonCodec.decode(json);

  @override
  bool operator ==(Object other) =>
      other is LedgerPromptInjectionPolicy &&
      other.presetOptIn == presetOptIn &&
      other.mode == mode &&
      other.algorithmVersion == algorithmVersion &&
      other.reverseScanDepth == reverseScanDepth;

  @override
  int get hashCode =>
      Object.hash(presetOptIn, mode, algorithmVersion, reverseScanDepth);
}

abstract final class LedgerPromptInjectionPolicyJsonCodec {
  static Map<String, Object?> encode(LedgerPromptInjectionPolicy policy) => {
    'presetOptIn': policy.presetOptIn,
    'mode': policy.mode.name,
    'algorithmVersion': policy.algorithmVersion,
    'reverseScanDepth': policy.reverseScanDepth,
  };

  static LedgerPromptInjectionPolicy decode(Map<String, dynamic> json) {
    final optedIn = json['presetOptIn'] == true;
    final mode = _mode(json['mode']);
    final version = json['algorithmVersion'];
    final depth = json['reverseScanDepth'];
    if (!optedIn || mode == LedgerPromptInjectionMode.disabled) {
      return disabledLedgerPromptInjectionPolicy;
    }
    if (mode == null || version != ledgerPromptInjectionAlgorithmVersion) {
      return _legacyPolicy(presetOptIn: true);
    }
    return LedgerPromptInjectionPolicy(
      presetOptIn: true,
      mode: mode,
      algorithmVersion: version as String,
      reverseScanDepth: depth is int && depth > 0 ? depth : 40,
    );
  }
}

LedgerPromptInjectionPolicy deriveLedgerPromptInjectionPolicy(
  StudioPreset preset,
) => deriveLedgerPromptInjectionPolicyFromRaw(
  presetId: preset.id,
  rawBlocks: preset.blocks,
  requestedMode: preset.runtime.requestedLedgerPromptInjectionMode,
  requestedAlgorithmVersion:
      preset.runtime.requestedLedgerPromptInjectionAlgorithmVersion,
);

/// Derives policy before group resolution. Any block matching either half of
/// the stable header identity is treated as an attempted known header, so a
/// duplicate or malformed attempt fails to disabled rather than full legacy.
LedgerPromptInjectionPolicy deriveLedgerPromptInjectionPolicyFromRaw({
  required String presetId,
  required List<Object?> rawBlocks,
  LedgerPromptInjectionMode? requestedMode,
  String? requestedAlgorithmVersion,
}) {
  final candidates = rawBlocks
      .where((value) {
        if (value is StudioPresetBlock) {
          return value.id == ledgerPromptInjectionHeaderId ||
              value.title == ledgerPromptInjectionHeaderTitle;
        }
        if (value is Map) {
          return value['id'] == ledgerPromptInjectionHeaderId ||
              value['title'] == ledgerPromptInjectionHeaderTitle ||
              value['name'] == ledgerPromptInjectionHeaderTitle;
        }
        return false;
      })
      .toList(growable: false);

  if (candidates.isEmpty) return _legacyPolicy(presetOptIn: true);
  if (candidates.length != 1) return disabledLedgerPromptInjectionPolicy;

  final candidate = candidates.single;
  late final String? id;
  late final String? title;
  late final Object? enabled;
  if (candidate is StudioPresetBlock) {
    id = candidate.id;
    title = candidate.title;
    enabled = candidate.enabled;
  } else {
    final map = candidate as Map;
    id = map['id'] is String ? map['id'] as String : null;
    final rawTitle = map['title'] ?? map['name'];
    title = rawTitle is String ? rawTitle : null;
    enabled = map['enabled'];
  }
  if (id != ledgerPromptInjectionHeaderId ||
      title != ledgerPromptInjectionHeaderTitle ||
      (enabled != null && enabled is! bool)) {
    return disabledLedgerPromptInjectionPolicy;
  }
  if (enabled == false || requestedMode == LedgerPromptInjectionMode.disabled) {
    return disabledLedgerPromptInjectionPolicy;
  }

  final targetDefault =
      requestedMode == null &&
      ledgerGapFillerTargetPresetIds.contains(presetId);
  final mode = targetDefault
      ? LedgerPromptInjectionMode.gapFiller
      : requestedMode ?? LedgerPromptInjectionMode.legacy;
  final version =
      requestedAlgorithmVersion ??
      (targetDefault ? ledgerPromptInjectionAlgorithmVersion : null);
  if (version != ledgerPromptInjectionAlgorithmVersion) {
    return _legacyPolicy(presetOptIn: true);
  }
  return LedgerPromptInjectionPolicy(presetOptIn: true, mode: mode);
}

LedgerPromptInjectionPolicy _legacyPolicy({required bool presetOptIn}) =>
    LedgerPromptInjectionPolicy(
      presetOptIn: presetOptIn,
      mode: LedgerPromptInjectionMode.legacy,
    );

LedgerPromptInjectionMode? _mode(Object? value) {
  if (value is! String) return null;
  for (final mode in LedgerPromptInjectionMode.values) {
    if (mode.name == value) return mode;
  }
  return null;
}
