class MemoryPromptPresets {
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

  static String resolve(String? presetKey, [List<MemoryPromptPreset>? custom]) {
    final all = [...builtIn, ...?custom];
    final match = all.where((p) => p.key == presetKey).firstOrNull;
    return match?.prompt ?? _detailedBeats;
  }

  static String label(String? presetKey, [List<MemoryPromptPreset>? custom]) {
    final all = [...builtIn, ...?custom];
    final match = all.where((p) => p.key == presetKey).firstOrNull;
    return match?.label ?? builtIn.first.label;
  }

  static const _detailedBeats = '''
Analyze the following roleplay segment and create a structured memory entry.
Preserve the original language. Exclude casual [OOC] conversation, BUT if OOC messages contain story rules, formatting instructions, backstory clarifications, or scene-setting directives, reflect those instructions in the memory entry under the relevant sections.

Use this markdown structure (skip sections if not applicable):
Timeline: Always label as "Day N" (Day 1, Day 2, Day 3, etc.) — increment the day counter each time a new in-story day begins. Write clock times HH:MM;  If the scene spans multiple days, write "Day N–M HH:MM-HH:MM".
Story Beats: Important plot events and developments
Key Interactions: Significant character exchanges and relationship shifts
Notable Details: Important objects, settings, revelations, quotes
OOC Rules & Directives: Any player-established rules, formatting requirements, backstory additions, or scene-setting instructions given through OOC
Outcome: Results, emotional states, consequences

Write in past tense, third person. Be comprehensive but avoid verbatim repetition.

For keywords: generate 15-25 concrete scene-specific tags:
- Proper nouns, locations, specific objects, unique actions
- NOT abstract concepts, emotions, or character names

Return plain text in this exact format:
Memory: <structured markdown summary following the template above>
Keys: <15-25 comma-separated concrete keywords>

{{history}}''';

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

  Map<String, dynamic> toJson() => {'key': key, 'label': label, 'prompt': prompt};

  factory MemoryPromptPreset.fromJson(Map<String, dynamic> json) {
    return MemoryPromptPreset(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
    );
  }

  static List<MemoryPromptPreset> fromJsonList(List<Map<String, dynamic>> list) {
    return list.map((m) => MemoryPromptPreset.fromJson(m)).toList();
  }

  static List<Map<String, dynamic>> toJsonList(List<MemoryPromptPreset> presets) {
    return presets.map((p) => p.toJson()).toList();
  }
}
