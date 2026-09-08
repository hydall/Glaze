/// A single attempt inside an auxiliary LLM call (post-cleaner, ledger,
/// tracker, or agentic search). Captured for the operations log UI so the
/// user can see retry behaviour (502 -> retry -> 200).
class AgentOperationAttempt {
  /// 1-based attempt number.
  final int attempt;

  /// HTTP status code (0 when not an HTTP error, e.g. timeout / parse error).
  final int statusCode;

  /// Short status label: 'ok' | 'http_5xx' | 'http_4xx' | 'timeout' | 'error'
  /// | 'cancelled'.
  final String status;

  /// Human-readable error text (truncated to 500 chars). Null on success.
  final String? error;

  /// Wall-clock millis for this attempt (epoch).
  final int startedAtMs;

  /// Elapsed millis for this attempt.
  final int elapsedMs;

  const AgentOperationAttempt({
    required this.attempt,
    required this.statusCode,
    required this.status,
    this.error,
    required this.startedAtMs,
    required this.elapsedMs,
  });

  factory AgentOperationAttempt.fromJson(Map<String, dynamic> json) =>
      AgentOperationAttempt(
        attempt: json['attempt'] as int? ?? 0,
        statusCode: json['statusCode'] as int? ?? 0,
        status: json['status'] as String? ?? 'error',
        error: json['error'] as String?,
        startedAtMs: json['startedAtMs'] as int? ?? 0,
        elapsedMs: json['elapsedMs'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'attempt': attempt,
    'statusCode': statusCode,
    'status': status,
    'error': error,
    'startedAtMs': startedAtMs,
    'elapsedMs': elapsedMs,
  };

  bool get isSuccess => status == 'ok';
}

/// Kinds of agentic operations tracked in the operations log.
enum AgentOperationKind {
  memorySidecar,
  postCleaner,
  agenticSearch,
  classifier,
  consolidation,
  studioTracker,
  studioFinal,
  factChecker,
  studioLedger,
  studioLedgerReconciliation;

  String get label => switch (this) {
    AgentOperationKind.memorySidecar => 'Memory sidecar',
    AgentOperationKind.postCleaner => 'POST-cleaner',
    AgentOperationKind.agenticSearch => 'Agentic search',
    AgentOperationKind.classifier => 'Classifier',
    AgentOperationKind.consolidation => 'Consolidation',
    AgentOperationKind.studioTracker => 'Studio tracker',
    AgentOperationKind.studioFinal => 'Studio final',
    AgentOperationKind.factChecker => 'Fact checker',
    AgentOperationKind.studioLedger => 'Studio Ledger',
    AgentOperationKind.studioLedgerReconciliation =>
      'Studio Ledger reconciliation',
  };
}

/// Final status of an agentic operation.
enum AgentOperationStatus {
  ok,
  disabled,
  aborted,
  timeout,
  httpError,
  invalidOutput,
  error;

  /// Whether the operation ultimately succeeded (produced a usable result).
  bool get isOk => this == AgentOperationStatus.ok;

  /// Whether the operation failed (any non-ok, non-aborted, non-disabled).
  bool get isFailure =>
      this != AgentOperationStatus.ok &&
      this != AgentOperationStatus.aborted &&
      this != AgentOperationStatus.disabled;

  String get label => switch (this) {
    AgentOperationStatus.ok => 'ok',
    AgentOperationStatus.disabled => 'disabled',
    AgentOperationStatus.aborted => 'aborted',
    AgentOperationStatus.timeout => 'timeout',
    AgentOperationStatus.httpError => 'http_error',
    AgentOperationStatus.invalidOutput => 'invalid_output',
    AgentOperationStatus.error => 'error',
  };
}

/// A single record in the agentic operations log.
///
/// Plain Dart class (not freezed) — mirrors the plain-Dart-class pattern to
/// avoid freezed-generator breakage when a second class in the same file has
/// a dependency on it. Kept immutable via [copyWith].
class AgentOperationRecord {
  /// Stable unique id (uuid or timestamp-based).
  final String id;

  /// Which agentic service produced this record.
  final AgentOperationKind kind;

  /// Final outcome of the operation.
  final AgentOperationStatus status;

