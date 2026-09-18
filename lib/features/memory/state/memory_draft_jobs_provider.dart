import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_settings_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../chat/chat_provider.dart';
import '../../chat/memory_draft_generator.dart';
import '../controllers/memory_settings_mapper.dart';
import 'memory_active_drafts_provider.dart';
import 'memory_book_revision_provider.dart';

/// The one LLM call a memory draft is generated with. Behind
/// [memoryDraftGeneratorProvider] so a test can stand in for the network.
typedef GenerateMemoryDraft =
    Future<MemoryDraft> Function({
      required MemoryDraft draft,
      required MemoryBookSettings settings,
      required PipelineSettings pipeline,
      required List<ChatMessage> messages,
      required String charId,
      required String sessionId,
      required Map<String, String> sessionVars,
      CancelToken? cancelToken,
    });

final memoryDraftGeneratorProvider = Provider<GenerateMemoryDraft>((ref) {
  return ({
    required draft,
    required settings,
    required pipeline,
    required messages,
    required charId,
    required sessionId,
    required sessionVars,
    cancelToken,
  }) => MemoryDraftGenerator(ref).generate(
    draft: draft,
    settings: settings,
    pipeline: pipeline,
    messages: messages,
    charId: charId,
    sessionId: sessionId,
    sessionVars: sessionVars,
    cancelToken: cancelToken,
  );
});

/// One manual memory-draft generation that is still running.
class MemoryDraftJob {
  final String sessionId;
  final String draftId;

  /// When the request went out — what the row's elapsed counter counts from,
  /// including after the sheet has been closed and reopened.
  final DateTime startedAt;

  const MemoryDraftJob({
    required this.sessionId,
    required this.draftId,
    required this.startedAt,
  });
}

/// A generation that ended in an error.
///
/// Kept in the state rather than pushed through a callback: the sheet that
/// started it may be closed by the time the request fails, and a toast has
/// nowhere to go then. The draft itself carries the same message, so a reader
/// who comes back later still finds out; [seq] is what tells a sheet that is
/// open whether it has already reported this one.
class MemoryDraftJobFailure {
  final String sessionId;
  final String draftId;
  final String message;

  /// Whether the draft already had content — a retry that failed reads
  /// differently from a first attempt that did.
  final bool wasRegeneration;

  /// Monotonic marker, compared against the last one a reader reported.
  final int seq;

  const MemoryDraftJobFailure({
    required this.sessionId,
    required this.draftId,
    required this.message,
    required this.wasRegeneration,
    required this.seq,
  });
}

/// Every manual memory-draft generation in flight, app-wide.
class MemoryDraftJobsState {
  /// Running jobs, keyed by session and draft.
  final Map<String, MemoryDraftJob> jobs;

  final MemoryDraftJobFailure? lastFailure;

  const MemoryDraftJobsState({this.jobs = const {}, this.lastFailure});

  static String key(String sessionId, String draftId) => '$sessionId/$draftId';

  bool isGenerating(String sessionId, String draftId) =>
      jobs.containsKey(key(sessionId, draftId));

  DateTime? startedAt(String sessionId, String draftId) =>
      jobs[key(sessionId, draftId)]?.startedAt;

  /// Whether anything is generating for [sessionId] — what the sheet's batch
  /// panel reads.
  bool isBusy(String sessionId) =>
      jobs.values.any((job) => job.sessionId == sessionId);

  /// The generating draft ids of one session, as the rows read them.
  Set<String> draftIdsFor(String sessionId) => {
    for (final job in jobs.values)
      if (job.sessionId == sessionId) job.draftId,
  };

  MemoryDraftJobsState copyWith({
    Map<String, MemoryDraftJob>? jobs,
    MemoryDraftJobFailure? lastFailure,
  }) => MemoryDraftJobsState(
    jobs: jobs ?? this.jobs,
    lastFailure: lastFailure ?? this.lastFailure,
  );
}

