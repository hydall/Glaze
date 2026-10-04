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
