import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/post_gen_status_card.dart';
import 'package:glaze_flutter/shared/widgets/glaze_spinner.dart';

void main() {
  testWidgets('shows a distinct Ledger reconciliation running badge', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledgerReconciliation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Ledger reconciliation running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows Ledger transport retry progress', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
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
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Ledger running 2nd attempt...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows Ledger parser repair progress', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
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
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Ledger repairing rejected response...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows the Card evolution observation pass', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardEvolutionObservation,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Card evolution observations running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('shows a distinct Card Rewriter running badge', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.cardRewriter,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );

    expect(find.text('Card Rewriter running...'), findsOneWidget);
    expect(find.byType(GlazeSpinner), findsOneWidget);
  });

  testWidgets('a running badge can always be dismissed by hand', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );
    expect(find.text('Ledger running...'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    // A stage whose ref went away can no longer clear the badge, so the user
    // must be able to. The pipeline keeps running; only the indicator goes.
    expect(container.read(postGenStatusProvider).phase, PostGenTaskPhase.idle);
    expect(find.text('Ledger running...'), findsNothing);
  });

  testWidgets('a stranded running badge is cleared by the watchdog', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
        ),
      ),
    );
    expect(find.text('Ledger running...'), findsOneWidget);

    await tester.pump(kPostGenRunningWatchdog + const Duration(seconds: 1));
    await tester.pump();

    expect(container.read(postGenStatusProvider).phase, PostGenTaskPhase.idle);
    expect(find.text('Ledger running...'), findsNothing);
  });

  testWidgets('the watchdog leaves a newer running task alone', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(postGenStatusProvider.notifier)
        .state = const PostGenStatusState.running(
      sessionId: 'session-1',
      task: PostGenTask.ledger,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PostGenStatusCard(sessionId: 'session-1')),
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
    expect(find.text('Card Rewriter running...'), findsOneWidget);

    // Drain the rescheduled timer so the test does not end with one pending.
    await tester.pump(kPostGenRunningWatchdog);
  });
}