/// Owns the manual draft-generation lifecycle: the requests in flight, their
/// cancel tokens and the session leases they hold.
///
/// It lives in the provider container, not in the memory sheet. The sheet used
/// to own this, which meant closing it mid-generation threw the finished draft
/// away: the completion wrote through the sheet's own `WidgetRef`, and a ref
/// whose widget is gone throws rather than persisting. Now the request outlives
/// the sheet, the result is written straight to the repository, and reopening
/// the sheet finds the same job still running with the same start time.
class MemoryDraftJobsNotifier extends Notifier<MemoryDraftJobsState> {
  final Map<String, CancelToken> _tokens = {};
  final Map<String, MemoryDraftLease> _leases = {};
  int _failureSeq = 0;

  @override
  MemoryDraftJobsState build() => const MemoryDraftJobsState();

  bool isGenerating(String sessionId, String draftId) =>
      state.isGenerating(sessionId, draftId);

  /// Generates one draft. Returns when the request has settled; the state
  /// carries everything a reader needs meanwhile, so callers do not have to
  /// await it.
  Future<void> generate({
    required String sessionId,
    required String charId,
    required String draftId,
  }) async {
    final jobKey = MemoryDraftJobsState.key(sessionId, draftId);
    if (_tokens.containsKey(jobKey)) return;

    final repo = ref.read(memoryBookRepoProvider);
    final book = await repo.getBySessionId(sessionId);
    if (book == null) return;
    final draftIndex = book.pendingDrafts.indexWhere((d) => d.id == draftId);
    if (draftIndex < 0) return;
    final draft = book.pendingDrafts[draftIndex];

    final session = ref.read(chatProvider(charId)).value?.session;
    if (session == null) return;
    final draftMessages = session.messages
        .where((message) => draft.messageIds.contains(message.id))
        .toList();
    if (draftMessages.isEmpty) {
      _recordFailure(
        sessionId: sessionId,
        draftId: draftId,
        message: 'memory_books_messages_not_found'.tr(),
        wasRegeneration: draft.content.isNotEmpty,
      );
      return;
    }

    // Re-checked after the awaits above: two taps in the same frame both get
    // this far before either has registered a token.
    if (_tokens.containsKey(jobKey)) return;

    final token = CancelToken();
    _tokens[jobKey] = token;
    _leases[jobKey] = ref
        .read(memoryActiveDraftsProvider.notifier)
        .acquire(sessionId);
    state = state.copyWith(
      jobs: {
        ...state.jobs,
        jobKey: MemoryDraftJob(
          sessionId: sessionId,
          draftId: draftId,
          startedAt: DateTime.now(),
        ),
      },
    );

    try {
      final generated = await ref.read(memoryDraftGeneratorProvider)(
        draft: draft,
        // The global settings, not the book's snapshot: this is the manual
        // path, and the sheet's own controls write the global copy.
        settings: const MemorySettingsMapper().globalToBook(
          ref.read(memoryGlobalSettingsProvider),
        ),
        pipeline: ref.read(pipelineSettingsProvider),
        messages: draftMessages,
        charId: charId,
        sessionId: sessionId,
        sessionVars: session.sessionVars,
        cancelToken: token,
      );
      if (!_owns(jobKey, token)) return;
      await repo.mutateDraft(
        sessionId: sessionId,
        draftId: draftId,
        // The ownership check is inside the transaction as well: a cancel
        // landing while the write is in flight must not publish the result.
        mutate: (current) => _owns(jobKey, token)
            ? current.copyWith(
                content: generated.content,
                keys: generated.keys,
                keyParagraphs: generated.keyParagraphs,
                ledgerRange: generated.ledgerRange,
                status: 'pending_approval',
                generatedAt: generated.generatedAt,
                updatedAt: generated.updatedAt,
                error: null,
              )
            : current,
      );
      if (!_owns(jobKey, token)) return;
      _bumpBookRevision();
    } catch (e) {
      if (!_owns(jobKey, token)) return;
      // Normalized here, once, because both surfaces show the same string: the
      // toast, and the draft card, which keeps it until the draft is generated
      // again. `e.toString()` on a provider rejection is Dio's own explanation
      // of what a DioException is, which buries the provider's reason.
      final message = formatError(e);
      // Keep the previous content and keys on failure. If even persisting the
      // error state fails, still settle and report the generation error.
      try {
        await repo.mutateDraft(
          sessionId: sessionId,
          draftId: draftId,
          mutate: (current) => _owns(jobKey, token)
              ? current.copyWith(
                  status: 'needs_regeneration',
                  error: message,
                  updatedAt: DateTime.now().millisecondsSinceEpoch,
                )
              : current,
        );
      } catch (_) {}
      if (!_owns(jobKey, token)) return;
      _recordFailure(
        sessionId: sessionId,
        draftId: draftId,
        message: message,
        wasRegeneration: draft.content.isNotEmpty,
      );
      _bumpBookRevision();
    } finally {
      if (identical(_tokens[jobKey], token)) {
        _tokens.remove(jobKey);
        _leases.remove(jobKey)?.release();
        _clearJob(jobKey);
      }
    }
  }

