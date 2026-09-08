import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/prompt_block_resolver.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/preset_macro_attribution.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/preset.dart';

void main() {
  test('{{personality}} in preset: chrome in preset row, field in macroTokens', () {
    final preset = Preset(
      id: 'p1',
      name: 'test',
      blocks: [
        const PresetBlock(
          id: 'custom',
          name: 'Form',
          role: 'system',
          content: 'Cast: {{personality}}',
          enabled: true,
        ),
      ],
    );
    final char = Character(
      id: 'c1',
      name: 'A',
      personality: 'P' * 400,
    );
    final result = buildPrompt(PromptPayload(
      character: char,
      preset: preset,
      history: const [],
      apiConfig: const ApiConfig(id: 'a', name: 'a', contextSize: 10000, maxTokens: 100),
    ));

    expect(
      result.breakdown.macroTokens['personality'],
      estimateTokens('P' * 400),
    );
    expect(result.breakdown.sourceTokens['preset'], lessThan(100));
    expect(result.breakdown.presetNetTokens, result.breakdown.sourceTokens['preset']);
  });

  test('contentForAccounting blanks {{personality}}', () {
    final result = resolveBlockContent(
      id: 'custom',
      rawContent: 'Cast: {{personality}}',
      role: 'system',
      char: Character(id: 'c1', name: 'A', personality: 'LONG'),
      persona: null,
      macroCtx: MacroContext(
        charName: 'A',
        charId: 'c1',
        sessionId: 's1',
        charPersonality: 'LONG',
      ),
      sessionVars: const {},
      globalVars: const {},
      summaryContent: null,
      summaryPrefix: null,
      notifyObj: NotifyObj(),
    );
    expect(result!.content, contains('LONG'));
    expect(result.contentForAccounting, 'Cast: ');
  });

  test('setvar-only block contributes definition tokens to preset', () {
    final notify = NotifyObj();
    final resolved = resolveBlockContent(
      id: 'vars',
      rawContent: '{{setvar::x::hello world}}{{trim}}',
      role: 'system',
      char: Character(id: 'c1', name: 'A'),
      persona: null,
      macroCtx: MacroContext(charName: 'A', charId: 'c1', sessionId: 's1'),
      sessionVars: const {},
      globalVars: const {},
      summaryContent: null,
      summaryPrefix: null,
      notifyObj: notify,
    );
    expect(resolved, isNotNull);
    expect(resolved!.content.trim(), isEmpty);
    expect(estimateTokens(resolved.contentForAccounting), greaterThan(0));
  });

  test('presetOnlyTokenCount ignores raw {{personality}} payload', () {
    final preset = Preset(
      id: 'p1',
      name: 'test',
      blocks: [
        const PresetBlock(
          id: 'custom',
          name: 'Form',
          role: 'system',
          content: 'Cast: {{personality}}',
          enabled: true,
        ),
      ],
    );
    final raw = estimateTokens('Cast: {{personality}}');
    final only = presetOnlyTokenCount(preset);
    expect(only, lessThan(raw));
  });

  test('presetNetTokens matches preset gross when lorebooks in macroTokens', () {
    final bd = TokenBreakdown(
      sourceTokens: {'preset': 16939, 'lorebook': 0},
      macroTokens: {'lorebooks': 2487, 'personality': 5318},
      staticTotal: 16939,
      historyBudget: 0,
      historyTokens: 0,
      totalTokens: 16939,
      cutoffIndex: 0,
      trimmedHistory: const [],
    );
    expect(bd.presetNetTokens, 16939);
  });
}
