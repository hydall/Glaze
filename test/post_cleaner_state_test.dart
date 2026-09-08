import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/state/post_cleaner_state_provider.dart';

void main() {
  group('PostCleanerState', () {
    test('idle is the default', () {
      final state = const PostCleanerState.idle();
      expect(state.phase, PostCleanerPhase.idle);
      expect(state.isActive, isFalse);
      expect(state.isDone, isFalse);
      expect(state.isError, isFalse);
      expect(state.charDelta, isNull);
    });

    test('running sets fields correctly', () {
      const state = PostCleanerState.running(
        sessionId: 's1',
        messageId: 'm1',
        originalChars: 500,
      );
      expect(state.phase, PostCleanerPhase.running);
      expect(state.isActive, isTrue);
      expect(state.sessionId, 's1');
      expect(state.messageId, 'm1');
      expect(state.originalChars, 500);
      expect(state.cleanedChars, isNull);
      expect(state.charDelta, isNull);
    });

    test('factChecking is active and marks fact check enabled', () {
      const state = PostCleanerState.factChecking(
        sessionId: 's1',
        messageId: 'm1',
        originalChars: 500,
      );
      expect(state.phase, PostCleanerPhase.factChecking);
      expect(state.isActive, isTrue);
      expect(state.factCheckEnabled, isTrue);
      expect(state.sessionId, 's1');
      expect(state.messageId, 'm1');
      expect(state.originalChars, 500);
      expect(state.cleanedChars, isNull);
    });

    test('done computes charDelta', () {
      const state = PostCleanerState.done(
        sessionId: 's1',
        messageId: 'm1',
        originalChars: 500,
        cleanedChars: 300,
      );
      expect(state.phase, PostCleanerPhase.done);
      expect(state.isDone, isTrue);
      expect(state.charDelta, -200);
    });

    test('done with positive delta', () {
      const state = PostCleanerState.done(
        sessionId: 's1',
        messageId: 'm1',
        originalChars: 300,
        cleanedChars: 350,
      );
      expect(state.charDelta, 50);
    });

    test('error sets phase', () {
      const state = PostCleanerState.error(sessionId: 's1', messageId: 'm1');
      expect(state.phase, PostCleanerPhase.error);
      expect(state.isError, isTrue);
      expect(state.isDone, isFalse);
    });

    test('skipped is done but not error', () {
      const state = PostCleanerState.skipped(sessionId: 's1', messageId: 'm1');
      expect(state.phase, PostCleanerPhase.skipped);
      expect(state.isDone, isTrue);
      expect(state.isError, isFalse);
    });
  });
}
