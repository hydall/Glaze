import '../../../core/llm/macro_engine.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/utils/think_tags.dart';
import 'tts_planner.dart';
import 'tts_voice_resolver.dart';

/// Turns chat messages into what the TTS engine reads: the visible text with
/// macros expanded, and the voice-map key of whoever wrote it.
class TtsMessageInputs {
  final String charId;
  final String charName;
  final String userName;

  /// Persona used for user messages that do not name their own.
  final String? personaId;

  const TtsMessageInputs({
    required this.charId,
    required this.charName,
    required this.userName,
    this.personaId,
  });

  /// Null for messages that are never voiced (system, errors, typing).
  TtsMessageInput? of(ChatMessage m) {
    if (m.isError || m.isTyping) return null;
    final String speaker;
    if (m.role == 'assistant' || m.role == 'character') {
      speaker = ttsCharKey(charId);
    } else if (m.role == 'user') {
      speaker = ttsUserKey(m.personaId ?? personaId);
    } else {
      return null;
    }
    return TtsMessageInput(
      messageId: m.id,
      text: textOf(m.content),
      speakerKey: speaker,
    );
  }

  String textOf(String content) {
    final stripped = stripThinkTags(content);
    if (!stripped.contains('{{')) return stripped;
    return replaceMacros(
      stripped,
      MacroContext(
        charName: charName,
        userName: userName,
        charId: charId,
        sessionId: '',
      ),
    ).text;
  }
}
