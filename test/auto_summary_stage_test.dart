import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/stages/auto_summary_stage.dart';

ChatMessage _msg(String role, {bool isError = false}) =>
    ChatMessage(id: role, role: role, content: 'x', isError: isError);

void main() {
  group('AutoSummaryStage.isEligible (INV-S4)', () {
    final botTail = [_msg('user'), _msg('assistant')];

    test('a bot reply qualifies', () {
      expect(AutoSummaryStage.isEligible(botTail), isTrue);
    });

    test('never after the user sent the last message', () {
      expect(AutoSummaryStage.isEligible([...botTail, _msg('user')]), isFalse);
    });

    test('never on an error bubble', () {
      expect(
        AutoSummaryStage.isEligible([
          _msg('user'),
          _msg('assistant', isError: true),
        ]),
        isFalse,
      );
    });

    test('an empty session never qualifies', () {
      expect(AutoSummaryStage.isEligible(const []), isFalse);
    });
  });
}
