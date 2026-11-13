import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/llm_request_capture_repo.dart';
import '../../../core/state/db_provider.dart';

final class PromptCaptureView {
  const PromptCaptureView({
    required this.row,
    required this.request,
    required this.event,
    required this.callEvents,
  });

  final LlmRequestCaptureRow row;
  final Map<String, dynamic> request;
  final Map<String, dynamic> event;
  final List<LlmCallEventRow> callEvents;

  LlmCallEventRow? get transportOutcome {
    for (final item in callEvents) {
      if (item.attempt == row.attempt && item.kind.startsWith('transport_')) {
        return item;
      }
    }
    return null;
  }

  /// What came back for this request, when the call events kept it.
  ///
  /// The transport outcome of this very attempt is the honest answer; a parser
  /// verdict's copy is the fallback for the attempts whose transport event
  /// recorded no body. Null when nothing was captured — a stream that was
  /// aborted, or a row from before response capture existed.
  String? get responseText {
    final outcome = transportOutcome?.responseText;
    if (outcome != null && outcome.isNotEmpty) return outcome;
    for (final item in callEvents) {
      final text = item.responseText;
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  /// The transport error of this attempt, when it failed.
  String? get responseError {
    final error = transportOutcome?.error;
    return error == null || error.isEmpty ? null : error;
  }

  List<LlmCallEventRow> get parserVerdicts => [
    for (final item in callEvents)
      if (item.kind.startsWith('parser_')) item,
  ];

  List<Map<String, dynamic>> get messages {
    final value = request['messages'];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map)
          Map<String, dynamic>.unmodifiable(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
  }

  String get formattedJson => const JsonEncoder.withIndent('  ').convert(event);

  static PromptCaptureView? tryParse(
    LlmRequestCaptureRow row, {
    List<LlmCallEventRow> callEvents = const [],
  }) {
    try {
      final decoded = jsonDecode(row.eventJson);
      if (decoded is! Map) return null;
      final event = Map<String, dynamic>.from(decoded);
      return PromptCaptureView(
        row: row,
        request: event,
        event: event,
        callEvents: List.unmodifiable(callEvents),
      );
    } catch (_) {
      return null;
    }
  }
}

final class PromptCaptureViewService {
  const PromptCaptureViewService(this._repo);

  final LlmRequestCaptureRepo _repo;

  /// The chat's own requests plus the session-less embedding ones (lorebook
  /// indexing), newest first. Indexing runs outside any chat, and without
  /// them the inspector never showed what it sent.
  ///
  /// Reads the whole per-session retention window — the repo keeps
  /// [LlmRequestCaptureRepo.maxRowsPerSession] rows, so asking for a shorter
  /// page silently hid every turn older than the newest handful of requests.
  Future<List<PromptCaptureView>> load(String sessionId) async {
    final rowsFuture = _repo.newestForSession(
      sessionId,
      limit:
          LlmRequestCaptureRepo.maxRowsPerSession +
          LlmRequestCaptureRepo.maxPluginRequestsPerSession,
    );
    final sharedFuture = _repo.newestEmbeddingsWithoutSession();
    final eventsFuture = _repo.newestCallEventsForSession(sessionId);
    final rows = [...await rowsFuture, ...await sharedFuture]
      ..sort((a, b) {
        final byTime = b.createdAtMs.compareTo(a.createdAtMs);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
    final events = await eventsFuture;
    final eventsByCall = <String, List<LlmCallEventRow>>{};
    for (final event in events.reversed) {
      eventsByCall.putIfAbsent(event.callId, () => []).add(event);
    }
    final rowsByCall = <String, List<LlmRequestCaptureRow>>{};
    for (final row in rows.reversed) {
      final callId = row.callId;
      if (callId != null) rowsByCall.putIfAbsent(callId, () => []).add(row);
    }
    return [
      for (final row in rows)
        ?PromptCaptureView.tryParse(
          row,
          callEvents: eventsForRow(
            row,
            sameCallRows: row.callId == null
                ? const []
                : rowsByCall[row.callId]!,
            callEvents: row.callId == null
                ? const []
                : eventsByCall[row.callId] ?? const [],
          ),
        ),
    ];
  }

  /// The call events that belong to [row], out of every event sharing its
  /// call id.
  ///
  /// A call id is not always unique over time: the main request's id was built
  /// from a generation counter that starts over with every app run, so several
  /// turns can share one. Joining on the id alone gave a new request every old
  /// turn's outcome, and the view showed the oldest. An event is taken as this
  /// row's only if it was recorded at or after the row was sent, and before the
  /// next row with the same id *and the same attempt* was — that next row is a
  /// different run of the call, not a retry of this one.
  ///
  /// [sameCallRows] and [callEvents] are oldest first.
  static List<LlmCallEventRow> eventsForRow(
    LlmRequestCaptureRow row, {
    required List<LlmRequestCaptureRow> sameCallRows,
    required List<LlmCallEventRow> callEvents,
  }) {
    if (callEvents.isEmpty) return const [];
    int? untilMs;
    for (final other in sameCallRows) {
      if (other.id == row.id || other.attempt != row.attempt) continue;
      final later =
          other.createdAtMs > row.createdAtMs ||
          (other.createdAtMs == row.createdAtMs && other.id > row.id);
      if (later && (untilMs == null || other.createdAtMs < untilMs)) {
        untilMs = other.createdAtMs;
      }
    }
    return [
      for (final event in callEvents)
        if (event.createdAtMs >= row.createdAtMs &&
            (untilMs == null || event.createdAtMs < untilMs))
          event,
    ];
  }
}

final promptCaptureViewServiceProvider = Provider<PromptCaptureViewService>(
  (ref) => PromptCaptureViewService(ref.watch(llmRequestCaptureRepoProvider)),
);

final promptCaptureViewsProvider = FutureProvider.autoDispose
    .family<List<PromptCaptureView>, String>(
      (ref, sessionId) =>
          ref.watch(promptCaptureViewServiceProvider).load(sessionId),
    );
