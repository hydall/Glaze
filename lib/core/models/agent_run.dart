/// One recorded agent run (see `agent_runs`).
class AgentRun {
  final int? id;
  final String sessionId;
  final String messageId;
  final String agentId;
  final String agentName;
  final String phase;
  final String resultType;
  final bool ok;
  final String? error;
  final String output;

  /// The request as sent, JSON-encoded messages.
  final String promptJson;
  final int promptTokens;
  final int completionTokens;
  final int durationMs;

  /// Milliseconds since epoch.
  final int createdAt;

  const AgentRun({
    this.id,
    required this.sessionId,
    this.messageId = '',
    required this.agentId,
    this.agentName = '',
    required this.phase,
    required this.resultType,
    this.ok = false,
    this.error,
    this.output = '',
    this.promptJson = '[]',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.durationMs = 0,
    required this.createdAt,
  });
}
