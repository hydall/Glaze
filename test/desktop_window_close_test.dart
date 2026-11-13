import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/platform/desktop_window.dart';

/// Closing the desktop window used to look like a crash at the next launch:
/// the window was destroyed before Dart heard of it, so the session marker
/// still said `foreground`. The close is intercepted now, and the run is
/// recorded as closed before the window goes.
void main() {
  test('the run is marked closed before the window is destroyed', () async {
    final order = <String>[];
    final handler = DesktopCloseHandler(
      markClosed: () => order.add('marked'),
      closeWindow: () async => order.add('destroyed'),
    );

    handler.onWindowClose();
    await Future<void>.delayed(Duration.zero);

    expect(order, ['marked', 'destroyed']);
  });

  test('the window goes even when marking the run fails', () async {
    var destroyed = false;
    final handler = DesktopCloseHandler(
      markClosed: () => throw StateError('disk full'),
      closeWindow: () async => destroyed = true,
    );

    expect(handler.onWindowClose, throwsStateError);
    await Future<void>.delayed(Duration.zero);

    expect(destroyed, isTrue);
  });

  test('a close that fails lets the next request try again', () async {
    var attempts = 0;
    var unmarked = 0;
    final handler = DesktopCloseHandler(
      markClosed: () {},
      unmarkClosed: () => unmarked++,
      closeWindow: () async {
        attempts++;
        if (attempts == 1) throw StateError('the intercept would not lift');
      },
    );

    handler.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    handler.onWindowClose();
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 2);
    // The first failure put the run back to live; the second close went.
    expect(unmarked, 1);
  });

  test('a repeated close request is honoured once', () async {
    var marked = 0;
    var destroyed = 0;
    final handler = DesktopCloseHandler(
      markClosed: () => marked++,
      closeWindow: () async => destroyed++,
    );

    handler.onWindowClose();
    handler.onWindowClose();
    await Future<void>.delayed(Duration.zero);

    expect(marked, 1);
    expect(destroyed, 1);
  });
}
