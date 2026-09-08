import '../../../../core/llm/beauty_state_parser.dart' show beautyStateVarKey;
import '../../../../core/models/chat_message.dart';

/// Extracts Beauty Shard brief and state from a chat message's studioOutputs
/// and a session's vars.
///
/// The Beauty Shard brief is emitted by the "beauty" Studio agent inside the
/// assistant message's `studioOutputs`. The current styling state is stored
/// in the session vars under `beautyStateVarKey`.
class BeautyStateHandler {
  /// Extracts the beauty brief from [message]'s `studioOutputs`.
  ///
  /// Matches agents whose `agentId` is `"beauty"` or whose `agentName`
  /// contains `"beauty shard"` or `"beauty"`. Returns empty string when no
  /// beauty brief is found.
  static String extractBeautyBrief(ChatMessage message) {
    for (final output in message.studioOutputs) {
      // Field names match studioOutputsToJson() in studio_stream_interceptor.dart:
      // {'id': agentId, 'name': agentName, 'content': brief}.
      final agentId = (output['id'] ?? '').toString().toLowerCase();
      final agentName =
          (output['name'] ?? '').toString().toLowerCase();
      final brief = (output['content'] ?? '').toString();
      if ((agentId.contains('beauty') ||
          agentName.contains('beauty shard') ||
          agentName.contains('beauty')) &&
          brief.trim().isNotEmpty) {
        return brief;
      }
    }
    return '';
  }

  /// Reads the current beauty state JSON from [sessionVars].
  ///
  /// Returns `null` when no beauty state has been stored yet.
  static String? extractBeautyState(Map<String, dynamic> sessionVars) {
    return sessionVars[beautyStateVarKey] as String?;
  }
}
