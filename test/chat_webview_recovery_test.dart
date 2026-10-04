import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_webview_recovery.dart';

void main() {
  late DateTime now;
  ChatWebViewRecovery recovery({int maxAttempts = 3}) => ChatWebViewRecovery(
    maxAttempts: maxAttempts,
    window: const Duration(minutes: 2),
    clock: () => now,
  );

  setUp(() => now = DateTime(2026, 1, 1, 12));

  test('a page that dies is rebuilt, up to the budget', () {
    final r = recovery();

    expect(r.requestRebuild(), isTrue);
    expect(r.requestRebuild(), isTrue);
    expect(r.requestRebuild(), isTrue);
    // The fourth death inside two minutes is a storm, not an accident: the
    // reader is told instead of watching the chat rebuild itself again.
    expect(r.requestRebuild(), isFalse);
    expect(r.attemptsInWindow, 3);
  });

  test('a death long after the last one is an accident again', () {
    final r = recovery();
    for (var i = 0; i < 3; i++) {
      expect(r.requestRebuild(), isTrue);
    }
    expect(r.requestRebuild(), isFalse);

    now = now.add(const Duration(minutes: 3));

    expect(r.attemptsInWindow, 0);
    expect(r.requestRebuild(), isTrue);
  });

  test('the window slides instead of resetting on the hour', () {
    final r = recovery(maxAttempts: 2);
    expect(r.requestRebuild(), isTrue);
    now = now.add(const Duration(minutes: 1));
    expect(r.requestRebuild(), isTrue);
    expect(r.requestRebuild(), isFalse);

    // The first attempt has aged out of the window; the second has not.
    now = now.add(const Duration(minutes: 1, seconds: 1));
    expect(r.attemptsInWindow, 1);
    expect(r.requestRebuild(), isTrue);
  });

  test('a chat that finished initializing owes nothing', () {
    final r = recovery();
    expect(r.requestRebuild(), isTrue);
    expect(r.requestRebuild(), isTrue);

    r.noteHealthy();

    expect(r.attemptsInWindow, 0);
    for (var i = 0; i < 3; i++) {
      expect(r.requestRebuild(), isTrue, reason: 'attempt $i');
    }
  });
}
