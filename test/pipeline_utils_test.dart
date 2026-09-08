import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/services/generation_pipeline.dart';

ChatMessage _msg({
  required String id,
  required String role,
  required String content,
  bool isError = false,
  bool isTyping = false,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    isError: isError,
    isTyping: isTyping,
  );
}

void main() {
  group('extractRecentHistoryText', () {
    test('returns empty string for empty messages', () {
      final result = extractRecentHistoryText([]);
      expect(result, isEmpty);
    });

    test('formats single message as "Role: content"', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Hello'),
      ]);
      expect(result, 'User: Hello');
    });

    test('formats multiple messages separated by double newline', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Hello'),
        _msg(id: 'm2', role: 'assistant', content: 'Hi there'),
      ]);
      expect(result, 'User: Hello\n\nAssistant: Hi there');
    });

    test('uses "Assistant" for assistant role, "User" for everything else', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Q'),
        _msg(id: 'm2', role: 'assistant', content: 'A'),
        _msg(id: 'm3', role: 'system', content: 'S'),
      ]);
      expect(result.contains('User: Q'), isTrue);
      expect(result.contains('Assistant: A'), isTrue);
      expect(result.contains('User: S'), isTrue);
    });

    test('skips error messages', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Hello'),
        _msg(id: 'm2', role: 'assistant', content: 'Error', isError: true),
        _msg(id: 'm3', role: 'assistant', content: 'OK'),
      ]);
      expect(result, 'User: Hello\n\nAssistant: OK');
    });

    test('skips typing messages', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Hello'),
        _msg(id: 'm2', role: 'assistant', content: '', isTyping: true),
        _msg(id: 'm3', role: 'assistant', content: 'Done'),
      ]);
      expect(result, 'User: Hello\n\nAssistant: Done');
    });

    test('skips empty content messages', () {
      final result = extractRecentHistoryText([
        _msg(id: 'm1', role: 'user', content: 'Hello'),
        _msg(id: 'm2', role: 'assistant', content: '   '),
        _msg(id: 'm3', role: 'assistant', content: 'Real reply'),
      ]);
      expect(result, 'User: Hello\n\nAssistant: Real reply');
    });

    test('limits to last N messages', () {
      final messages = List.generate(
        15,
        (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
      );
      final result = extractRecentHistoryText(messages, maxMessages: 5);
      expect(result.contains('Msg 10'), isTrue);
      expect(result.contains('Msg 14'), isTrue);
      expect(result.contains('Msg 9'), isFalse);
    });

    test('handles exactly maxMessages', () {
      final messages = List.generate(
        10,
        (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
      );
      final result = extractRecentHistoryText(messages, maxMessages: 10);
      expect(result.contains('Msg 0'), isTrue);
      expect(result.contains('Msg 9'), isTrue);
    });

    // Regeneration and historical analysis can bound context to the target
    // message so the Ledger sees the relevant canonical conversation slice.
    test('upToMessageId truncates messages after the target (inclusive)', () {
      final messages = List.generate(
        20,
        (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
      );
      final result = extractRecentHistoryText(
        messages,
        maxMessages: 10,
        upToMessageId: 'm9',
      );
      // Only messages m0..m9 are considered. With maxMessages: 10, all 10
      // are taken (no truncation by max).
      expect(result.contains('Msg 9'), isTrue);
      // Messages after m9 are excluded from the historical context slice.
      expect(result.contains('Msg 10'), isFalse);
      expect(result.contains('Msg 19'), isFalse);
    });

    test('upToMessageId with maxMessages takes the last N of the slice', () {
      final messages = List.generate(
        20,
        (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
      );
      final result = extractRecentHistoryText(
        messages,
        maxMessages: 5,
        upToMessageId: 'm9',
      );
      // Slice m0..m9 (10 messages), then take last 5 → m5..m9.
      expect(result.contains('Msg 5'), isTrue);
      expect(result.contains('Msg 9'), isTrue);
      expect(result.contains('Msg 4'), isFalse);
      expect(result.contains('Msg 10'), isFalse);
    });

    test(
      'upToMessageId with unknown id returns the full slice (no truncation)',
      () {
        final messages = List.generate(
          5,
          (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
        );
        final result = extractRecentHistoryText(
          messages,
          maxMessages: 10,
          upToMessageId: 'm_nonexistent',
        );
        // Unknown id → no truncation, behaves like upToMessageId=null.
        expect(result.contains('Msg 0'), isTrue);
        expect(result.contains('Msg 4'), isTrue);
      },
    );

    test('upToMessageId null returns the full recent history (legacy)', () {
      final messages = List.generate(
        15,
        (i) => _msg(id: 'm$i', role: 'user', content: 'Msg $i'),
      );
      final result = extractRecentHistoryText(
        messages,
        maxMessages: 10,
        upToMessageId: null,
      );
      expect(result.contains('Msg 5'), isTrue);
      expect(result.contains('Msg 14'), isTrue);
      expect(result.contains('Msg 4'), isFalse);
    });
  });

  group('selectStudioLedgerTextAfterCleaner', () {
    test('uses cleaned text when cleaner changed the reply', () {
      final text = selectStudioLedgerTextAfterCleaner(
        cleanerStatus: 'ok',
        wasCleaned: true,
        cleanedText: 'POST-cleaner canon',
        assistantText: 'PRE-cleaner raw',
        streamedPartialText: '',
      );
      expect(text, 'POST-cleaner canon');
    });

    test('uses original text when cleaner skipped the rewrite', () {
      final text = selectStudioLedgerTextAfterCleaner(
        cleanerStatus: 'skipped',
        wasCleaned: false,
        cleanedText: 'Rejected rewrite',
        assistantText: 'Original preserved',
        streamedPartialText: '',
      );
      expect(text, 'Original preserved');
    });

    test(
      'uses partial streamed cleaner text when cleaner failed after output',
      () {
        final text = selectStudioLedgerTextAfterCleaner(
          cleanerStatus: 'error',
          wasCleaned: false,
          cleanedText: 'Original raw',
          assistantText: 'Original raw',
          streamedPartialText: 'Partial cleaned canon',
        );
        expect(text, 'Partial cleaned canon');
      },
    );
  });
}
