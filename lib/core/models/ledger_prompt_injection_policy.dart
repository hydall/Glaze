import 'ledger_prompt_injection_mode.dart';

const ledgerPromptInjectionPolicyIdentity = 'ledger-prompt-injection';
const ledgerPromptInjectionAlgorithmVersion = 'ledger-gap-filler-v1';

const disabledLedgerPromptInjectionPolicy = LedgerPromptInjectionPolicy(
  presetOptIn: false,
  mode: LedgerPromptInjectionMode.disabled,
);

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
