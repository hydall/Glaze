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
  embedding,
  image,
  plugin,
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
  if (stage.startsWith('embedding')) return RequestStageFamily.embedding;
  if (stage.startsWith('image')) return RequestStageFamily.image;
  if (stage.startsWith('memory')) return RequestStageFamily.memory;
  if (stage.startsWith('summary')) return RequestStageFamily.summary;
  if (stage.startsWith('plugin')) return RequestStageFamily.plugin;
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

/// Folds raw captures into the timeline the Requests tab renders: one row per
/// logical call, newest first, each in its own place in time.
///
/// Requests used to be folded under the message they belonged to, so a turn
/// was one card with its stages inside. That misled more than it helped: a
/// step re-run an hour later (an ext block, a ledger repair) was filed under
/// the old turn, and the turn jumped to the top of the list with the late
/// request hidden inside it. Now nothing is nested; a row still names its turn
/// in its subtitle, so the link is not lost.
///
/// Only retries of one call collapse — three identical rows for one failing
/// request is noise. A call is identified by its call id *within its owner*
/// (message, then pipeline run): call ids built from a per-run counter repeat
/// across app restarts, and must not fold unrelated turns together.
///
/// Every returned group holds exactly one entry; [RequestGroup] is kept as the
/// row type so the card and the filter read it the same way.
List<RequestGroup> buildRequestTimeline(List<PromptCaptureView> captures) {
  if (captures.isEmpty) return const [];

  final rows = captures.toList()
    ..sort((a, b) {
      final byTime = a.row.createdAtMs.compareTo(b.row.createdAtMs);
      return byTime != 0 ? byTime : a.row.id.compareTo(b.row.id);
    });

  final order = <String>[];
  final byCall = <String, List<PromptCaptureView>>{};
  // The chain currently open for each call key. An attempt number that does
  // not go up means the same id was handed out again (a counter that started
  // over), not a retry, so it opens a chain of its own.
  final openChain = <String, String>{};
  for (final row in rows) {
    final base = _callKey(row);
    var key = openChain[base];
    if (key != null && !_continuesChain(byCall[key]!.last, row)) key = null;
    if (key == null) {
      key = byCall.containsKey(base) ? '$base#${row.row.id}' : base;
      openChain[base] = key;
      order.add(key);
    }
    byCall.putIfAbsent(key, () => []).add(row);
  }

  final groups = [
    for (final key in order)
      _rowFor(
        key,
        RequestTimelineEntry(
          capture: byCall[key]!.last,
          attempts: byCall[key]!.length,
        ),
      ),
  ];
  // By the time the call was made: a retry that ran later moves its row up,
  // because its last attempt is what the row shows.
  groups.sort((a, b) {
    final byTime = b.startedAtMs.compareTo(a.startedAtMs);
    return byTime != 0
        ? byTime
        : b.entries.single.capture.row.id.compareTo(
            a.entries.single.capture.row.id,
          );
  });
  return groups;
}

/// Where the "app restart" separator goes in a newest-first timeline: the
/// index of the first row sent before this run started at [startedAtMs], so
/// the separator sits between this run's requests and the earlier ones. Null
/// when no earlier request is listed — a separator under everything would mark
/// nothing.
int? restartSeparatorIndex(List<RequestGroup> groups, int startedAtMs) {
  for (var i = 0; i < groups.length; i++) {
    if (groups[i].startedAtMs < startedAtMs) return i;
  }
  return null;
}

RequestGroup _rowFor(String key, RequestTimelineEntry entry) {
  final messageId = entry.capture.row.messageId;
  final hasMessage = messageId != null && messageId.isNotEmpty;
  return RequestGroup(
    key: key,
    kind: hasMessage ? RequestGroupKind.turn : RequestGroupKind.task,
    messageId: hasMessage ? messageId : null,
    entries: [entry],
  );
}

bool _continuesChain(PromptCaptureView last, PromptCaptureView next) {
  final previous = last.row.attempt;
  final current = next.row.attempt;
  if (previous == null || current == null) return true;
  return current > previous;
}

String _ownerKey(PromptCaptureView capture) {
  final row = capture.row;
  final messageId = row.messageId;
  if (messageId != null && messageId.isNotEmpty) return 'msg:$messageId';
  final runId = row.pipelineRunId;
  if (runId != null && runId.isNotEmpty) return 'run:$runId';
  return 'row:${row.id}';
}

String _callKey(PromptCaptureView capture) {
  final row = capture.row;
  final owner = _ownerKey(capture);
  final callId = row.callId ?? row.logicalCallId;
  if (callId != null && callId.isNotEmpty) return '$owner|call:$callId';
  // No call identity (older main requests have none): stage + agent is enough
  // to fold a retry of the same step, and distinct steps keep distinct stages.
  return '$owner|stage:${row.stage}:${row.agentId ?? ''}';
}
