class MemoryPromptPresets {
  static const fallbackKey = 'detailed_beats';

  static const builtIn = [
    MemoryPromptPreset(
      key: 'detailed_beats',
      label: 'Detailed beats (recommended)',
      prompt: _detailedBeats,
    ),
    MemoryPromptPreset(
      key: 'concise_narrative',
      label: 'Concise narrative',
      prompt: _conciseNarrative,
    ),
    MemoryPromptPreset(
      key: 'structured_markdown',
      label: 'Structured (markdown)',
      prompt: _structuredMarkdown,
    ),
    MemoryPromptPreset(
      key: 'minimal_factual',
      label: 'Minimal (1-2 sentences)',
      prompt: _minimalFactual,
    ),
  ];

  static String resolve(
    String? presetKey, [
    List<MemoryPromptPreset>? custom,
    bool studioTimeContract = false,
  ]) {
    final all = [...builtIn, ...?custom];
    final match = all.where((p) => p.key == presetKey).firstOrNull;
    final resolved = match ?? builtIn.first;
    if (resolved.key != fallbackKey) return resolved.prompt;
    return resolved.prompt.replaceAll(
      '{{time_contract}}',
      studioTimeContract ? _studioTimeContract : _ordinaryTimeContract,
    );
  }

  static String label(String? presetKey, [List<MemoryPromptPreset>? custom]) {
    final all = [...builtIn, ...?custom];
    final match = all.where((p) => p.key == presetKey).firstOrNull;
    return match?.label ?? builtIn.first.label;
  }

  static MemoryPromptPreset? find(
    String? presetKey, [
    List<MemoryPromptPreset>? custom,
  ]) {
    return [
      ...builtIn,
      ...?custom,
    ].where((preset) => preset.key == presetKey).firstOrNull;
  }

  static bool isBuiltIn(String key) =>
      builtIn.any((preset) => preset.key == key);

  /// Keeps a selected custom key from dangling after a custom preset is
  /// removed. Unknown keys use the same fallback as [resolve].
  static String validSelection(
    String? presetKey, [
    List<MemoryPromptPreset>? custom,
  ]) {
    return find(presetKey, custom)?.key ?? fallbackKey;
  }

  /// Repairs only a serialized MemoryBook settings prompt selection. Returning
  /// the original map for valid or missing values keeps every unrelated field
  /// byte-for-byte equivalent when callers re-encode it.
  static Map<String, dynamic> normalizeSerializedSelection(
    Map<String, dynamic> settings,
    Set<String> availableKeys,
  ) {
    final selected = settings['promptPreset'];
    if (selected is! String || availableKeys.contains(selected)) {
      return settings;
    }
    return {...settings, 'promptPreset': fallbackKey};
  }

  static const _detailedBeats = '''
Analyze the following roleplay segment and create a compact, retrieval-oriented memory entry.

LANGUAGE:
- Infer the roleplay language from the narrative prose and dialogue, not from character names, metadata labels, JSON property names, or isolated foreign phrases.
- Write every memory paragraph and every keyword in that same roleplay language.
- Preserve proper names and established terms exactly. Do not translate or transliterate them.

{{time_contract}}

CONTENT:
- Produce 3-8 self-contained paragraphs, each covering one distinct meaningful beat.
- Keep each paragraph to 2-5 concise sentences and under 650 characters.
- State each fact once only. Do not repeat the same event under separate categories such as story beat, interaction, detail, or outcome.
- Prioritize durable continuity: decisions, revelations, relationship changes, promises, plans, unresolved threads, important objects, locations, and resulting state.
- Include a concrete descriptive detail only when it will help distinguish or retrieve the beat later.
- Exclude casual OOC conversation. Include OOC only when it establishes canonical backstory, a story rule, a formatting requirement, or a scene-setting directive; integrate that fact once into the relevant paragraph.
- Describe chronology or elapsed time only when narratively important. Never invent a date, day counter, or clock time.
- Use past tense and third person. Do not add headings, section labels, bullet lists, commentary, or a separate outcome recap inside paragraph text.

KEYWORDS:
- Give every paragraph 3-7 concrete, scene-specific retrieval keys.
- Prefer locations, specific objects, organizations, distinctive phrases, revelations, plans, and unique actions.
- Do not use abstract themes, generic emotions, generic verbs, or a character name by itself.
- A key may appear on multiple paragraphs only when it genuinely retrieves each of them.

Return JSON only, without a markdown fence, in this exact shape:
{"paragraphs":[{"text":"one self-contained memory paragraph","keys":["keywords specific to this paragraph"]}]}

Keep the JSON property names exactly as shown. Do not add any other properties.

{{history}}''';

