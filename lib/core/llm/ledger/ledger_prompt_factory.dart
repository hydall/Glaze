import '../../models/character.dart';
import '../../models/memory_book.dart';
import '../../models/studio_config.dart';
import '../../models/tracker.dart';
import '../macro_engine.dart';
import '../studio/studio_aux_prompt_assembler.dart';
import '../studio_ledger_prompt.dart';

const _ledgerSystemPromptBlockId = 'ledger_system';

class LedgerPromptFactory {
  const LedgerPromptFactory([this._promptBuilder = const StudioLedgerPrompt()]);

  final StudioLedgerPrompt _promptBuilder;

  String buildLedgerPrompt({
    required String finalAssistantText,
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    Character? character,
    Map<String, String> entityAliases = const {},
    StudioLedgerEngine engine = StudioLedgerEngine.currentReconciled,
  }) {
    if (engine == StudioLedgerEngine.legacyTurnOnly) {
      return _promptBuilder.buildLegacyTurnOnly(
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistoryText,
        currentTrackers: currentTrackers,
        recentMemoryEntries: recentMemoryEntries,
        focalUserName: macroCtx?.userName ?? '',
      );
    }
    final hasActiveLedgerBlocks = ledgerBlocks.any(
      (block) =>
          block.id == _ledgerSystemPromptBlockId &&
          block.enabled &&
          block.injectionPoint == 'ledger' &&
          block.content.trim().isNotEmpty,
    );
    if (!hasActiveLedgerBlocks || macroCtx == null) {
      return _promptBuilder.build(
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistoryText,
        currentTrackers: currentTrackers,
        recentMemoryEntries: recentMemoryEntries,
        character: character,
        entityAliases: entityAliases,
        focalUserName: macroCtx?.userName ?? '',
      );
    }

    final trackerBlock = _promptBuilder.buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = _promptBuilder.buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);
    final cardSection = StudioLedgerPrompt.buildCharacterCardSection(character);
    final entitySection = StudioLedgerPrompt.buildEntityAliasSection(
      entityAliases,
    );

    final runtimeSuffix =
        '''
$cardSection$entitySection<current_state>
$trackerBlock
</current_state>

<existing_keys>
$keyCatalog
</existing_keys>

<existing_memory>
$memoryBlock
</existing_memory>

<recent_chat>
$recentHistoryText
</recent_chat>

<final_assistant_response>
$finalAssistantText
</final_assistant_response>

Now produce the Studio Ledger output. You MUST return BOTH blocks below.
The <glaze_memory_export> block is MANDATORY — even when there is nothing
to write, include it with empty arrays. Do not omit it under any circumstance.

Required response template (follow this exact structure):
<glaze_memory_export>
{"ops":[],"knowledgeFacts":[]}
</glaze_memory_export>
<glaze_knowledge_cleanup>
{"ops":[]}
</glaze_knowledge_cleanup>
<studio_ledger>
Compact continuity snapshot here.
</studio_ledger>

The <glaze_memory_export> block MUST come first, before <studio_ledger>.
It must contain a single JSON object with "ops" and "knowledgeFacts" arrays.
When there are no state changes or knowledge facts, output empty arrays —
do NOT skip the block.

The <glaze_knowledge_cleanup> block is OPTIONAL. Include it only when you
need to rename a descriptive alias entity to a canonical identity. Use:
{"ops":[{"op":"rename_entity","fromKey":"entity:descriptive_alias","toKey":"entity:canonical","canonicalName":"Name"}]}
Only rename placeholder/descriptive identities listed in
<existing_fact_entities>. Never rename an already-named entity to a
different name. The canonicalName must appear in the final assistant
response or recent chat.

Ops format:
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"},…],"knowledgeFacts":[]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set REPLACES the complete current value.
Never append history to a state value. Keep each value under 1200 characters.
Never write npc:*.knowledge or relationship:*.knowledge; durable propositions belong in knowledgeFacts.
Relationship trust/status/attitude and card overrides are current state and must be updated with set whenever they change.
Reuse an exact key from <current_state> or <existing_keys> for the same fact; update it with set instead of creating a synonym key.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).

Game clock (world:time, world:date, world:day):
- Maintain world:time as the current in-game time of day in 24h HH:MM format.
- Keep one complete tuple: world:date (DD.MM.YYYY), zero-based world:day, and
  world:time. Never guess a missing date or day.
- When the final response or chat implies elapsed time, advance world:time to the
  new in-game time based on how much time the narrated events would take.
- For an ordinary continuous turn with no explicit duration, advance the clock
  by 1–5 minutes. Use an explicitly narrated duration instead when available.
- The game clock only moves FORWARD. Never rewind time; flashbacks and memories
  stay in prose without touching world:time. When time passes midnight, advance
  world:day (day 0 is the first day of the story) and world:date.
- Do not invent time skips that the narrative does not support.''';

    return const StudioAuxPromptAssembler().assemble(
      blocks: ledgerBlocks,
      injectionPoint: 'ledger',
      macroCtx: macroCtx,
      runtimeSuffix: runtimeSuffix,
      skipBlockIds: {
        for (final block in ledgerBlocks)
          if (block.id != _ledgerSystemPromptBlockId) block.id,
      },
    );
  }

  String _buildMemoryBlock(List<MemoryEntry> entries) {
    if (entries.isEmpty) return '(no existing memory)';
    return entries
        .take(20)
        .map((e) {
          final keys = e.keys.isEmpty ? '' : ' [${e.keys.join(', ')}]';
          final locked = e.locked ? ' [locked]' : '';
          return '- ${e.title.isNotEmpty ? e.title : e.id}$keys$locked';
        })
        .join('\n');
  }
}
