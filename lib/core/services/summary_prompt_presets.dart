import '../llm/summary_service.dart';
import 'memory_prompt_presets.dart' show MemoryPromptPreset;

/// Ready-made prompts for retelling a run of messages as a summary block, the
/// way Memory Books has ready-made drafting prompts.
///
/// Chosen by key, like a Memory Books prompt: the selection is global
/// ([SummaryPromptSelection]) and editing a saved prompt changes it wherever
/// it is used. Built-ins are read-only; copy one to change it.
///
/// They carry no `{{history}}` or `{{previous_summary}}` on purpose. The
/// transcript goes in the user message, and the earlier summary is handed over
/// under its own heading only when there is one. A saved prompt can still use
/// both; see `SummaryService`.
///
/// Reuses [MemoryPromptPreset] as the record type — it is a key/label/prompt
/// triple with no memory in it beyond the name.
class SummaryPromptPresets {
  const SummaryPromptPresets._();

  static const fallbackKey = 'recap';

  static const builtIn = [
    MemoryPromptPreset(
      key: fallbackKey,
      label: 'Recap (recommended)',
      prompt: defaultSummaryPrompt,
    ),
    MemoryPromptPreset(
      key: 'state_of_play',
      label: 'State of play',
      prompt: _stateOfPlay,
    ),
    MemoryPromptPreset(
      key: 'bullet_facts',
      label: 'Bullet facts',
      prompt: _bulletFacts,
    ),
    MemoryPromptPreset(
      key: 'minimal',
      label: 'Minimal (2-3 sentences)',
      prompt: _minimal,
    ),
  ];

  static List<MemoryPromptPreset> all([List<MemoryPromptPreset>? custom]) => [
    ...builtIn,
    ...?custom,
  ];

  /// The preset [key] names; the built-in default when it names none.
  static MemoryPromptPreset resolve(
    String? key, [
    List<MemoryPromptPreset>? custom,
  ]) => _find(all(custom), key) ?? builtIn.first;

  /// The preset [template] still is, or null when it is text of its own. An
  /// empty template is the built-in default, which is what an unset session
  /// prompt resolves to.
  static MemoryPromptPreset? match(
    String? template, [
    List<MemoryPromptPreset>? custom,
  ]) {
    final text = template?.trim() ?? '';
    if (text.isEmpty) return builtIn.first;
    return all(custom).where((p) => p.prompt.trim() == text).firstOrNull;
  }

  static const _stateOfPlay = '''
Write a running state of this roleplay, in the language the roleplay is written in.

Cover, each in its own short paragraph and only when the conversation gives you something to say:
- Where the scene stands right now: place, time of day, who is present.
- What has happened that still matters, in the order it happened.
- What each character wants, believes, and is hiding.
- Open threads: promises made, questions unanswered, dangers not yet resolved.

Keep proper names and established terms exactly as they appear. State facts plainly; do not invent, and do not comment on the summary itself.
''';

  static const _bulletFacts = '''
Extract what is established in this roleplay as a flat list of facts, in the language the roleplay is written in.

- One fact per line, starting with "- ".
- Each line stands on its own and names who or what it is about.
- Record only what the conversation establishes: events, relationships, decisions, injuries, possessions, places, promises.
- Keep proper names and established terms exactly as they appear.
- No preamble, no closing remark, no speculation.
''';

  static const _minimal = '''
Summarize this roleplay in two or three sentences, in the language the roleplay is written in: where the story stands, and the one or two things that matter most for what happens next. Keep proper names exactly as they appear. No preamble.
''';
}

/// Ready-made prompts for merging adjacent summary blocks a level up. Same
/// rules as [SummaryPromptPresets]: chosen by key, built-ins read-only.
///
/// `{{target_tokens}}` places the size target; without it the target is
/// appended.
class SummaryMergePromptPresets {
  const SummaryMergePromptPresets._();

  static const fallbackKey = 'continuity';

  static const builtIn = [
    MemoryPromptPreset(
      key: fallbackKey,
      label: 'Keep continuity (recommended)',
      prompt: summaryMergePrompt,
    ),
    MemoryPromptPreset(key: 'tight', label: 'Tight', prompt: _tight),
  ];

  static List<MemoryPromptPreset> all([List<MemoryPromptPreset>? custom]) => [
    ...builtIn,
    ...?custom,
  ];

  static MemoryPromptPreset resolve(
    String? key, [
    List<MemoryPromptPreset>? custom,
  ]) => _find(all(custom), key) ?? builtIn.first;

  static const _tight = '''
You are given consecutive parts of the summary of one roleplay, oldest first. Merge them into one short summary, in the language they are written in.

- Keep only what the story still needs: where things stand, who is who to each other, what is still open, and what caused the big changes.
- Retell finished events in a line each, by their outcome.
- Never present a thread that was resolved as open again.
- Keep proper names and established terms exactly as written.
- Add nothing that the parts do not say. No preamble.
''';
}

MemoryPromptPreset? _find(List<MemoryPromptPreset> presets, String? key) =>
    key == null ? null : presets.where((p) => p.key == key).firstOrNull;
