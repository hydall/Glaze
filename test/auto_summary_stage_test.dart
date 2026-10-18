import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/stages/auto_summary_stage.dart';

ChatMessage _msg(String role, {bool isError = false}) =>
    ChatMessage(id: role, role: role, content: 'x', isError: isError);

void main() {
  group('AutoSummaryStage.isDue (INV-S4)', () {
    final botTail = [
      _msg('user'),
      _msg('assistant'),
      _msg('user'),
      _msg('assistant'),
    ];

    test('fires once the interval is reached on a bot turn', () {
      expect(
        AutoSummaryStage.isDue(
          messages: botTail,
          savedMessageCount: 0,
          interval: 4,
        ),
        isTrue,
      );
    });

    test('never fires when the user sent the last message', () {
      expect(
        AutoSummaryStage.isDue(
          messages: [...botTail, _msg('user')],
          savedMessageCount: 0,
          interval: 4,
        ),
        isFalse,
      );
    });

    test('does not fire on an error bubble', () {
      expect(
        AutoSummaryStage.isDue(
          messages: [...botTail.sublist(0, 3), _msg('assistant', isError: true)],
          savedMessageCount: 0,
          interval: 4,
        ),
        isFalse,
      );
    });

    test('counts only messages added since the stored summary', () {
      expect(
        AutoSummaryStage.isDue(
          messages: botTail,
          savedMessageCount: 2,
          interval: 4,
        ),
        isFalse,
      );
      expect(
        AutoSummaryStage.isDue(
          messages: botTail,
          savedMessageCount: 2,
          interval: 2,
        ),
        isTrue,
      );
    });

    test('interval 0 disables the feature', () {
      expect(
        AutoSummaryStage.isDue(
          messages: botTail,
          savedMessageCount: 0,
          interval: 0,
        ),
        isFalse,
      );
    });

    test('an empty session is never due', () {
      expect(
        AutoSummaryStage.isDue(
          messages: const [],
          savedMessageCount: 0,
          interval: 1,
        ),
        isFalse,
      );
    });
  });
}
