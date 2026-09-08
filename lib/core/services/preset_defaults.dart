import '../models/preset.dart';

/// Default guided-generation wrapper, mirrors hydall/Glaze
/// `guidedGenerationPrompt`. Used as the `guided_generation` block content and
/// for guided swipes. `{{guidance}}` is replaced with the user's instruction.
const kDefaultGuidedGenerationPrompt =
    '[Generate your next reply according to these instructions: {{guidance}}]';

/// Default guided-impersonation wrapper, mirrors hydall/Glaze
/// `guidedImpersonationPrompt`. Applied when impersonation runs with a
/// guidance instruction.
const kDefaultGuidedImpersonationPrompt =
    '[Instead of replying for {{char}}, impersonate {{user}} according to '
    'these instructions: {{guidance}}]';

/// Legacy default the `guided_generation` block shipped with before parity with
/// Glaze. Presets still carrying it verbatim are upgraded on load so guided
/// generation/swipe reads exactly like Glaze.
const kLegacyGuidedGenerationBlockContent = '[System Note: {{guidance}}]';

const mandatoryBlocks = <PresetBlock>[
  PresetBlock(id: 'worldInfoBefore', name: 'World Info Before', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'user_persona', name: 'User Persona', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'char_card', name: 'Character Card', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'char_personality', name: 'Character Personality', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'scenario', name: 'Scenario', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'example_dialogue', name: 'Dialogue Examples', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'worldInfoAfter', name: 'World Info After', role: 'system', content: '', enabled: true, isStatic: true),
  PresetBlock(id: 'chat_history', name: 'Chat History', role: 'system', content: '', enabled: true, isStatic: true),
];

List<PresetBlock> defaultPresetBlocks({String mainPrompt = "Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}."}) {
  return [
    PresetBlock(id: 'main', name: 'Main Prompt', role: 'system', content: mainPrompt, enabled: true),
    ...mandatoryBlocks.where((b) => b.id != 'chat_history'),
    PresetBlock(id: 'memory', name: 'Memory Book', role: 'system', content: '', enabled: true, isStatic: true),
    PresetBlock(id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, depth: 4, insertionMode: 'depth', prefix: 'Summary: '),
    PresetBlock(id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, insertionMode: 'relative'),
    PresetBlock(id: 'guided_generation', name: 'Guided Generation', role: 'system', content: kDefaultGuidedGenerationPrompt, enabled: true, isStatic: true, insertionMode: 'relative'),
    mandatoryBlocks.firstWhere((b) => b.id == 'chat_history'),
  ];
}

Preset finalizeImportedPreset(Preset preset) {
  final blocks = List<PresetBlock>.from(preset.blocks);
  final existingIds = blocks.map((b) => b.id).toSet();

  for (final mb in mandatoryBlocks) {
    if (!existingIds.contains(mb.id)) {
      final chatHistoryIdx = blocks.indexWhere((b) => b.id == 'chat_history');
      if (chatHistoryIdx != -1 && mb.id != 'chat_history') {
        blocks.insert(chatHistoryIdx, mb);
      } else {
        blocks.add(mb);
      }
      existingIds.add(mb.id);
    }
  }

  if (!existingIds.contains('memory')) {
    final chatHistoryIdx = blocks.indexWhere((b) => b.id == 'chat_history');
    final insertIdx = chatHistoryIdx != -1 ? chatHistoryIdx : blocks.length;
    blocks.insert(insertIdx, const PresetBlock(id: 'memory', name: 'Memory Book', role: 'system', content: '', enabled: true, isStatic: true));
    existingIds.add('memory');
  }

  if (!existingIds.contains('summary')) {
    final chatHistoryIdx = blocks.indexWhere((b) => b.id == 'chat_history');
    final insertIdx = chatHistoryIdx != -1 ? chatHistoryIdx : blocks.length;
    blocks.insert(insertIdx, const PresetBlock(id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, depth: 4, insertionMode: 'depth', prefix: 'Summary: '));
  }

  if (!existingIds.contains('authors_note')) {
    final chatHistoryIdx = blocks.indexWhere((b) => b.id == 'chat_history');
    final insertIdx = chatHistoryIdx != -1 ? chatHistoryIdx + 1 : blocks.length;
    blocks.insert(insertIdx, const PresetBlock(id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, insertionMode: 'relative'));
  }

  if (!existingIds.contains('guided_generation')) {
    final authorsIdx = blocks.indexWhere((b) => b.id == 'authors_note');
    final chatHistoryIdx = blocks.indexWhere((b) => b.id == 'chat_history');
    final insertIdx = authorsIdx != -1 ? authorsIdx + 1 : (chatHistoryIdx != -1 ? chatHistoryIdx + 1 : blocks.length);
    blocks.insert(insertIdx, const PresetBlock(id: 'guided_generation', name: 'Guided Generation', role: 'system', content: kDefaultGuidedGenerationPrompt, enabled: true, isStatic: true, insertionMode: 'relative'));
  }

  return preset.copyWith(blocks: blocks);
}
