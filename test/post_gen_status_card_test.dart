import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/post_gen_status_card.dart';
import 'package:glaze_flutter/features/chat/chrome/chat_chrome_channel.dart';

/// The card is drawn by the chat page; what it hands the page is the
/// `statusPostGen` chrome section.
Map<String, Object?>? card(ChatChromeChannel channel) =>
    channel.debugSections['statusPostGen'] as Map<String, Object?>?;

String? label(ChatChromeChannel channel) => card(channel)?['label'] as String?;

bool spinning(ChatChromeChannel channel) => card(channel)?['spinner'] == true;

void main() {
  testWidgets('shows a distinct Ledger reconciliation running badge', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledgerReconciliation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    expect(label(channel), 'Ledger reconciliation running...');
    expect(spinning(channel), isTrue);
  });

  testWidgets('shows Ledger transport retry progress', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
      detail: 'Ledger running 2nd attempt...',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    expect(label(channel), 'Ledger running 2nd attempt...');
    expect(spinning(channel), isTrue);
  });

  testWidgets('shows Ledger parser repair progress', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
      detail: 'Ledger repairing rejected response...',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    expect(label(channel), 'Ledger repairing rejected response...');
    expect(spinning(channel), isTrue);
  });

  testWidgets('shows the Card evolution observation pass', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardEvolutionObservation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    expect(label(channel), 'Card evolution observations running...');
    expect(spinning(channel), isTrue);
  });

  testWidgets('shows a distinct Card Rewriter running badge', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardRewriter,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    expect(label(channel), 'Card Rewriter running...');
    expect(spinning(channel), isTrue);
  });

  testWidgets('a running badge can always be dismissed by hand', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );
    expect(label(channel), 'Ledger running...');

    // The page draws the close button; its tap comes back as an intent.
    expect((card(channel)?['action'] as Map?)?['id'], 'statusPostGen');
    channel.debugIntent('statusAction', {'id': 'statusPostGen'});
    await tester.pump();

    // A stage whose ref went away can no longer clear the badge, so the user
    // must be able to. The pipeline keeps running; only the indicator goes.
    expect(container.read(postGenStatusProvider).phase, PostGenTaskPhase.idle);
    expect(card(channel), isNull);
  });

  testWidgets('a stranded running badge is cleared by the watchdog', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );
    expect(label(channel), 'Ledger running...');

    await tester.pump(kPostGenRunningWatchdog + const Duration(seconds: 1));
    await tester.pump();

    expect(container.read(postGenStatusProvider).phase, PostGenTaskPhase.idle);
    expect(card(channel), isNull);
  });

  testWidgets('the watchdog leaves a newer running task alone', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final channel = ChatChromeChannel();
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PostGenStatusCard(channel: channel, sessionId: 'session-1'),
          ),
        ),
      ),
    );

    // A later task takes over the slot just before the first watchdog fires.
    await tester.pump(kPostGenRunningWatchdog - const Duration(seconds: 1));
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardRewriter,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    // The first task's deadline must not cut short the task that replaced it.
    expect(
      container.read(postGenStatusProvider).task,
      PostGenTask.cardRewriter,
    );
    expect(label(channel), 'Card Rewriter running...');

    // Drain the rescheduled timer so the test does not end with one pending.
    await tester.pump(kPostGenRunningWatchdog);
  });
}