  /// Generates up to the configured batch size of the drafts that still need
  /// it, staggered so the requests do not all fire at once.
  Future<void> generateBatch({
    required String sessionId,
    required String charId,
  }) async {
    final pending = await draftsNeedingGeneration(sessionId);
    final toGenerate = pending
        .take(ref.read(memoryGlobalSettingsProvider).batchSize)
        .toList();
    if (toGenerate.isEmpty) return;

    final futures = <Future<void>>[];
    for (var i = 0; i < toGenerate.length; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 2));
      futures.add(
        generate(
          sessionId: sessionId,
          charId: charId,
          draftId: toGenerate[i].id,
        ),
      );
    }
    await Future.wait(futures);
  }

  /// The drafts of [sessionId] that have no content yet and are not already
  /// being generated.
  Future<List<MemoryDraft>> draftsNeedingGeneration(String sessionId) async {
    final book = await ref
        .read(memoryBookRepoProvider)
        .getBySessionId(sessionId);
    if (book == null) return const [];
    return book.pendingDrafts
        .where(
          (draft) =>
              draft.content.isEmpty &&
              (draft.status == 'pending_generation' ||
                  draft.status == 'needs_regeneration') &&
              !state.isGenerating(sessionId, draft.id),
        )
        .toList();
  }

  void cancel(String sessionId, String draftId) {
    final jobKey = MemoryDraftJobsState.key(sessionId, draftId);
    _tokens.remove(jobKey)?.cancel();
    _leases.remove(jobKey)?.release();
    _clearJob(jobKey);
  }

  /// Whether the request under [token] is still the one this draft is waiting
  /// on — a cancel, a delete or a restart hands ownership to someone else.
  bool _owns(String jobKey, CancelToken token) =>
      !token.isCancelled && identical(_tokens[jobKey], token);

  void _clearJob(String jobKey) {
    if (!state.jobs.containsKey(jobKey)) return;
    state = state.copyWith(jobs: {...state.jobs}..remove(jobKey));
  }

  void _recordFailure({
    required String sessionId,
    required String draftId,
    required String message,
    required bool wasRegeneration,
  }) {
    state = state.copyWith(
      lastFailure: MemoryDraftJobFailure(
        sessionId: sessionId,
        draftId: draftId,
        message: message,
        wasRegeneration: wasRegeneration,
        seq: ++_failureSeq,
      ),
    );
  }

  void _bumpBookRevision() =>
      ref.read(memoryBookRevisionProvider.notifier).state++;
}

final memoryDraftJobsProvider =
    NotifierProvider<MemoryDraftJobsNotifier, MemoryDraftJobsState>(
      MemoryDraftJobsNotifier.new,
    );
