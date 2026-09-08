import 'package:flutter_riverpod/legacy.dart';

/// Live state of the tracker recovery batch, surfaced to the chat UI so
/// the user can see progress while the recovery walks the chat history.
///
/// Recovery re-runs the Studio tracker cycle for each assistant message in a
/// session. Used when tracker outputs were lost due to the `studioOutputs`
/// regression fixed in the writeAssistant restoration.
///
/// The phases are:
///   idle → running → done | error
///
/// `running` covers the batch loop. [processedMessages] / [totalMessages]
/// is the N/M progress indicator. [currentMessageIndex] is the index in
/// the session's message list of the message currently being processed.
class RecoveryState {
  final String? sessionId;
  final RecoveryPhase phase;
  final int totalMessages;
  final int processedMessages;
  final int currentMessageIndex;
  final String? currentMessageId;
  final int trackersWritten;
  final int failedMessages;
  final String? error;

  const RecoveryState({
    this.sessionId,
    this.phase = RecoveryPhase.idle,
    this.totalMessages = 0,
    this.processedMessages = 0,
    this.currentMessageIndex = -1,
    this.currentMessageId,
    this.trackersWritten = 0,
    this.failedMessages = 0,
    this.error,
  });

  bool get isActive => phase == RecoveryPhase.running;
  bool get isDone => phase == RecoveryPhase.done;
  bool get isError => phase == RecoveryPhase.error;

  const RecoveryState.idle()
    : sessionId = null,
      phase = RecoveryPhase.idle,
      totalMessages = 0,
      processedMessages = 0,
      currentMessageIndex = -1,
      currentMessageId = null,
      trackersWritten = 0,
      failedMessages = 0,
      error = null;

  const RecoveryState.running({
    required this.sessionId,
    required this.totalMessages,
    required this.processedMessages,
    required this.currentMessageIndex,
    this.currentMessageId,
    required this.trackersWritten,
    required this.failedMessages,
  }) : phase = RecoveryPhase.running,
       error = null;

  const RecoveryState.done({
    required this.sessionId,
    required this.totalMessages,
    required this.processedMessages,
    required this.trackersWritten,
    required this.failedMessages,
  }) : phase = RecoveryPhase.done,
       currentMessageIndex = -1,
       currentMessageId = null,
       error = null;

  const RecoveryState.error({
    required this.sessionId,
    required this.error,
    this.totalMessages = 0,
    this.processedMessages = 0,
    this.currentMessageIndex = -1,
    this.currentMessageId,
    this.trackersWritten = 0,
    this.failedMessages = 0,
  }) : phase = RecoveryPhase.error;
}

enum RecoveryPhase { idle, running, done, error }

/// Global recovery live state. Set by [TrackerMemoryRecoveryService.recover]
/// and watched by the recovery progress card in the Post-Building menu.
final recoveryStateProvider = StateProvider<RecoveryState>(
  (_) => const RecoveryState.idle(),
);
