import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/studio_agent_settings.dart';

void main() {
  test('Responses API slot toggles default to off and round-trip', () {
    expect(
      StudioAgentSettings.fromJson(const {}).studioFinalUseResponsesApi,
      isFalse,
    );
    expect(
      StudioAgentSettings.fromJson(const {}).studioTrackerUseResponsesApi,
      isFalse,
    );

    final restored = StudioAgentSettings.fromJson(
      const StudioAgentSettings(
        studioFinalUseResponsesApi: true,
        studioTrackerUseResponsesApi: true,
      ).toJson(),
    );
    expect(restored.studioFinalUseResponsesApi, isTrue);
    expect(restored.studioTrackerUseResponsesApi, isTrue);
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
}
