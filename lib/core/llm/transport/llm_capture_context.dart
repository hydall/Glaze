/// Identifies every request made by one generation, before the assistant
/// message it produces exists.
///
/// The reply is written only after the stream ends, so the main request (and
/// the agent shards that precede it) cannot carry a message id at send time.
/// They carry this instead, and `LlmRequestCaptureRepo.bindTurnMessageId`
/// stamps the message id over them once the write lands — after which one
/// turn is one `messageId` across every stage that took part in it.
String turnRunId(String sessionId, int genId) => 'turn:$sessionId:$genId';

/// The call id of a turn's **main** request — the one that writes the reply.
///
/// A captured request is joined to its call events by `callId`, and an event
/// whose callId is null is dropped rather than stored
/// (`LlmRequestCaptureRepo._recordCallEvent`). The main request used to carry
/// none, so it recorded no outcome at all and the inspector's Response tab
/// could only ever say "nothing captured" for the one request a reader most
/// wants to see.
///
/// One id per turn, derived rather than generated, so it is the same value on
/// both sides of the join and stays stable if the turn is described twice.
/// Retries within a turn are distinguished by `attempt`, which is what the
/// call-event table is keyed on alongside the id.
String mainCallId(String sessionId, int genId) => 'call:main:$sessionId:$genId';

/// The capture context for a turn's **main** request — the one that writes the
/// reply.
///
/// Every field here is load-bearing for a reader, which is why they are set in
/// one named place rather than inline at the call site:
///
/// * `stage` and `sessionId` keep the request out of the session-less bucket,
///   so a per-chat view can show it at all.
/// * `pipelineRunId` groups it with the agent shards of the same turn.
/// * `callId` is what a captured request is joined to its outcome by, and an
///   event carrying none is dropped rather than stored.
/// * `attempt` is the other half of that key: a row whose attempt is null
///   matches no event, so the outcome would be recorded and still not found.
///
/// [messageId] is null for an ordinary turn — the assistant message does not
/// exist yet — and carries the target when a regenerate or a continue is
/// rewriting one that does.
LlmCaptureContext mainCaptureContext({
  required String sessionId,
  required int genId,
  String? messageId,
}) => LlmCaptureContext(
  stage: 'main',
  sessionId: sessionId,
  messageId: messageId,
  pipelineRunId: turnRunId(sessionId, genId),
  callId: mainCallId(sessionId, genId),
  // One attempt: this stream has no retry runner, and a failure is surfaced
  // to the reader rather than retried behind their back.
  attempt: 1,
);

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
