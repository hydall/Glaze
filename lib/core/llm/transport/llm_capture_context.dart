/// Identifies every request made by one generation, before the assistant
/// message it produces exists.
///
/// The reply is written only after the stream ends, so the main request (and
/// the agent shards that precede it) cannot carry a message id at send time.
/// They carry this instead, and `LlmRequestCaptureRepo.bindTurnMessageId`
/// stamps the message id over them once the write lands — after which one
/// turn is one `messageId` across every stage that took part in it.
String turnRunId(String sessionId, int genId) => 'turn:$sessionId:$genId';

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
    this.callId,
    this.parentCallId,
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
  final String? callId;
  final String? parentCallId;
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
    callId: callId,
    parentCallId: parentCallId,
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
    if (callId != null) 'callId': callId,
    if (parentCallId != null) 'parentCallId': parentCallId,
    if (logicalCallId != null) 'logicalCallId': logicalCallId,
    if (relatedArtifactId != null) 'relatedArtifactId': relatedArtifactId,
    if (agentId != null) 'agentId': agentId,
    if (stageOrdinal != null) 'stageOrdinal': stageOrdinal,
    if (attempt != null) 'attempt': attempt,
  };

  LlmCaptureContext withCallIdentity({
    required String pipelineRunId,
    required String callId,
  }) => LlmCaptureContext(
    stage: stage,
    sessionId: sessionId,
    messageId: messageId,
    pipelineRunId: pipelineRunId,
    callId: callId,
    parentCallId: parentCallId,
    logicalCallId: logicalCallId,
    relatedArtifactId: relatedArtifactId,
    agentId: agentId,
    stageOrdinal: stageOrdinal,
    attempt: attempt,
  );
}
