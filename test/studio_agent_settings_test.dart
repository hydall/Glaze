import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_agent_settings.dart';

void main() {
  test('Responses API slot toggles default to off and round-trip', () {
    expect(
      StudioAgentSettings.fromJson(const {}).studioFinalUseResponsesApi,
      isFalse,
    );
    expect(
      StudioAgentSettings.fromJson(const {}).studioControllerUseResponsesApi,
      isFalse,
    );

    final restored = StudioAgentSettings.fromJson(
      const StudioAgentSettings(
        studioFinalUseResponsesApi: true,
        studioControllerUseResponsesApi: true,
      ).toJson(),
    );
    expect(restored.studioFinalUseResponsesApi, isTrue);
    expect(restored.studioControllerUseResponsesApi, isTrue);
  });

  test('reasoning history count defaults to zero', () {
    expect(
      StudioAgentSettings.fromJson(const {}).studioFinalReasoningHistoryCount,
      0,
    );
  });

  test('migrates the legacy reasoning history toggle', () {
    final settings = StudioAgentSettings.fromJson(const {
      'studioFinalIncludeLastReasoning': true,
    });

    expect(settings.studioFinalReasoningHistoryCount, 1);
    expect(settings.toJson()['studioFinalReasoningHistoryCount'], 1);
    expect(
      settings.toJson(),
      isNot(contains('studioFinalIncludeLastReasoning')),
    );
  });

  test('explicit reasoning history count wins over the legacy toggle', () {
    final settings = StudioAgentSettings.fromJson(const {
      'studioFinalReasoningHistoryCount': 3,
      'studioFinalIncludeLastReasoning': false,
    });

    expect(settings.studioFinalReasoningHistoryCount, 3);
  });

  test('final max tokens zero round-trips as an explicit override', () {
    final restored = StudioAgentSettings.fromJson(
      const StudioAgentSettings(
        studioFinalMaxTokens: 0,
        studioFinalMaxTokensOverride: true,
      ).toJson(),
    );

    expect(restored.studioFinalMaxTokens, 0);
    expect(restored.studioFinalMaxTokensOverride, isTrue);
  });

  test('legacy positive final max tokens enables its override', () {
    final restored = StudioAgentSettings.fromJson(const {
      'studioFinalMaxTokens': 8000,
    });

    expect(restored.studioFinalMaxTokensOverride, isTrue);
  });

  test('legacy zero final max tokens keeps inheritance', () {
    final restored = StudioAgentSettings.fromJson(const {
      'studioFinalMaxTokens': 0,
    });

    expect(restored.studioFinalMaxTokensOverride, isFalse);
  });
}
