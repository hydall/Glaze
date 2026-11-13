import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/summary_block.dart';
import '../services/summary_generation_service.dart';

/// A compaction that ended in an error, or found nothing to do
/// (`SummaryChainException('nothing_to_compact')`).
///
/// Kept in the state, as `SummaryRegenerationFailure` is: the sheet that
/// started the run may be closed by the time it fails. [seq] tells an open
/// sheet whether it has already shown this one.
class SummaryCompactionFailure {
  final String sessionId;
  final Object error;
  final int seq;

  const SummaryCompactionFailure({
    required this.sessionId,
    required this.error,
    required this.seq,
  });
}

/// One manual compaction under way.
class SummaryCompactionRun {
  final DateTime startedAt;
  final SummaryCompactionProgress progress;

  /// The reader pressed Stop: the step under way finishes, nothing follows.
  final bool stopping;

  const SummaryCompactionRun({
    required this.startedAt,
    this.progress = const SummaryCompactionProgress(),
    this.stopping = false,
  });

  SummaryCompactionRun copyWith({
    SummaryCompactionProgress? progress,
    bool? stopping,
  }) => SummaryCompactionRun(
    startedAt: startedAt,
    progress: progress ?? this.progress,
    stopping: stopping ?? this.stopping,
  );
}

/// Every manual compaction running, app-wide, keyed by session.
class SummaryCompactionState {
  final Map<String, SummaryCompactionRun> runs;
  final SummaryCompactionFailure? lastFailure;

  const SummaryCompactionState({this.runs = const {}, this.lastFailure});

  SummaryCompactionRun? run(String sessionId) => runs[sessionId];

  /// Whether [sessionId]'s chain is held by a run: nothing else may call the
  /// summarizer on it meanwhile.
  bool isBusy(String sessionId) => runs.containsKey(sessionId);

  SummaryCompactionState _with({
    Map<String, SummaryCompactionRun>? runs,
    SummaryCompactionFailure? lastFailure,
  }) => SummaryCompactionState(
    runs: runs ?? this.runs,
    lastFailure: lastFailure ?? this.lastFailure,
  );
}

/// Owns the manual compactions in flight — "Compact history" in the Memory
/// sheet: their progress, their cancel tokens and the last failure.
///
/// Lives in the container, not in the sheet, the way
/// `SummaryRegenerationNotifier` does: a long chat takes many blocks and
/// minutes, so the run goes on when the sheet is closed, every block is
/// written by the service as it lands, and reopening the sheet finds the same
/// run still counting from the same start.
class SummaryCompactionNotifier extends Notifier<SummaryCompactionState> {
  final Map<String, CancelToken> _tokens = {};
  int _failureSeq = 0;

  @override
  SummaryCompactionState build() => const SummaryCompactionState();

  /// Retells everything older than the fresh tail of [session], block by
  /// block, until nothing is left. Returns when the run has settled; the
  /// state carries everything a reader needs meanwhile. A second call for a
  /// session already running is ignored.
  Future<void> compact({
    required String charId,
    required ChatSession session,
  }) async {
    final sessionId = session.id;
    if (_tokens.containsKey(sessionId)) return;
    final token = CancelToken();
    _tokens[sessionId] = token;
    _put(sessionId, SummaryCompactionRun(startedAt: DateTime.now()));
    try {
      final result = await ref
          .read(summaryGenerationServiceProvider)
          .compact(
            charId: charId,
            session: session,
            force: true,
            cancelToken: token,
            onProgress: (progress) {
              // A progress call from a run that has been replaced is stale.
              if (!identical(_tokens[sessionId], token)) return;
              final run = state.run(sessionId);
              if (run != null) {
                _put(sessionId, run.copyWith(progress: progress));
              }
            },
          );
      if (!result.changed && !token.isCancelled) {
        throw const SummaryChainException('nothing_to_compact');
      }
    } catch (e) {
      // A stop aborts nothing, so whatever was thrown is a real failure, the
      // last block's included.
      if (!ref.mounted) return;
      state = state._with(
        lastFailure: SummaryCompactionFailure(
          sessionId: sessionId,
          error: e,
          seq: ++_failureSeq,
        ),
      );
    } finally {
      if (identical(_tokens[sessionId], token)) {
        _tokens.remove(sessionId);
        _remove(sessionId);
      }
    }
  }

  /// Stops the run on [sessionId] after the block it is writing. Every block
  /// already written stays. The run is shown as stopping until it has.
  void cancel(String sessionId) {
    final token = _tokens[sessionId];
    if (token == null) return;
    token.cancel();
    final run = state.run(sessionId);
    if (run != null) _put(sessionId, run.copyWith(stopping: true));
  }

  void _put(String sessionId, SummaryCompactionRun run) {
    if (!ref.mounted) return;
    state = state._with(runs: {...state.runs, sessionId: run});
  }

  void _remove(String sessionId) {
    if (!ref.mounted || !state.runs.containsKey(sessionId)) return;
    state = state._with(runs: {...state.runs}..remove(sessionId));
  }
}

final summaryCompactionProvider =
    NotifierProvider<SummaryCompactionNotifier, SummaryCompactionState>(
      SummaryCompactionNotifier.new,
    );
