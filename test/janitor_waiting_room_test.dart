import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/janitor_waiting_room.dart';

void main() {
  group('parseJanitorWaitingRoom', () {
    test('reads the real JanitorAI waiting-room page', () {
      final room = parseJanitorWaitingRoom(_waitingRoomHtml);

      expect(room, isNotNull);
      expect(room!.refreshInterval, const Duration(seconds: 20));
      expect(room.estimatedWait, '4 minutes');
    });

    test('reads a page without an estimate', () {
      final room = parseJanitorWaitingRoom(
        '<html><head><title>Please wait — janitor</title></head>'
        '<body><h1>You’re in line</h1></body></html>',
      );

      expect(room, isNotNull);
      expect(room!.estimatedWait, isNull);
      expect(room.refreshInterval, const Duration(seconds: 20));
    });

    test('reads the refresh interval with the attributes reversed', () {
      final room = parseJanitorWaitingRoom(
        '<html><head><title>Please wait — janitor</title>'
        '<meta content="15" http-equiv="refresh"></head>'
        '<body>You’re in line</body></html>',
      );

      expect(room?.refreshInterval, const Duration(seconds: 15));
    });

    test('does not mistake a character card for the waiting room', () {
      final room = parseJanitorWaitingRoom(
        '{"description":"Please wait in line at the bank, the janitor will '
        'refresh the floor. Traffic is high."}',
      );

      expect(room, isNull);
    });

    test('does not mistake the site itself for the waiting room', () {
      final room = parseJanitorWaitingRoom(
        '<html><head><title>janitor - Build, share, and explore</title></head>'
        '<body><h1>Be anyone. Build anything.</h1></body></html>',
      );

      expect(room, isNull);
    });

    test('ignores empty bodies', () {
      expect(parseJanitorWaitingRoom(''), isNull);
    });
  });
}

const _waitingRoomHtml = '''
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="dark">
    <meta name="theme-color" content="#313338">
    <meta
      name="description"
      content="janitor is managing traffic. Try again shortly, or use the iOS or Android app."
    >
    <title>Please wait — janitor</title>
    <meta http-equiv="refresh" content="20">
  </head>
  <body>
    <main aria-labelledby="page-title">
      <h1 id="page-title">You’re in line</h1>
      <p>
        Traffic is high right now, so we’re letting people in slowly to keep things stable.
        Keep this page open, or chat in the app while you wait.
      </p>
      <p class="wait" aria-live="polite" aria-atomic="true">
          Estimated wait: 4 minutes
      </p>
      <p class="note">
          This page refreshes every 20 seconds.
      </p>
    </main>
  </body>
</html>
''';
