import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/features/chat/widgets/tokenizer_widgets.dart';

/// The stepped trim's lines on the inspector's context bar.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  const breakdown = TokenBreakdown(
    sourceTokens: {'preset': 300},
    staticTotal: 300,
    fixedTotal: 300,
    historyBudget: 700,
    historyTokens: 200,
    totalTokens: 500,
    cutoffIndex: 0,
    trimmedHistory: [],
  );

  Future<void> pump(WidgetTester tester, List<ContextBarMark> marks) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TokenizerLayout(
                breakdown: breakdown,
                contextSize: 1000,
                marks: marks,
              ),
            ),
          ),
        ),
      );

  testWidgets('the trigger and the refill level paint over the bar', (
    tester,
  ) async {
    await pump(tester, const [
      ContextBarMark(percent: 85),
      ContextBarMark(percent: 55, strong: false),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lines at the very ends of the bar stay inside it', (
    tester,
  ) async {
    await pump(tester, const [
      ContextBarMark(percent: 100),
      ContextBarMark(percent: 1, strong: false),
    ]);
    expect(tester.takeException(), isNull);
  });

  test('marks compare by value', () {
    expect(
      const ContextBarMark(percent: 85),
      const ContextBarMark(percent: 85),
    );
    expect(
      const ContextBarMark(percent: 85),
      isNot(const ContextBarMark(percent: 85, strong: false)),
    );
  });
}
