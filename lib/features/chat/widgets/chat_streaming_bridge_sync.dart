import '../../../core/models/chat_message.dart';
import '../bridge/chat_bridge_controller.dart';
import 'chat_webview_sync_dispatcher.dart';

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
      } else {
        await bridge.appendMessage(message);
      }
      if (ownsStream()) syncState.streamingSent = true;
    } catch (_) {
      // Leave streamingSent false so a later delta can retry the append.
    }
  });
  await operation;
}
