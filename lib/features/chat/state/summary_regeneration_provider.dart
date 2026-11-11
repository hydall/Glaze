import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../services/summary_generation_service.dart';

/// A regeneration that ended in an error.
///
/// Kept in the state rather than pushed through a callback, as
/// `MemoryDraftJobFailure` is: the sheet that started it may be closed by the
/// time the request fails. [seq] tells an open sheet whether it has already
/// shown this one.
class SummaryRegenerationFailure {
  final String sessionId;
  final String blockId;
  final Object error;
  final int seq;

  const SummaryRegenerationFailure({
    required this.sessionId,
    required this.blockId,
    required this.error,
    required this.seq,
  });
}

/// Every summary block being written again, app-wide.
class SummaryRegenerationState {
  /// When each running request went out, keyed by session and block — what a
  /// card's elapsed counter counts from, including after the sheet was closed
  /// and opened again.
  final Map<String, DateTime> startedAt;

  final SummaryRegenerationFailure? lastFailure;

  const SummaryRegenerationState({this.startedAt = const {}, this.lastFailure});

  static String key(String sessionId, String blockId) => '$sessionId/$blockId';

  DateTime? since(String sessionId, String blockId) =>
      startedAt[key(sessionId, blockId)];

  /// Whether a block of [sessionId] is being written: the chain is then held
  /// by that run, and nothing else may call the summarizer on it.
  bool isBusy(String sessionId) =>
      startedAt.keys.any((k) => k.startsWith('$sessionId/'));
}

/// Owns the summary-block regenerations and shortenings in flight: their
/// start times, their cancel tokens and the last failure.
///
/// Lives in the container, not in the Memory sheet, the way
/// `MemoryDraftJobsNotifier` does: the run outlives the sheet, the draft is
/// written by the service either way, and reopening the sheet finds the same
/// run still counting from the same start.
class SummaryRegenerationNotifier extends Notifier<SummaryRegenerationState> {
  final Map<String, CancelToken> _tokens = {};
  int _failureSeq = 0;

  @override
  SummaryRegenerationState build() => const SummaryRegenerationState();

  /// Writes [blockId] again as a draft. Returns when the request has settled;
  /// the state carries everything a reader needs meanwhile.
  Future<void> regenerate({
    required String charId,
    required ChatSession session,
    required String blockId,
  }) => _run(
    session,
    blockId,
    (token) => ref
        .read(summaryGenerationServiceProvider)
        .regenerateBlock(
          charId: charId,
          session: session,
          blockId: blockId,
          cancelToken: token,
        ),
  );

  /// Shortens [blockId] to the block size as a draft, the same way.
  Future<void> shorten({
    required ChatSession session,
    required String blockId,
  }) => _run(
    session,
    blockId,
    (token) => ref
        .read(summaryGenerationServiceProvider)
        .shortenBlock(session: session, blockId: blockId, cancelToken: token),
  );

  Future<void> _run(
    ChatSession session,
    String blockId,
    Future<void> Function(CancelToken token) job,
  ) async {
    final jobKey = SummaryRegenerationState.key(session.id, blockId);
    if (_tokens.containsKey(jobKey)) return;
    final token = CancelToken();
    _tokens[jobKey] = token;
    state = SummaryRegenerationState(
      startedAt: {...state.startedAt, jobKey: DateTime.now()},
      lastFailure: state.lastFailure,
    );
    try {
      await job(token);
    } catch (e) {
      // A stop is not a failure: the reader asked for it.
      if (token.isCancelled || !ref.mounted) return;
      state = SummaryRegenerationState(
        startedAt: state.startedAt,
        lastFailure: SummaryRegenerationFailure(
          sessionId: session.id,
          blockId: blockId,
          error: e,
          seq: ++_failureSeq,
        ),
      );
    } finally {
      if (identical(_tokens[jobKey], token)) {
        _tokens.remove(jobKey);
        _clear(jobKey);
      }
    }
  }

  /// Stops the run on [blockId]. The block keeps the text and any draft it
  /// had.
  void cancel(String sessionId, String blockId) {
    final jobKey = SummaryRegenerationState.key(sessionId, blockId);
    _tokens.remove(jobKey)?.cancel();
    _clear(jobKey);
  }

  void _clear(String jobKey) {
    if (!ref.mounted || !state.startedAt.containsKey(jobKey)) return;
    state = SummaryRegenerationState(
      startedAt: {...state.startedAt}..remove(jobKey),
      lastFailure: state.lastFailure,
    );
  }
}

final summaryRegenerationProvider =
    NotifierProvider<SummaryRegenerationNotifier, SummaryRegenerationState>(
      SummaryRegenerationNotifier.new,
    );
