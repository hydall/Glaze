import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_search_delegate.dart';

ChatMessage _msg(String id, String content, {String? reasoning}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: 1,
  reasoning: reasoning,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatSearchDelegate.pageMatchIndex', () {
    // Four messages, hits in the first and the last two; the page holds a
    // scrollback window that starts at the third.
    final messages = [
      _msg('m1', 'foo'),
      _msg('m2', 'none'),
      _msg('m3', 'foo foo'),
      _msg('m4', 'foo'),
    ];

    test('counts the active hit over the window the page holds', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', messages);
      expect(delegate.matchCount, 4);
      expect(delegate.activeMatch?.messageIndex, 0);
      // The first hit is in a message the page does not have.
      expect(delegate.pageMatchIndex(2), -1);
      // Once the window reaches it, it is the page's first hit too.
      expect(delegate.pageMatchIndex(0), 0);

      delegate.searchNext();
      expect(delegate.activeMatch?.messageIndex, 2);
      // Chat-wide hit 1 is the page's hit 0: the one before it is outside.
      expect(delegate.pageMatchIndex(2), 0);
      delegate.searchNext();
      delegate.searchNext();
      expect(delegate.pageMatchIndex(2), 2);
      expect(delegate.pageMatchIndex(3), 0);
      delegate.dispose();
    });

    test('a new query starts where the reader is, not at the chat start', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.windowStart = 2;
      delegate.search('foo', messages);
      // The first hit in the window (m3), not the one in m1.
      expect(delegate.activeMatch?.messageIndex, 2);
      expect(delegate.pageMatchIndex(2), 0);
      // No hit in the window: the newest one before it, the nearest to load.
      delegate.windowStart = 4;
      delegate.search('foo', messages);
      expect(delegate.activeMatch?.messageIndex, 3);
      delegate.windowStart = 2;
      delegate.search('none', messages);
      expect(delegate.activeMatch?.messageIndex, 1);
      delegate.dispose();
    });

    test('no hits, no active match', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('zzz', messages);
      expect(delegate.activeMatch, isNull);
      expect(delegate.pageMatchIndex(0), -1);
      delegate.dispose();
    });
  });

  group('ChatSearchDelegate.syncWithMessages', () {
    test('recounts the matches after a message was edited', () {
      final delegate = ChatSearchDelegate()..openSearch();
      final messages = [_msg('m1', 'foo and foo'), _msg('m2', 'nothing')];
      delegate.search('foo', messages);
      expect(delegate.matchCount, 2);

      final edited = [_msg('m1', 'foo and foo'), _msg('m2', 'foo again')];
      expect(delegate.syncWithMessages(edited), isTrue);
      expect(delegate.matchCount, 3);

      delegate.dispose();
    });

    test('drops matches removed by an edit and clamps the active index', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', [_msg('m1', 'foo'), _msg('m2', 'foo foo')]);
      delegate.searchNext();
      delegate.searchNext();
      expect(delegate.searchCurrentIndex, 2);

      delegate.syncWithMessages([_msg('m1', 'foo'), _msg('m2', 'gone')]);

      expect(delegate.matchCount, 1);
      expect(delegate.searchCurrentIndex, 0);
      expect(delegate.onSearchNext, isNull);

      delegate.dispose();
    });

    test('keeps the reader on the active match when it survives', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', [_msg('m1', 'foo'), _msg('m2', 'foo foo')]);
      delegate.searchNext();
      expect(delegate.searchCurrentIndex, 1);

      delegate.syncWithMessages([
        _msg('m1', 'foo'),
        _msg('m2', 'foo foo'),
        _msg('m3', 'foo'),
      ]);

      expect(delegate.matchCount, 4);
      expect(delegate.searchCurrentIndex, 1);

      delegate.dispose();
    });

    test('bumps the revision so the WebView re-numbers its highlights', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', [_msg('m1', 'foo')]);
      final before = delegate.searchRevision;

      // Same match count, same active index — only the surrounding text moved.
      expect(delegate.syncWithMessages([_msg('m1', 'a foo b')]), isTrue);

      expect(delegate.matchCount, 1);
      expect(delegate.searchCurrentIndex, 0);
      expect(delegate.searchRevision, before + 1);

      delegate.dispose();
    });

    test('is a no-op when the messages did not change', () {
      final delegate = ChatSearchDelegate()..openSearch();
      final messages = [_msg('m1', 'foo')];
      delegate.search('foo', messages);
      var notifications = 0;
      void listener() => notifications++;
      delegate.addListener(listener);

      expect(delegate.syncWithMessages([_msg('m1', 'foo')]), isFalse);
      expect(notifications, 0);

      delegate.removeListener(listener);
      delegate.dispose();
    });

    test('a delete that preserves the total text still recounts', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', [_msg('m1', 'foo'), _msg('m2', 'foo')]);

      // Deleting the first message keeps the total text identical, so only the
      // ids in the fingerprint can tell the two lists apart.
      expect(
        delegate.syncWithMessages([_msg('m2', 'foo'), _msg('m3', 'foo')]),
        isTrue,
      );

      delegate.dispose();
    });

    test('does nothing while the search bar is closed', () {
      final delegate = ChatSearchDelegate();
      expect(delegate.syncWithMessages([_msg('m1', 'foo')]), isFalse);
      expect(delegate.matchCount, 0);
      delegate.dispose();
    });

    test('counts reasoning occurrences too', () {
      final delegate = ChatSearchDelegate()..openSearch();
      delegate.search('foo', [_msg('m1', 'foo', reasoning: 'foo')]);
      expect(delegate.matchCount, 2);

      delegate.syncWithMessages([_msg('m1', 'foo', reasoning: 'no hit')]);
      expect(delegate.matchCount, 1);

      delegate.dispose();
    });
  });
}
