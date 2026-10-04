import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';

void main() {
  Map<String, Object?> header({Object? enabled = true}) => {
    'id': ledgerPromptInjectionHeaderId,
    'title': ledgerPromptInjectionHeaderTitle,
    'enabled': enabled,
  };

  group('raw Ledger policy derivation', () {
    test('no known header preserves legacy behavior', () {
      final policy = deriveLedgerPromptInjectionPolicyFromRaw(
        presetId: 'custom',
        rawBlocks: const [],
      );

      expect(policy.effectiveMode, LedgerPromptInjectionMode.legacy);
      expect(policy.presetOptIn, isTrue);
    });

    test('known enabled target defaults to gap-filler', () {
      final policy = deriveLedgerPromptInjectionPolicyFromRaw(
        presetId: ledgerGapFillerTargetPresetIds.first,
        rawBlocks: [header()],
      );

      expect(policy.effectiveMode, LedgerPromptInjectionMode.gapFiller);
      expect(policy.algorithmVersion, ledgerPromptInjectionAlgorithmVersion);
    });

    test('known disabled header is an authoritative opt-out', () {
      final policy = deriveLedgerPromptInjectionPolicyFromRaw(
        presetId: ledgerGapFillerTargetPresetIds.first,
        rawBlocks: [header(enabled: false)],
        requestedMode: LedgerPromptInjectionMode.legacy,
        requestedAlgorithmVersion: 'unknown',
      );

      expect(policy.presetOptIn, isFalse);
      expect(policy.effectiveMode, LedgerPromptInjectionMode.disabled);
    });

    test('unknown mode or algorithm falls back to legacy', () {
      final unknownMode = StudioPresetCodec.decodePreset({
        'id': 'custom',
        'blocks': [header()],
        'runtime': {
          'requestedLedgerPromptInjectionMode': 'future',
          'requestedLedgerPromptInjectionAlgorithmVersion':
              ledgerPromptInjectionAlgorithmVersion,
        },
      });
      final unknownVersion = deriveLedgerPromptInjectionPolicyFromRaw(
        presetId: 'custom',
        rawBlocks: [header()],
        requestedMode: LedgerPromptInjectionMode.gapFiller,
        requestedAlgorithmVersion: 'future',
      );

      expect(
        unknownMode.preset.runtime.requestedLedgerPromptInjectionMode,
        LedgerPromptInjectionMode.legacy,
      );
      expect(
        unknownMode.ledgerPromptInjectionPolicy.effectiveMode,
        LedgerPromptInjectionMode.legacy,
      );
      expect(unknownVersion.effectiveMode, LedgerPromptInjectionMode.legacy);
    });

    test('preset codec exposes raw duplicate-header failure', () {
      final decoded = StudioPresetCodec.decodePreset({
        'id': 'custom',
        'blocks': [header(), header()],
      });

      expect(
        decoded.ledgerPromptInjectionPolicy.effectiveMode,
        LedgerPromptInjectionMode.disabled,
      );
    });

    test('duplicate or malformed known header fails disabled', () {
      for (final blocks in <List<Object?>>[
        [header(), header()],
        [header(enabled: 'yes')],
        [
          {
            'id': ledgerPromptInjectionHeaderId,
            'title': 'renamed known header',
          },
        ],
      ]) {
        expect(
          deriveLedgerPromptInjectionPolicyFromRaw(
            presetId: 'custom',
            rawBlocks: blocks,
          ).effectiveMode,
          LedgerPromptInjectionMode.disabled,
        );
      }
    });
  });

  test('policy JSON codec round-trips and has stable identity', () {
    const source = LedgerPromptInjectionPolicy(
      presetOptIn: true,
      mode: LedgerPromptInjectionMode.shadow,
      reverseScanDepth: 24,
    );
    final restored = LedgerPromptInjectionPolicy.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    );

    expect(restored, source);
    expect(restored.identity, source.identity);
    expect(
      restored.identity,
      isNot(
        const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.shadow,
          reverseScanDepth: 25,
        ).identity,
      ),
    );
  });

  test('Studio preset codec round-trips requested policy settings', () {
    final source = StudioPreset(
      id: 'custom',
      agents: const [],
      blocks: [StudioPresetBlock.fromJson(header())],
      runtime: const StudioRuntimeSettings(
        requestedLedgerPromptInjectionMode: LedgerPromptInjectionMode.shadow,
        requestedLedgerPromptInjectionAlgorithmVersion:
            ledgerPromptInjectionAlgorithmVersion,
      ),
    );
    final restored = StudioPresetCodec.decodePreset(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    ).preset;

    expect(restored.runtime, source.runtime);
    expect(
      deriveLedgerPromptInjectionPolicy(restored).effectiveMode,
      LedgerPromptInjectionMode.shadow,
    );
  });
}
