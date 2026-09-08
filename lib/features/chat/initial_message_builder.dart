import '../../core/llm/macro_engine.dart';
import '../../core/models/character.dart';
import '../../core/models/chat_message.dart';
import '../../core/utils/id_generator.dart';
import '../../core/models/persona.dart';

class InitialMessageBuilder {
  static List<ChatMessage> build({
    required Character? character,
    required Persona? persona,
    required String sessionId,
  }) {
    final greetings = resolveGreetings(
      character: character,
      persona: persona,
      sessionId: sessionId,
    );
    if (greetings.isEmpty) return [];
    return [
      ChatMessage(
        id: generateId(),
        role: 'assistant',
        content: greetings.first,
        greetingIndex: 0,
        swipes: [greetings.first],
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  static List<String> resolveGreetings({
    required Character? character,
    required Persona? persona,
    required String sessionId,
  }) {
    if (character == null) return const [];
    final raw = <String>[
      if ((character.firstMes ?? '').isNotEmpty) character.firstMes!,
      ...character.alternateGreetings.where((g) => g.isNotEmpty),
    ];
    if (raw.isEmpty) return const [];
    final macroCtx = MacroContext(
      charName: character.name,
      charDescription: character.description,
      charScenario: character.scenario,
      charPersonality: character.personality,
      charMesExample: character.mesExample,
      userName: persona?.name ?? 'User',
      personaPrompt: persona?.prompt,
      charId: character.id,
      sessionId: sessionId,
      macroName: character.macroName,
    );
    return raw.map((g) => replaceMacros(g, macroCtx).text).toList();
  }
}
