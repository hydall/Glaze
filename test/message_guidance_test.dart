import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat/services/saved_message_writer.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

ChatSession _sessionWith(ChatMessage message) => ChatSession(
  id: 's1',
  characterId: 'c1',
  sessionIndex: 0,
  messages: [message],
);

/// Glaze showed the instruction that steered a reply on the message itself:
/// a guided generation and a guided impersonation on the user bubble that
/// carries them, a guided swipe on the variation it produced. None of it
/// reached a message here — the text was written into the swipe's meta and
/// nothing ever read it back.
void main() {
  group('a guided swipe keeps its instruction per variation', () {
    test('switching to a guided variation shows its instruction', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(_messageServiceProvider);
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'first',
        swipes: const ['first', 'second'],
        swipeId: 0,
        swipesMeta: [
          <String, dynamic>{},
          <String, dynamic>{
            'guidanceText': 'be colder',
            'guidanceType': 'SWIPE',
          },
        ],
      );

      final guided = service
          .setSwipe(_sessionWith(message), 0, 1)
          .messages
          .single;
      expect(guided.guidanceText, 'be colder');
      expect(guided.guidanceType, 'SWIPE');

      final plain = service
          .setSwipe(_sessionWith(guided), 0, 0)
          .messages
          .single;
      expect(plain.guidanceText, isNull);
      expect(plain.guidanceType, 'GENERATION');
    });

    test('a reply steered from the composer leaves no block on itself', () {
      // The user message carries that instruction, so repeating it on the
      // reply would show the same text twice.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final service = container.read(_messageServiceProvider);
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'first',
        swipes: const ['first', 'second'],
        swipeId: 0,
        swipesMeta: [
          <String, dynamic>{},
          <String, dynamic>{
            'guidanceText': 'be colder',
            'guidanceType': 'GENERATION',
          },
        ],
      );

      final switched = service
          .setSwipe(_sessionWith(message), 0, 1)
          .messages
          .single;
      expect(switched.guidanceText, isNull);
    });

    test('deleting a variation shows the surviving one\'s instruction', () {
      final message = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'second',
        guidanceText: 'be warmer',
        guidanceType: 'SWIPE',
        swipes: const ['first', 'second'],
        swipeId: 1,
        swipesMeta: [
          <String, dynamic>{
            'guidanceText': 'be colder',
            'guidanceType': 'SWIPE',
          },
          <String, dynamic>{
            'guidanceText': 'be warmer',
            'guidanceType': 'SWIPE',
          },
        ],
      );

      final survivor = ChatMessageService.removeActiveSwipe(message)!;
      expect(survivor.content, 'first');
      expect(survivor.guidanceText, 'be colder');
      expect(survivor.guidanceType, 'SWIPE');
    });
  });

  group('the writer records which kind of run produced a variation', () {
    test('a guided swipe stores its own type, not GENERATION', () {
      const writer = SavedMessageWriter();
      final previous = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'first',
        swipes: const ['first'],
      );
      final state = writer.writeAssistant(
        text: 'second',
        reasoning: null,
        currentSession: _sessionWith(previous),
        isAborted: () => false,
        guidanceText: 'be colder',
        guidanceType: 'SWIPE',
        previousSwipes: const ['first'],
        regenTargetId: 'a1',
      );

      final message = state.session!.messages.single;
      expect(message.swipesMeta.last['guidanceText'], 'be colder');
      expect(message.swipesMeta.last['guidanceType'], 'SWIPE');
      // And it is on the message, so the block is up as soon as the swipe is.
      expect(message.guidanceText, 'be colder');
      expect(message.guidanceType, 'SWIPE');
    });

    test('a composer-guided regenerate leaves the reply unmarked', () {
      const writer = SavedMessageWriter();
      final previous = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'first',
        guidanceText: 'be colder',
        guidanceType: 'SWIPE',
        swipes: const ['first'],
      );
      final state = writer.writeAssistant(
        text: 'second',
        reasoning: null,
        currentSession: _sessionWith(previous),
        isAborted: () => false,
        guidanceText: 'answer in French',
        previousSwipes: const ['first'],
        regenTargetId: 'a1',
      );

      final message = state.session!.messages.single;
      expect(message.swipesMeta.last['guidanceType'], 'GENERATION');
      expect(message.guidanceText, isNull);
    });
  });

  group('the send stamps the message it steered', () {
    final provider = File(
      'lib/features/chat/chat_provider.dart',
    ).readAsStringSync();

    test('a guided send puts its instruction on the user message', () {
      expect(provider, contains('guidanceText: effectiveGuidance'));
      expect(provider, contains('guidanceType: effectiveGuidanceType'));
    });

    test('an impersonation instruction waits for the message it wrote', () {
      expect(provider, contains('_pendingImpersonationGuidance'));
      expect(provider, contains("'IMPERSONATION'"));
    });

    test('regenerating a guided user turn re-uses its instruction', () {
      expect(provider, contains('guidanceText ?? lastMsg.guidanceText'));
    });
  });

  test('the renderer is always told which kind of guidance it is', () {
    // It falls back to SWIPE when the type is missing, which would mislabel
    // every guided generation.
    final mapper = File(
      'lib/features/chat/bridge/chat_message_mapper.dart',
    ).readAsStringSync();
    expect(mapper, isNot(contains("if (m.guidanceType != 'GENERATION')")));
    expect(mapper, contains("'guidanceType': m.guidanceType,"));
  });
}
