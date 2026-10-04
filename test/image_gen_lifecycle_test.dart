import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/image_recovery_service.dart';
import 'package:glaze_flutter/features/chat/services/image_gen_processor.dart';

void main() {
  ChatSession session(String id, String content) => ChatSession(
    id: id,
    characterId: 'character',
    sessionIndex: 0,
    messages: [
      ChatMessage(id: 'assistant', role: 'assistant', content: content),
    ],
  );

  group('ImageGenProcessor owned state merging', () {
    test('merges a current image update onto live chat state', () {
      final originalSession = session('session-1', '[IMG:GEN]');
      final liveState = ChatState(
        session: originalSession.copyWith(
          messages: [
            ...originalSession.messages,
            const ChatMessage(id: 'tail', role: 'user', content: 'new tail'),
          ],
          draft: 'new draft',
          sessionVars: const {'concurrent': 'keep'},
        ),
        isGenerating: true,
        isGeneratingImage: true,
        isPostGenRunning: true,
        error: 'unrelated live state',
        visibleStartIndex: 4,
      );
      final imageUpdate = ChatState(
        session: session('session-1', '[IMG:RESULT:/images/result.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: imageUpdate,
        sessionId: 'session-1',
        targetMessageId: 'assistant',
        ownsOperation: true,
      );

      expect(merged, isNotNull);
      expect(merged!.messages.first.content, '[IMG:RESULT:/images/result.png]');
      expect(merged.messages.last.id, 'tail');
      expect(merged.session?.draft, 'new draft');
      expect(merged.session?.sessionVars, {'concurrent': 'keep'});
      expect(merged.isGenerating, isTrue);
      expect(merged.isPostGenRunning, isTrue);
      expect(merged.error, 'unrelated live state');
      expect(merged.visibleStartIndex, 4);
      expect(merged.isGeneratingImage, isFalse);
    });

    test('drops late callbacks after stop or replacement generation', () {
      final liveState = ChatState(
        session: session('session-1', '[IMG:GEN]'),
        isGeneratingImage: false,
      );
      final staleUpdate = ChatState(
        session: session('session-1', '[IMG:RESULT:/images/stale.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: staleUpdate,
        sessionId: 'session-1',
        targetMessageId: 'assistant',
        ownsOperation: false,
      );

      expect(merged, isNull);
      expect(liveState.messages.single.content, '[IMG:GEN]');
      expect(liveState.isGeneratingImage, isFalse);
    });

    test('drops an owned callback when the live session changed', () {
      final liveState = ChatState(
        session: session('new-session', 'new generation'),
        isGenerating: true,
      );
      final staleUpdate = ChatState(
        session: session('old-session', '[IMG:RESULT:/images/old.png]'),
        isGeneratingImage: false,
      );

      final merged = ImageGenProcessor.mergeOwnedStateUpdate(
        liveState: liveState,
        update: staleUpdate,
        sessionId: 'old-session',
        targetMessageId: 'assistant',
        ownsOperation: true,
      );

      expect(merged, isNull);
      expect(liveState.messages.single.content, 'new generation');
      expect(liveState.isGenerating, isTrue);
    });
  });

  group('Imagen green swipes', () {
    test('regeneration rewrites the active swipe instead of adding one', () {
      final message = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
        isError: true,
        swipes: const ['She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]'],
        swipesMeta: [
          <String, dynamic>{
            'isError': true,
            'agentSwipes': [
              const AgentSwipe(
                content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
              ).toJson(),
            ],
            'agentSwipeId': 0,
          },
        ],
        agentSwipes: const [
          AgentSwipe(
            content: 'She smiles. [IMG:RESULT:/old.png|{"prompt":"scene"}]',
          ),
        ],
      );

      final result = ImageGenProcessor.resetImageContentInPlace(
        message,
        'She smiles. [IMG:GEN:{"prompt":"scene"}]',
      );

      expect(result.swipes, ['She smiles. [IMG:GEN:{"prompt":"scene"}]']);
      expect(result.swipeId, 0);
      expect(result.content, 'She smiles. [IMG:GEN:{"prompt":"scene"}]');
      expect(result.agentSwipes.single.content, contains('[IMG:GEN:'));
      expect(result.isError, isFalse);
      expect(result.swipesMeta.single.containsKey('isError'), isFalse);
      expect(
        AgentSwipe.fromJson(
          Map<String, dynamic>.from(
            (result.swipesMeta[0]['agentSwipes'] as List).single as Map,
          ),
        ).content,
        contains('[IMG:GEN:'),
      );
    });

    test('image completion keeps green, blue and metadata content aligned', () {
      final candidate = ChatMessage(
        id: 'assistant',
        role: 'assistant',
        content: '[IMG:GEN]',
        swipes: const ['old', '[IMG:GEN]'],
        swipeId: 1,
        swipesMeta: [
          <String, dynamic>{},
          <String, dynamic>{
            'agentSwipes': [const AgentSwipe(content: '[IMG:GEN]').toJson()],
          },
        ],
        agentSwipes: const [AgentSwipe(content: '[IMG:GEN]')],
      );

      final result = ImageGenProcessor.replaceActiveImageContent(
        candidate,
        '[IMG:RESULT:/new.png]',
      );

      expect(result.content, '[IMG:RESULT:/new.png]');
      expect(result.swipes, ['old', '[IMG:RESULT:/new.png]']);
      expect(result.agentSwipes.single.content, '[IMG:RESULT:/new.png]');
      final stored = AgentSwipe.fromJson(
        Map<String, dynamic>.from(
          (result.swipesMeta[1]['agentSwipes'] as List).single as Map,
        ),
      );
      expect(stored.content, '[IMG:RESULT:/new.png]');
    });
  });

  group('regenerating a failed block', () {
    const text =
        '[IMG:RESULT:/kept.png|{"prompt":"kept"}] '
        '[IMG:ERROR:{"error":"HTTP 502","instruction":"{\\"prompt\\":\\"lost\\"}"}]';

    test('resets only the failed block and keeps the finished image', () {
      final result = ImageRecoveryService.resetImgErrorTagsToGen(text);

      expect(result, contains('[IMG:RESULT:/kept.png|{"prompt":"kept"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"lost"}]'));
      expect(result, isNot(contains('[IMG:ERROR:')));
    });

    test('a full retry still resets every block', () {
      final result = ImageRecoveryService.resetImgTagsToGen(text);

      expect(result, isNot(contains('[IMG:RESULT:')));
      // The finished image rides along in the pending tag, so the retry adds a
      // variant to that block instead of replacing its only picture.
      expect(result, contains('[IMG:GEN:@/kept.png|{"prompt":"kept"}]'));
      expect(result, contains('[IMG:GEN:{"prompt":"lost"}]'));
    });
  });
}
