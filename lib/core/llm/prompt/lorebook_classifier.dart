import '../history_assembler.dart';
import '../macro_engine.dart';
import '../../models/lorebook.dart';
import 'prompt_payload.dart';

typedef LorebookClassification = ({
  List<PromptMessage> loreBefore,
  List<PromptMessage> loreAfter,
  List<String> loreMacroBuffer,
  List<String> loreScenario,
  List<String> lorePersonality,
  List<String> loreDescription,
});

int calculateLorebookReserve(PromptPayload payload) {
  final settings = payload.lorebookSettings;
  if (settings.reserveValue <= 0) return 0;
  if (settings.reserveMode == 'percent') {
    return (payload.apiConfig.contextSize * settings.reserveValue / 100)
        .round();
  }
  return settings.reserveValue;
}

LorebookClassification classifyLorebooks(
  List<LorebookEntry> entries,
  MacroContext macroCtx,
  LorebookGlobalSettings settings,
) {
  final loreBefore = <PromptMessage>[];
  final loreAfter = <PromptMessage>[];
  final loreMacroBuffer = <String>[];
  final loreScenario = <String>[];
  final lorePersonality = <String>[];
  final loreDescription = <String>[];

  for (final entry in entries) {
    var content = replaceMacros(entry.content, macroCtx).text;
    if (content.trim().isEmpty) continue;

    final pos = entry.position == 'matchGlobal'
        ? settings.injectionPosition
        : entry.position;

    if (pos == 'charScenario') {
      loreScenario.add(content);
    } else if (pos == 'charPersonality') {
      lorePersonality.add(content);
    } else if (pos == 'charDescription') {
      loreDescription.add(content);
    } else if (pos == 'lorebooksMacro') {
      loreMacroBuffer.add(content);
    } else if (pos == 'worldInfoAfter') {
      loreAfter.add(
        PromptMessage(
          role: 'system',
          content: content,
          isLorebook: true,
          blockId: 'worldInfoAfter',
          blockName:
              'Lorebook: ${entry.comment.isNotEmpty ? entry.comment : entry.id}',
        ),
      );
    } else {
      loreBefore.add(
        PromptMessage(
          role: 'system',
          content: content,
          isLorebook: true,
          blockId: 'worldInfoBefore',
          blockName:
              'Lorebook: ${entry.comment.isNotEmpty ? entry.comment : entry.id}',
        ),
      );
    }
  }
  return (
    loreBefore: loreBefore,
    loreAfter: loreAfter,
    loreMacroBuffer: loreMacroBuffer,
    loreScenario: loreScenario,
    lorePersonality: lorePersonality,
    loreDescription: loreDescription,
  );
}
