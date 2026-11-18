import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';

void main() {
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
}
