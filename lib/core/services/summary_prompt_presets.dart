import '../llm/summary_service.dart';
import 'memory_prompt_presets.dart' show MemoryPromptPreset;

/// Ready-made summarization prompts, the way Memory Books has ready-made
/// drafting prompts.
///
/// The session stores the template itself, not a preset key, so a preset is
/// simply a text to start from: picking one fills the field, and editing it
/// afterwards is expected. [labelFor] is what tells the settings sheet which
/// preset the stored text still matches.
///
/// They carry no `{{history}}` or `{{previous_summary}}` on purpose. The
/// transcript is appended, and the summary being replaced is handed over under
/// its own heading only when there is one — a preset that placed the
/// placeholder itself would leave an empty label behind on the first run. A
/// hand-written prompt can still use both; see `SummaryService`.
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

  /// The preset [template] still is, or null when it has been edited into
  /// something of its own. An empty template is the built-in default, which is
  /// what an unset session prompt resolves to.
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
