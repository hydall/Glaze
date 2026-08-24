/// Stable diagnostic identity attached to an outgoing LLM request.
///
/// This is deliberately separate from `ChatTransportRequest.sessionId`, which
/// may be serialized and affect provider-side routing or prompt caching.
final class LlmCaptureContext {
  const LlmCaptureContext({
    required this.stage,
    this.sessionId,
    this.messageId,
    this.pipelineRunId,
    this.logicalCallId,
    this.relatedArtifactId,
    this.agentId,
    this.stageOrdinal,
    this.attempt,
  });

  final String stage;
  final String? sessionId;
  final String? messageId;
  final String? pipelineRunId;
  final String? logicalCallId;
  final String? relatedArtifactId;
  final String? agentId;
  final int? stageOrdinal;
  final int? attempt;

  LlmCaptureContext withAttempt(int value) => LlmCaptureContext(
    stage: stage,
    sessionId: sessionId,
    messageId: messageId,
    pipelineRunId: pipelineRunId,
    logicalCallId: logicalCallId,
    relatedArtifactId: relatedArtifactId,
    agentId: agentId,
    stageOrdinal: stageOrdinal,
    attempt: value,
  );

  Map<String, dynamic> toJson() => {
    'stage': stage,
    if (sessionId != null) 'sessionId': sessionId,
    if (messageId != null) 'messageId': messageId,
    if (pipelineRunId != null) 'pipelineRunId': pipelineRunId,
    if (logicalCallId != null) 'logicalCallId': logicalCallId,
    if (relatedArtifactId != null) 'relatedArtifactId': relatedArtifactId,
    if (agentId != null) 'agentId': agentId,
    if (stageOrdinal != null) 'stageOrdinal': stageOrdinal,
    if (attempt != null) 'attempt': attempt,
  };
}
