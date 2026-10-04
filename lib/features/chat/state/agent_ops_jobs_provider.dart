import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Agentic Ops actions that are running right now, by job key.
///
/// The work itself belongs to the services behind the buttons, not to the
/// sheet: a collector run, a ledger rerun or a card-rewriter job keeps going
/// and keeps writing its results when the sheet is closed. Only the flag that
/// says "this one is running" used to live in the tab's `State`, so closing
/// and reopening the sheet came back to idle buttons — no spinner on a run
/// that was still going, and nothing left to stop the reader from starting the
/// same job a second time on top of the first.
class AgentOpsJobsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  bool isRunning(String key) => state.contains(key);

  /// Whether anything under [prefix] is running — how a tab asks "is a
  /// recovery of any of these runs in progress" without naming which.
  bool isAnyRunning(String prefix) =>
      state.any((key) => key.startsWith(prefix));

  /// Marks [key] as running. Returns false when it already was — the caller's
  /// guard against starting the same job twice.
  bool start(String key) {
    if (state.contains(key)) return false;
    state = {...state, key};
    return true;
  }

  void finish(String key) {
    if (!state.contains(key)) return;
    state = {...state}..remove(key);
  }
}

final agentOpsJobsProvider =
    NotifierProvider<AgentOpsJobsNotifier, Set<String>>(
      AgentOpsJobsNotifier.new,
    );

/// Job keys. Each one names a single piece of work, so two different sessions
/// (or two different runs) never share a spinner.
class AgentOpsJobKeys {
  const AgentOpsJobKeys._();

  static String collectorPending(String sessionId) =>
      'collector-pending/$sessionId';

  /// Prefix of every collector recovery of one session, for [
  /// AgentOpsJobsNotifier.isAnyRunning].
  static String collectorRecoveryScope(String sessionId) =>
      'collector-recovery/$sessionId/';
  static String collectorRecovery(String sessionId, String runId) =>
      '${collectorRecoveryScope(sessionId)}$runId';

  static String ledgerRerun(String sessionId) => 'ledger-rerun/$sessionId';
  static String reconciliation(String sessionId) => 'reconciliation/$sessionId';

  static String reconciliationRegenScope(String sessionId) =>
      'reconciliation-regen/$sessionId/';
  static String reconciliationRegen(String sessionId, String runId) =>
      '${reconciliationRegenScope(sessionId)}$runId';

  static String cardRewriter(String sessionId) => 'card-rewriter/$sessionId';

  static String cardRewriterRecoveryScope(String sessionId) =>
      'card-rewriter-recovery/$sessionId/';
  static String cardRewriterRecovery(String sessionId, String callId) =>
      '${cardRewriterRecoveryScope(sessionId)}$callId';
}
