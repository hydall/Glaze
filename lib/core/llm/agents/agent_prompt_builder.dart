import '../../models/agent_definition.dart';
import '../../models/chat_message.dart';
import '../macro_engine.dart';

/// Builds the request of one agent: its prompt blocks with macros resolved,
/// and the latest [AgentDefinition.contextSize] chat messages as a transcript.
///
/// The transcript stands in wherever a block writes `{{history}}`; when no
/// block does, it is sent as a closing user message. A request always ends
/// with a user message, which every provider accepts.
class AgentPromptBuilder {
  const AgentPromptBuilder();

  static const historyMacro = '{{history}}';

  List<Map<String, String>> build({
    required AgentDefinition agent,
    required MacroContext macroContext,
    required List<ChatMessage> history,
  }) {
    final transcript = transcriptOf(
      history,
      limit: agent.contextSize,
      userName: macroContext.userName,
      charName: macroContext.macroName ?? macroContext.charName,
    );
    final messages = <Map<String, String>>[];
    var historyPlaced = false;
    for (final block in agent.activeBlocks) {
      if (!block.enabled) continue;
      var content = block.content;
      if (content.contains(historyMacro)) {
        content = content.replaceAll(historyMacro, transcript);
        historyPlaced = true;
      }
      content = replaceMacros(content, macroContext).text.trim();
      if (content.isEmpty) continue;
      final role = switch (block.role) {
        'user' || 'assistant' => block.role,
        _ => 'system',
      };
      messages.add({'role': role, 'content': content});
    }
    if (!historyPlaced) {
      messages.add({
        'role': 'user',
        'content': transcript.isEmpty
            ? '(The chat has no messages yet.)'
            : '<chat_history>\n$transcript\n</chat_history>',
      });
    } else if (messages.isEmpty || messages.last['role'] != 'user') {
      messages.add({'role': 'user', 'content': 'Respond now.'});
    }
    return messages;
  }

  /// The last [limit] visible messages as `Name: text` lines.
  static String transcriptOf(
    List<ChatMessage> history, {
    required int limit,
    required String userName,
    required String charName,
  }) {
    final visible = [
      for (final message in history)
        if (!message.isHidden &&
            !message.isError &&
            !message.isTyping &&
            message.content.trim().isNotEmpty &&
            (message.role == 'user' || message.role == 'assistant'))
          message,
    ];
    final count = limit < 1 ? 1 : limit;
    final window = visible.length <= count
        ? visible
        : visible.sublist(visible.length - count);
    return window
        .map((message) {
          final name = message.role == 'user'
              ? (message.personaName?.trim().isNotEmpty == true
                    ? message.personaName!.trim()
                    : userName)
              : charName;
          return '$name: ${message.content.trim()}';
        })
        .join('\n\n');
  }
}
