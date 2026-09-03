import '../../../core/models/chat_message.dart';
import '../bridge/chat_bridge_controller.dart';
import '../chat_state.dart';
import '../services/continuation_message_merger.dart';
import 'chat_webview_sync_dispatcher.dart';

/// Restores the transient generation presentation after [setMessages] replaces
/// the WebView DOM. Unlike the regular dispatcher this is level-triggered: a
/// generation may already be active when a fresh widget attaches.
///
/// [isBusy] is the whole "a reply is on its way" window — streaming, or the
/// send that will produce it still being persisted (`ChatState.isSendPending`).
/// Reconciling on `isGenerating` alone would drop the typing bubble of a
/// session switched into during that window.
Future<void> reconcileActiveGenerationBridge({
  required ChatBridgeController bridge,
  required ChatWebViewSyncState syncState,
  required bool isBusy,
  required bool isImpersonating,
  required String? regenTargetId,
  required String? continuationTargetId,
  required StreamingState streaming,
  required List<ChatMessage> messages,
  required String streamingId,
  required bool Function() isCurrent,
}) async {
  syncState.wasBusy = isBusy;
  bridge.continuationTargetId = continuationTargetId;

  if (!isBusy || isImpersonating || !isCurrent()) {
    syncState.streamingSent = false;
    syncState.regenStreamingSent = false;
    return;
  }

  final targetId = regenTargetId ?? continuationTargetId;
  if (targetId != null) {
    final index = messages.indexWhere((message) => message.id == targetId);
    if (index < 0) return;
    final original = messages[index];
    final updated = continuationTargetId != null
        ? original.copyWith(
            content: joinContinuation(original.content, streaming.text),
            reasoning:
                joinContinuationReasoning(
                  original.reasoning,
                  streaming.reasoning,
                ) ??
                original.reasoning,
            isTyping: true,
          )
        : original.copyWith(
            content: streaming.text,
            reasoning: streaming.reasoning ?? original.reasoning,
            isTyping: true,
          );
    await bridge.updateMessage(updated);
    if (isCurrent()) syncState.regenStreamingSent = true;
    return;
  }

  final placeholder = ChatMessage(
    id: streamingId,
    role: 'assistant',
    content: streaming.text,
    reasoning: streaming.reasoning,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    isTyping: true,
  );
  if (syncState.streamingSent) {
    await bridge.updateMessage(placeholder);
  } else {
    await bridge.appendMessage(placeholder);
  }
  if (isCurrent()) syncState.streamingSent = true;
}

/// Serializes streaming bridge calls and drops completions that no longer own
/// the current generation/session epoch.
Future<void> pushStreamingMessageOwned({
  required ChatBridgeController bridge,
  required ChatMessage message,
  required ChatWebViewSyncState syncState,
  required int epoch,
  required bool Function() isCurrent,
}) async {
  bool ownsStream() => isCurrent() && syncState.streamEpoch == epoch;
  final operation = syncState.enqueueMessageMutation(() async {
    try {
      if (!ownsStream()) return;
      if (syncState.streamingSent) {
        await bridge.updateMessage(message);
      } else if (syncState.wasBusy) {
        // The first delta of a run whose placeholder append is still in
        // flight puts the bubble up itself. Only while a reply is actually on
        // its way, though: this runs on the shared mutation queue, so a delta
        // that was still crossing the channel when the run settled lands
        // *after* the falling edge removed the placeholder — and appending it
        // there stands the finished reply a second time under itself, in a
        // bubble nothing will ever take away again.
        await bridge.appendMessage(message);
      } else {
        return;
      }
      if (ownsStream()) syncState.streamingSent = true;
    } catch (_) {
      // Leave streamingSent false so a later delta can retry the append.
    }
  });
  await operation;
}