  static const _ordinaryTimeContract = '''TIME:
- This is an ordinary chat transcript without a Studio-computed clock.
- Do not infer, calculate, or invent a date, day counter, clock time, duration, or timeline range.
- Do not put time metadata in paragraph text or JSON. The application owns the entry header.''';

  static const _studioTimeContract = '''TIME — STUDIO LEDGER:
- The transcript begins with AUTHORITATIVE_LEDGER_RANGE computed by Studio Ledger. It is source metadata, not dialogue.
- Preserve that range exactly as supplied. Do not shorten, translate, normalize, recalculate, or replace any part of it.
- Do not put the range in paragraph text or JSON. The application attaches it to the saved entry header.''';

  static const _conciseNarrative = '''
Analyze the following roleplay segment and create a concise memory entry.
Preserve the original language. Do not translate. Exclude all [OOC] conversation.

Write a compact 3-5 sentence narrative summary in past tense, third person.
Focus on:
- What happened (main events and decisions)
- Key character interactions or developments
- Important outcome or state change

For keywords: provide 10-20 concrete, scene-specific keywords:
- Locations, objects, proper nouns, unique actions
- NOT abstract themes, emotions, or character names

Return plain text in this exact format:
Memory: <3-5 sentence concise narrative summary>
Keys: <10-20 comma-separated concrete keywords>

{{history}}''';

  static const _structuredMarkdown = '''
Analyze the following roleplay segment and create a structured memory entry.
Preserve the original language. Exclude all [OOC] conversation.

Use this markdown structure (skip sections if not applicable):
**Timeline**: Day/time this scene covers
**Story Beats**: Important plot events and developments
**Key Interactions**: Significant character exchanges and relationship shifts
**Notable Details**: Important objects, settings, revelations, quotes
**Outcome**: Results, emotional states, consequences

Write in past tense, third person. Be comprehensive but avoid verbatim repetition.

For keywords: generate 15-25 concrete scene-specific tags:
- Proper nouns, locations, specific objects, unique actions
- NOT abstract concepts, emotions, or character names

Return plain text in this exact format:
Memory: <structured markdown summary following the template above>
Keys: <15-25 comma-separated concrete keywords>

{{history}}''';

  static const _minimalFactual = '''
Create a minimal memory entry from the following roleplay segment.
Preserve the original language. Exclude [OOC] conversation.

Write 1-2 sentences capturing only the most important factual development.
Focus on durable outcomes: status changes, revealed facts, decisions, or relationship shifts.

For keywords: provide 5-10 most relevant concrete keywords (locations, objects, proper nouns).
Do not use abstract themes or character names.

Return plain text in this exact format:
Memory: <1-2 sentence factual summary>
Keys: <5-10 comma-separated concrete keywords>

{{history}}''';
}

class MemoryPromptPreset {
  final String key;
  final String label;
  final String prompt;

  const MemoryPromptPreset({
    required this.key,
    required this.label,
    required this.prompt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'prompt': prompt,
  };

  factory MemoryPromptPreset.fromJson(Map<String, dynamic> json) {
    return MemoryPromptPreset(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
    );
  }

  static List<MemoryPromptPreset> fromJsonList(
    List<Map<String, dynamic>> list,
  ) {
    return list.map((m) => MemoryPromptPreset.fromJson(m)).toList();
  }

  static List<Map<String, dynamic>> toJsonList(
    List<MemoryPromptPreset> presets,
  ) {
    return presets.map((p) => p.toJson()).toList();
  }
}
