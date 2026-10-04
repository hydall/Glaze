import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/agent_ops_jobs_provider.dart';

/// The Agentic Ops tabs used to keep "this is running" in their own `State`,
/// so closing the sheet mid-run lost both the spinner and the guard: reopening
/// it offered the same button again, on top of a run that was still going.
void main() {
  ProviderContainer container() {
    final result = ProviderContainer();
    addTearDown(result.dispose);
    return result;
  }

  test('a job that started stays started across a sheet being rebuilt', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);

    expect(jobs.start(AgentOpsJobKeys.collectorPending('s1')), isTrue);
    expect(jobs.isRunning(AgentOpsJobKeys.collectorPending('s1')), isTrue);
    // Nothing in the tab's lifecycle clears it — only the run finishing does.
    jobs.finish(AgentOpsJobKeys.collectorPending('s1'));
    expect(jobs.isRunning(AgentOpsJobKeys.collectorPending('s1')), isFalse);
  });

  test('starting the same job twice is refused', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);
    final key = AgentOpsJobKeys.cardRewriter('s1');

    expect(jobs.start(key), isTrue);
    expect(jobs.start(key), isFalse);
    jobs.finish(key);
    expect(jobs.start(key), isTrue);
  });

  test('a scope answers whether any of its runs is going', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);
    final scope = AgentOpsJobKeys.collectorRecoveryScope('s1');

    expect(jobs.isAnyRunning(scope), isFalse);
    jobs.start(AgentOpsJobKeys.collectorRecovery('s1', 'run-7'));
    expect(jobs.isAnyRunning(scope), isTrue);
    // Another session's recovery is not this one's business.
    expect(
      jobs.isAnyRunning(AgentOpsJobKeys.collectorRecoveryScope('s2')),
      isFalse,
    );
    jobs.finish(AgentOpsJobKeys.collectorRecovery('s1', 'run-7'));
    expect(jobs.isAnyRunning(scope), isFalse);
  });

  test('the same work in two sessions does not share one flag', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);

    jobs.start(AgentOpsJobKeys.ledgerRerun('s1'));
    expect(jobs.isRunning(AgentOpsJobKeys.ledgerRerun('s2')), isFalse);
    expect(jobs.start(AgentOpsJobKeys.ledgerRerun('s2')), isTrue);
  });

  test('finishing a job nobody started changes nothing', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);

    jobs.finish(AgentOpsJobKeys.reconciliation('s1'));
    expect(c.read(agentOpsJobsProvider), isEmpty);
  });

  test('the set is replaced, not mutated, so watchers see the change', () {
    final c = container();
    final jobs = c.read(agentOpsJobsProvider.notifier);

    final before = c.read(agentOpsJobsProvider);
    jobs.start(AgentOpsJobKeys.reconciliation('s1'));
    final after = c.read(agentOpsJobsProvider);

    expect(identical(before, after), isFalse);
    expect(before, isEmpty);
    expect(after, {AgentOpsJobKeys.reconciliation('s1')});
  });
}
