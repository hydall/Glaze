import '../services/prompt_capture_view_service.dart';

/// What kind of work a captured request belongs to. Drives the colour and the
/// wording everywhere the timeline is rendered.
enum RequestStageFamily {
  main,
  agent,
  cleaner,
  ledger,
  memory,
  extBlock,
  card,
  summary,
  other,
}

RequestStageFamily requestStageFamily(String? stage) {
  if (stage == null || stage.isEmpty) return RequestStageFamily.other;
  if (stage == 'main') return RequestStageFamily.main;
  if (stage.startsWith('studio.')) return RequestStageFamily.agent;
  if (stage.startsWith('cleaner')) return RequestStageFamily.cleaner;
  if (stage.startsWith('ledger')) return RequestStageFamily.ledger;
  if (stage.startsWith('extblock')) return RequestStageFamily.extBlock;
  if (stage.startsWith('card') || stage.startsWith('lorebook_')) {
    return RequestStageFamily.card;
  }
  if (stage.startsWith('memory')) return RequestStageFamily.memory;
  if (stage.startsWith('summary')) return RequestStageFamily.summary;
  return RequestStageFamily.other;
}

/// One logical call in the timeline. Retries of the same call collapse into a
/// single entry — three identical rows for one failing request is noise, not
/// information; [attempts] carries the fact that it took three tries.
class RequestTimelineEntry {
  RequestTimelineEntry({required this.capture, required this.attempts});

  /// The last attempt — the one whose payload actually decided the outcome.
  final PromptCaptureView capture;
  final int attempts;

  String? get stage => capture.row.stage;
  RequestStageFamily get family => requestStageFamily(stage);
  int get createdAtMs => capture.row.createdAtMs;

  bool get failed {
    final kind = capture.transportOutcome?.kind;
    return kind != null && !kind.endsWith('succeeded');
  }
}

enum RequestGroupKind {
  /// Everything one chat turn set in motion: the main model or the agent
  /// shards, then the cleaner, the ledger, the ext blocks.
  turn,

  /// Work that is not part of a turn — a card rewrite job, a ledger
  /// reconciliation, a summary. Shown in the same timeline, in its own place in
  /// time, because "when did this run relative to my turns" is the question
  /// being asked.
  task,
}

class RequestGroup {
  RequestGroup({
    required this.key,
    required this.kind,
    required this.messageId,
    required this.entries,
  });

  final String key;
  final RequestGroupKind kind;
  final String? messageId;

  /// Execution order, oldest first — a turn reads top to bottom the way it ran.
  final List<RequestTimelineEntry> entries;

  int get startedAtMs => entries.first.createdAtMs;
  int get endedAtMs => entries.last.createdAtMs;
  int get requestCount => entries.fold(0, (sum, e) => sum + e.attempts);
  bool get hasFailure => entries.any((e) => e.failed);
  bool get hasRetry => entries.any((e) => e.attempts > 1);

  /// The family that names the group: the turn's generator, or whatever the
  /// background task is.
  RequestStageFamily get leadFamily {
    for (final entry in entries) {
      final family = entry.family;
      if (family == RequestStageFamily.main ||
          family == RequestStageFamily.agent) {
        return family;
      }
    }
    return entries.first.family;
  }
}

/// Folds raw captures into the timeline the Requests tab renders.
///
/// Grouping key, in order of preference:
/// 1. `messageId` — one chat turn. Post-generation stages set it themselves and
///    the generation stages are stamped with it once the reply is written
///    (`LlmRequestCaptureRepo.bindTurnMessageId`), so a whole turn collapses
///    into one group without guessing from timestamps.
/// 2. `pipelineRunId` — one background job (card rewrite, reconciliation).
/// 3. the row itself — a stray call with no identity of its own.
///
/// Groups come back newest-last-request first; entries inside a group run
/// oldest first.
List<RequestGroup> buildRequestTimeline(List<PromptCaptureView> captures) {
  if (captures.isEmpty) return const [];

  final byKey = <String, List<PromptCaptureView>>{};
  for (final capture in captures) {
    byKey.putIfAbsent(_groupKey(capture), () => []).add(capture);
  }

  final groups = <RequestGroup>[];
  for (final entry in byKey.entries) {
    final rows = entry.value.toList()
      ..sort((a, b) => a.row.createdAtMs.compareTo(b.row.createdAtMs));
    final collapsed = _collapseAttempts(rows);
    if (collapsed.isEmpty) continue;
    groups.add(
      RequestGroup(
        key: entry.key,
        kind: entry.key.startsWith('msg:')
            ? RequestGroupKind.turn
            : RequestGroupKind.task,
        messageId: rows.first.row.messageId,
        entries: collapsed,
      ),
    );
  }

  groups.sort((a, b) => b.endedAtMs.compareTo(a.endedAtMs));
  return groups;
}

String _groupKey(PromptCaptureView capture) {
  final row = capture.row;
  final messageId = row.messageId;
  if (messageId != null && messageId.isNotEmpty) return 'msg:$messageId';
  final runId = row.pipelineRunId;
  if (runId != null && runId.isNotEmpty) return 'run:$runId';
  return 'row:${row.id}';
}

/// One entry per logical call, carrying how many attempts it took.
List<RequestTimelineEntry> _collapseAttempts(List<PromptCaptureView> rows) {
  final order = <String>[];
  final byCall = <String, List<PromptCaptureView>>{};
  for (final row in rows) {
    final key = _callKey(row);
    if (!byCall.containsKey(key)) order.add(key);
    byCall.putIfAbsent(key, () => []).add(row);
  }
  return [
    for (final key in order)
      RequestTimelineEntry(
        capture: byCall[key]!.last,
        attempts: byCall[key]!.length,
      ),
  ];
}

String _callKey(PromptCaptureView capture) {
  final row = capture.row;
  final callId = row.callId ?? row.logicalCallId;
  if (callId != null && callId.isNotEmpty) return 'call:$callId';
  // No call identity (the main request has none): stage + agent is enough to
  // fold a retry of the same step, and distinct steps keep distinct stages.
  return 'stage:${row.stage}:${row.agentId ?? ''}';
}
