import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/card_rewriter_settings.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_pipeline_overrides.dart';

/// Post Clean, Studio Ledger and Card Rewriter are configured per preset. These
/// pin the fold that resolves a preset's settings against the globals — the
/// contract every runtime consumer depends on, since none of them reads either
/// source directly any more.
void main() {
  const globals = PipelineSettings(
    cleaner: CleanerSettings(postCleanerModel: 'global-cleaner'),
    ledger: LedgerSettings(studioLedgerModel: 'global-ledger'),
    cardRewriter: CardRewriterSettings(
      enabled: true,
      apiConfigId: 'global-api',
    ),
  );

  test('a preset with no lane settings keeps every global', () {
    const preset = StudioPreset(id: 'preset');

    final resolved = applyStudioPresetOverrides(globals, preset);

    expect(resolved, globals);
  });

  test('a null preset keeps every global', () {
    expect(applyStudioPresetOverrides(globals, null), globals);
  });

  test('a configured lane wins, and only that lane', () {
    const preset = StudioPreset(
      id: 'preset',
      runtime: StudioRuntimeSettings(
        ledger: LedgerSettings(studioLedgerModel: 'preset-ledger'),
      ),
    );

    final resolved = applyStudioPresetOverrides(globals, preset);

    expect(resolved.ledger.studioLedgerModel, 'preset-ledger');
    expect(resolved.cleaner.postCleanerModel, 'global-cleaner');
    expect(resolved.cardRewriter.apiConfigId, 'global-api');
  });

  test('the per-lane readers resolve the same way as the whole fold', () {
    const preset = StudioPreset(
      id: 'preset',
      runtime: StudioRuntimeSettings(
        cardRewriter: CardRewriterSettings(apiConfigId: 'preset-api'),
      ),
    );

    expect(
      effectiveCardRewriterSettings(globals, preset).apiConfigId,
      'preset-api',
    );
    expect(effectiveCleanerSettings(globals, preset).postCleanerModel,
        'global-cleaner');
    expect(
      effectiveLedgerSettings(globals, preset).studioLedgerModel,
      'global-ledger',
    );
    expect(effectiveCardRewriterSettings(globals, null).apiConfigId,
        'global-api');
  });

  group('StudioTurnConfigSnapshot', () {
    test('runs the turn on the preset lane settings', () {
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session', enabled: true),
        preset: const StudioPreset(
          id: 'preset',
          runtime: StudioRuntimeSettings(
            cleaner: CleanerSettings(postCleanerModel: 'preset-cleaner'),
            cardRewriter: CardRewriterSettings(enabled: false),
          ),
        ),
        pipelineSettings: globals,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerModel,
          'preset-cleaner');
      expect(snapshot.pipelineSettings.cardRewriter.enabled, isFalse);
      expect(
        snapshot.pipelineSettings.ledger.studioLedgerModel,
        'global-ledger',
      );
    });

    // The switch in the preset editor's pipeline is what the user just flipped,
    // so it has to win over a `postCleanerEnabled` the preset's own cleaner
    // settings still carry from before.
    test('the agent toggle beats the lane settings for Post Clean', () {
      final snapshot = StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session', enabled: true),
        preset: const StudioPreset(
          id: 'preset',
          agentEnabled: {'post_clean': false},
          runtime: StudioRuntimeSettings(
            cleaner: CleanerSettings(postCleanerEnabled: true),
          ),
        ),
        pipelineSettings: globals,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings.cleaner.postCleanerEnabled, isFalse);
    });

    test('Studio off leaves the globals alone', () {
      final snapshot = StudioTurnConfigSnapshot(
        config: null,
        preset: null,
        pipelineSettings: globals,
        apiConfigs: const [],
        activeApiConfig: null,
      );

      expect(snapshot.pipelineSettings, globals);
    });
  });
}