  /// Session id anchor (which chat produced this call).
  final String? sessionId;

  /// Message id anchor (which message triggered / received this call).
  final String? messageId;

  /// Per-attempt details (1 for one-shot, up to 3 for retried calls).
  final List<AgentOperationAttempt> attempts;

  /// Total elapsed millis across all attempts.
  final int totalElapsedMs;

  /// Model label used for this call (for diagnostics).
  final String? model;

  /// Endpoint used (host only, no api key / path) for diagnostics.
  final String? endpoint;

  /// Short human-readable summary shown in the log list.
  final String? summary;

  /// Wall-clock millis (epoch) when the operation started.
  final int startedAtMs;

  /// Wall-clock millis (epoch) when the operation finished.
  final int finishedAtMs;

  /// Whether the operation can be retried/regenerated from the UI.
  /// True for operations with a natural user-triggered retry, such as
  /// post-cleaner regeneration. False for fire-and-forget ops.
  final bool canRegenerate;

  const AgentOperationRecord({
    required this.id,
    required this.kind,
    required this.status,
    this.sessionId,
    this.messageId,
    this.attempts = const [],
    this.totalElapsedMs = 0,
    this.model,
    this.endpoint,
    this.summary,
    required this.startedAtMs,
    required this.finishedAtMs,
    this.canRegenerate = false,
  });

  factory AgentOperationRecord.fromJson(Map<String, dynamic> json) =>
      AgentOperationRecord(
        id: json['id'] as String? ?? '',
        kind: AgentOperationKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => AgentOperationKind.memorySidecar,
        ),
        status: AgentOperationStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => AgentOperationStatus.error,
        ),
        sessionId: json['sessionId'] as String?,
        messageId: json['messageId'] as String?,
        attempts:
            (json['attempts'] as List?)
                ?.whereType<Map<dynamic, dynamic>>()
                .map(
                  (e) => AgentOperationAttempt.fromJson(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList() ??
            const [],
        totalElapsedMs: json['totalElapsedMs'] as int? ?? 0,
        model: json['model'] as String?,
        endpoint: json['endpoint'] as String?,
        summary: json['summary'] as String?,
        startedAtMs: json['startedAtMs'] as int? ?? 0,
        finishedAtMs: json['finishedAtMs'] as int? ?? 0,
        canRegenerate: json['canRegenerate'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'status': status.name,
    'sessionId': sessionId,
    'messageId': messageId,
    'attempts': attempts.map((a) => a.toJson()).toList(),
    'totalElapsedMs': totalElapsedMs,
    'model': model,
    'endpoint': endpoint,
    'summary': summary,
    'startedAtMs': startedAtMs,
    'finishedAtMs': finishedAtMs,
    'canRegenerate': canRegenerate,
  };

  AgentOperationRecord copyWith({
    String? id,
    AgentOperationKind? kind,
    AgentOperationStatus? status,
    String? sessionId,
    String? messageId,
    List<AgentOperationAttempt>? attempts,
    int? totalElapsedMs,
    String? model,
    String? endpoint,
    String? summary,
    int? startedAtMs,
    int? finishedAtMs,
    bool? canRegenerate,
  }) => AgentOperationRecord(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    sessionId: sessionId ?? this.sessionId,
    messageId: messageId ?? this.messageId,
    attempts: attempts ?? this.attempts,
    totalElapsedMs: totalElapsedMs ?? this.totalElapsedMs,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    summary: summary ?? this.summary,
    startedAtMs: startedAtMs ?? this.startedAtMs,
    finishedAtMs: finishedAtMs ?? this.finishedAtMs,
    canRegenerate: canRegenerate ?? this.canRegenerate,
  );

  /// Number of attempts actually executed (1 for one-shot, up to 3 for retry).
  int get attemptCount => attempts.length;

  /// True if any retry happened (more than one attempt).
  bool get wasRetried => attempts.length > 1;

  /// Short text for the log list tile: "POST-cleaner · ok · 2 attempts · 320ms".
  String get tileLabel {
    final retry = wasRetried ? ' · ${attempts.length} attempts' : '';
    return '${kind.label} · ${status.label}$retry · ${totalElapsedMs}ms';
  }
}
