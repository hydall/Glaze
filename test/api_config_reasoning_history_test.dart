import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

void main() {
  test('Responses API defaults off and round-trips when enabled', () {
    expect(ApiConfig.fromJson(const {'id': 'api'}).useResponsesApi, isFalse);
    final config = ApiConfig(id: 'api', useResponsesApi: true);

    expect(ApiConfig.fromJson(config.toJson()).useResponsesApi, isTrue);
  });

  test('reasoning settings are backward-compatible', () {
    final config = ApiConfig.fromJson(const {'id': 'api'});

    expect(config.reasoningHistoryCount, 0);
    expect(config.showNativeReasoning, isTrue);
    expect(config.omitTopK, isFalse);
    expect(config.omitFrequencyPenalty, isFalse);
    expect(config.omitPresencePenalty, isFalse);
  });

  test('legacy omitReasoning controls the initial visibility default', () {
    final visible = ApiConfig.fromJson(const {
      'id': 'visible',
      'omitReasoning': false,
    });
    final hidden = ApiConfig.fromJson(const {
      'id': 'hidden',
      'omitReasoning': true,
    });

    expect(visible.showNativeReasoning, isTrue);
    expect(hidden.showNativeReasoning, isFalse);
  });

  test('migrates legacy include-last-reasoning JSON to count one', () {
    final config = ApiConfig.fromJson(const {
      'id': 'legacy',
      'includeLastReasoning': true,
    });

    expect(config.reasoningHistoryCount, 1);
    expect(config.toJson(), isNot(contains('includeLastReasoning')));
  });
}
