import '../models/character.dart';
import '../models/preset.dart';
import 'macro_engine.dart';
import 'prompt_block_resolver.dart';
import 'tokenizer.dart';

/// Block ids whose injected payload comes from character/persona, not preset text.
const presetExternalInjectionBlockIds = <String>{
  'char_card',
  'char_personality',
  'scenario',
  'example_dialogue',
  'user_persona',
  'summary',
  'memory',
};

bool isPresetExternalInjectionBlock(String blockId) =>
    presetExternalInjectionBlockIds.contains(blockId);

/// Joins all `{{setvar::}}` / `{{setglobalvar::}}` payload values for token
/// accounting when a block resolves to empty output but defines variables.
String setvarDefinitionsForAccounting(String raw) {
  final values = <String>[];
  for (final keyword in const ['setvar', 'setglobalvar']) {
    values.addAll(extractSetvarPayloads(raw, keyword));
  }
  return values.join('\n\n');
}

/// Token count for preset list / editor: only in-preset text (macros resolved,
/// external character/lorebook/memory injections blanked).
int presetOnlyTokenCount(Preset preset) {
  final notify = NotifyObj();
  var sessionVars = <String, String>{};
  var globalVars = <String, String>{};
  final baseCtx = MacroContext(
    charName: '',
    charId: '',
    sessionId: '',
    userName: '',
  ).forPresetAccounting();

  var total = 0;
  for (final block in preset.blocks) {
    if (!block.enabled || block.isStashed || block.content.isEmpty) continue;

    final resolved = resolveBlockContent(
      id: block.id,
      rawContent: block.content,
      role: block.role,
      char: Character(id: '', name: ''),
      persona: null,
      macroCtx: baseCtx.copyWith(
        sessionVars: sessionVars,
        globalVars: globalVars,
      ),
      sessionVars: sessionVars,
      globalVars: globalVars,
      summaryContent: null,
      summaryPrefix: null,
      notifyObj: notify,
    );

    if (notify.varsChanged) {
      sessionVars = Map<String, String>.from(notify.sessionVars);
      globalVars = Map<String, String>.from(notify.globalVars);
      notify.varsChanged = false;
    }

    if (resolved == null) continue;
    final acc = resolved.contentForAccounting.trim();
    if (acc.isNotEmpty) total += estimateTokens(acc);
  }
  return total;
}
