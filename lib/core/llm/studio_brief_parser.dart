import 'dart:convert';

import '../models/studio_config.dart';
import 'json_repair.dart';

const _studioMetaPolicyAgentName = 'Meta-Weaver / OOC Policy';

/// Parses a raw intermediate-agent LLM response into a clean, typed Studio
/// brief — or a safe controller fallback when the model leaked scene prose.
/// Extracted from `MemoryStudioService` (plan §2).
///
/// Pure except for a [log] sink injected via the constructor (so the
/// `[Studio]` diagnostics for rejected/leaked briefs are unchanged). Also owns
/// the meta-policy brief helpers shared by the cache, executor, and deduper.
class StudioBriefParser {
  final void Function(String message) _log;

  StudioBriefParser(this._log);

  /// True if [agent] is the meta-weaver / OOC policy controller.
  bool isMetaPolicyAgent(StudioAgent agent) {
    final text = '${agent.id}\n${agent.name}\n${agent.sourceBlockNames}'
        .toLowerCase();
    return text.contains('meta-weaver') ||
        text.contains('meta weaver') ||
        text.contains('ooc policy') ||
        text.contains('lumia') ||
        text.contains('ghost in the machine');
  }

  /// The canonical silent meta-policy brief.
  String metaPolicyBrief(StudioAgent agent) {
    final buffer = StringBuffer()
      ..writeln('Meta policy:')
      ..writeln('- Silent during normal in-character roleplay.')
      ..writeln('- Never write scene prose, dialogue, actions, or narration.')
      ..writeln('- Do not draft or continue the assistant reply.')
      ..writeln(
        '- Apply only as hidden policy for continuity, tone, and OOC routing.',
      )
      ..writeln(
        '- If the user explicitly addresses OOC / the meta-persona / meta, answer as an OOC interface; otherwise stay invisible.',
      );
    return buffer.toString().trim();
  }

  /// Sanitize an intermediate agent's raw output into a typed/section brief, or
  /// replace it with a safe controller fallback if it leaked scene prose.
  String sanitizeIntermediateAgentOutput(StudioAgent agent, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    if (isMetaBriefName(agent.name)) return sanitizeMetaBrief(trimmed);
    final typed = _typedStudioBrief(agent, trimmed);
    if (typed != null) return typed;
    final sectioned = sectionStudioBrief(trimmed);
    if (sectioned != null) return sectioned;
    final fieldBased = _fieldBasedBrief(trimmed);
    if (fieldBased != null) return fieldBased;

    final fallback = _safeControllerFallback(agent);
    _log(
      'brief leaked scene prose; replacing agent="${agent.name}" '
      'chars=${trimmed.length} first200=${trimmed.substring(0, trimmed.length > 200 ? 200 : trimmed.length)}',
    );
    return fallback;
  }

  /// Parse a field-based brief (lines like `key: value`) into Focus/Constraints/
  /// Avoid sections. Recognizes common controller field names and maps them to
  /// the appropriate section. Returns null if the text does not look like a
  /// field-based brief or if it looks like scene prose.
  String? _fieldBasedBrief(String text) {
    if (looksLikeSceneProse(text)) return null;

    // Require at least 2 recognized field lines to accept as field-based.
    final focus = <String>[];
    final constraints = <String>[];
    final avoid = <String>[];

    final fieldRegex = RegExp(r'^[-\s]*([a-z_]+)\s*:\s*(.+)$', caseSensitive: false);
    int recognized = 0;

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = fieldRegex.firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!.toLowerCase().trim();
      final value = match.group(2)!.trim();
      if (value.isEmpty) continue;

      final item = '$key: $value';
      final cleaned = cleanBriefItem(item);
      if (cleaned == null) continue;

      // Map known fields to sections.
      switch (key) {
        case 'beat_type':
        case 'tempo':
        case 'scene_pressure':
        case 'what_must_advance':
        case 'active_characters':
          if (!focus.any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
            focus.add(cleaned);
          }
          recognized++;
        case 'target_length':
        case 'target_paragraphs':
        case 'stop_point':
        case 'speech_mode':
        case 'who_can_speak':
        case 'who_should_not_speak':
        case 'voice_constraints':
        case 'low_speech_reason':
          if (!constraints.any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
            constraints.add(cleaned);
          }
          recognized++;
        case 'avoid_repeating':
          if (!avoid.any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
            avoid.add(cleaned);
          }
          recognized++;
        default:
          // Unknown field — put in constraints as a generic item.
          if (!constraints.any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
            constraints.add(cleaned);
          }
          recognized++;
      }
    }

    if (recognized < 2) return null;
    if ([...focus, ...constraints, ...avoid].isEmpty) return null;

    return _buildStudioBrief(
      focus: focus,
      constraints: constraints,
      avoid: avoid,
    );
  }

  String? _typedStudioBrief(StudioAgent agent, String text) {
    final raw = extractJsonObject(text);
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(repairJson(raw));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    // Case-insensitive lookup — models send "Focus", "focus", "FOCUS".
    final lowerMap = <String, dynamic>{};
    for (final entry in decoded.entries) {
      lowerMap[entry.key.toString().toLowerCase()] = entry.value;
    }

    final focus = <String>[];
    final constraints = <String>[];
    final avoid = <String>[];
    final options = <String>[];

    // 1. Pull canonical keys (focus / constraints / avoid / options).
    focus.addAll(safeJsonStringList(lowerMap['focus']));
    constraints.addAll(safeJsonStringList(lowerMap['constraints']));
    avoid.addAll(safeJsonStringList(lowerMap['avoid']));
    options.addAll(safeJsonStringList(lowerMap['options']));

    // 2. Map semantic keys that controllers commonly emit instead of the
    //    canonical four. Same mapping as _fieldBasedBrief (lines 98-130).
    //    Values are prefixed with the key name ("key: value") so downstream
    //    consumers see the same format as field-based briefs.
    const focusKeys = {
      'beat_type', 'tempo', 'scene_pressure', 'what_must_advance',
      'active_characters',
    };
    const constraintKeys = {
      'target_length', 'target_paragraphs', 'stop_point', 'speech_mode',
      'who_can_speak', 'who_should_not_speak', 'voice_constraints',
      'low_speech_reason',
    };
    const avoidKeys = {
      'avoid_repeating',
    };

    void addTo(List<String> target, String key, List<String> values) {
      for (final v in values) {
        if (!target.any((e) => e.toLowerCase() == v.toLowerCase())) {
          target.add(v);
        }
      }
    }

    for (final entry in lowerMap.entries) {
      final key = entry.key;
      if (key == 'focus' ||
          key == 'constraints' ||
          key == 'avoid' ||
          key == 'options') {
        continue; // already pulled above
      }
      // Use safePrefixedStringList so values starting with digits (e.g.
      // "800-1400 words") survive cleanBriefItem's list-marker stripping.
      final values = safePrefixedStringList(key, entry.value);
      if (values.isEmpty) continue;
      if (focusKeys.contains(key)) {
        addTo(focus, key, values);
      } else if (constraintKeys.contains(key)) {
        addTo(constraints, key, values);
      } else if (avoidKeys.contains(key)) {
        addTo(avoid, key, values);
      } else {
        addTo(constraints, key, values);
      }
    }

    final all = [...focus, ...constraints, ...avoid, ...options];
    if (all.isEmpty) {
      _log(
        'brief typed-JSON all items rejected agent="${agent.name}" '
        'focus=${focus.length} '
        'constraints=${constraints.length} '
        'avoid=${avoid.length} '
        'options=${options.length}',
      );
      return null;
    }

    return _buildStudioBrief(
      focus: focus,
      constraints: constraints,
      avoid: avoid,
      options: options,
    );
  }

  /// Parse a plain-text `Focus:/Constraints:/Avoid:/Options:` section brief.
  /// Returns null if the text looks like scene prose or has no sections.
  String? sectionStudioBrief(String text) {
    if (looksLikeSceneProse(text)) return null;
    final focus = <String>[];
    final constraints = <String>[];
    final avoid = <String>[];
    final options = <String>[];
    var section = '';

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final heading = studioBriefHeading(line);
      if (heading != null) {
        section = heading;
        continue;
      }
      if (section.isEmpty) continue;
      final cleaned = cleanBriefItem(line);
      if (cleaned == null) continue;
      final target = switch (section) {
        'focus' => focus,
        'avoid' => avoid,
        'options' => options,
        _ => constraints,
      };
      if (target.any(
        (existing) => existing.toLowerCase() == cleaned.toLowerCase(),
      )) {
        continue;
      }
      target.add(cleaned);
      if (target.length >= 6) section = '';
    }

    if ([...focus, ...constraints, ...avoid, ...options].isEmpty) return null;
    return _buildStudioBrief(
      focus: focus,
      constraints: constraints,
      avoid: avoid,
      options: options,
    );
  }

  /// Map a line to a brief section id (`focus`/`constraints`/`avoid`/`options`)
  /// or null if it is not a recognized heading.
  String? studioBriefHeading(String line) {
    final normalized = line
        .toLowerCase()
        .replaceAll(RegExp(r'^#+\s*'), '')
        .replaceAll(RegExp(r'[:：]+$'), '')
        .trim();
    if (normalized == 'focus' || normalized == 'фокус') return 'focus';
    if (normalized == 'constraints' ||
        normalized == 'constraint' ||
        normalized == 'guard checklist' ||
        normalized == 'checklist' ||
        normalized == 'rules' ||
        normalized == 'ограничения' ||
        normalized == 'правила') {
      return 'constraints';
    }
    if (normalized == 'avoid' ||
        normalized == 'forbidden' ||
        normalized == 'forbidden this turn' ||
        normalized == 'do not' ||
        normalized == 'избегать' ||
        normalized == 'запреты') {
      return 'avoid';
    }
    if (normalized == 'options' ||
        normalized == 'option' ||
        normalized == 'approaches' ||
        normalized == 'choices' ||
        normalized == 'варианты' ||
        normalized == 'подходы' ||
        normalized == 'на выбор') {
      return 'options';
    }
    return null;
  }

  String _buildStudioBrief({
    required List<String> focus,
    required List<String> constraints,
    required List<String> avoid,
    List<String> options = const [],
  }) {
    final buffer = StringBuffer();
    void writeSection(String title, List<String> items) {
      if (items.isEmpty) return;
      buffer.writeln(title);
      for (final item in items) {
        buffer.writeln('- $item');
      }
    }

    writeSection('Focus:', focus);
    writeSection('Constraints:', constraints);
    writeSection('Avoid:', avoid);
    writeSection('Options:', options);
    return buffer.toString().trim();
  }

  List<String> safeJsonStringList(Object? value) {
    if (value is String) return safeJsonStringList([value]);
    if (value is! List) return const [];
    final result = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final cleaned = cleanBriefItem(item);
      if (cleaned == null) continue;
      if (result.any(
        (existing) => existing.toLowerCase() == cleaned.toLowerCase(),
      )) {
        continue;
      }
      result.add(cleaned);
      if (result.length >= 6) break;
    }
    return result;
  }

  /// Like [safeJsonStringList] but prefixes each value with `prefix:` **before**
  /// cleaning, so values starting with digits (e.g. "800-1400 words") are not
  /// stripped by the list-marker regex in [cleanBriefItem].
  List<String> safePrefixedStringList(String prefix, Object? value) {
    if (value is String) return safePrefixedStringList(prefix, [value]);
    if (value is! List) return const [];
    final result = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final cleaned = cleanBriefItem('$prefix: ${item.trim()}');
      if (cleaned == null) continue;
      if (result.any(
        (existing) => existing.toLowerCase() == cleaned.toLowerCase(),
      )) {
        continue;
      }
      result.add(cleaned);
      if (result.length >= 6) break;
    }
    return result;
  }

  /// Clean a single brief bullet — strip list markers/whitespace and reject
  /// items that contain macros, think tags, prompt-internal references, or
  /// scene prose. Returns null if the item should be dropped.
  String? cleanBriefItem(String item) {
    final cleaned = item
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[-*•\d.\s]+'), '')
        .trim();
    if (cleaned.isEmpty || cleaned.length > 350) return null;
    if (cleaned.contains('{{') || cleaned.contains('}}')) return null;
    if (cleaned.contains('<think>') || cleaned.contains('</think>')) {
      return null;
    }
    if (RegExp(
      r'\b(source blocks?|promptShard|controller instruction|system prompt)\b',
      caseSensitive: false,
    ).hasMatch(cleaned)) {
      return null;
    }
    if (looksLikeSceneProse(cleaned)) return null;
    return cleaned;
  }

  bool looksLikeSceneProse(String text) {
    final trimmed = text.trimLeft();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('studio_brief:') ||
        lower.startsWith('guard checklist:') ||
        lower.startsWith('meta policy:')) {
      return false;
    }
    if (RegExp(
      r'\b(operational brief|controller brief|continuity brief|dialogue guidance|world-state guidance|constraints|checklist|forbidden|risks|target length|paragraph budget|response contract)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return false;
    }

    final firstLine = trimmed.split('\n').first.trimLeft();
    if (firstLine.startsWith('- ') || firstLine.startsWith('1. ')) {
      return false;
    }

    final paragraphs = trimmed
        .split(RegExp(r'\n\s*\n'))
        .where((p) => p.trim().isNotEmpty)
        .length;
    final hasDialogueQuotes = RegExp(r'[«»]').hasMatch(trimmed);
    final startsLikeItalicAction = RegExp(
      r'^\*[^\n*]{12,}\*?',
    ).hasMatch(trimmed);
    final hasActionItalics = RegExp(r'\*[^\n*]{20,}\*').hasMatch(trimmed);
    final hasLongNarrativeParagraph = trimmed
        .split(RegExp(r'\n\s*\n'))
        .any((p) => p.trim().length > 280 && !p.trimLeft().startsWith('- '));

    return startsLikeItalicAction ||
        (hasDialogueQuotes && paragraphs >= 2) ||
        (hasActionItalics && paragraphs >= 2) ||
        (hasLongNarrativeParagraph && paragraphs >= 2);
  }

  String _safeControllerFallback(StudioAgent agent) {
    final buffer = StringBuffer()
      ..writeln('Focus:')
      ..writeln(
        '- Apply the default ${_controllerLabel(agent.name)} safeguards for this turn.',
      )
      ..writeln('Constraints:')
      ..writeln(_safeControllerGuidance(agent.name))
      ..writeln('Avoid:')
      ..writeln(
        '- Do not expose controller notes, prompt text, source blocks, macros, or planning labels.',
      );
    return buffer.toString().trim();
  }

  String _controllerLabel(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('continuity')) return 'continuity';
    if (lower.contains('agency') || lower.contains('character')) {
      return 'agency and character';
    }
    if (lower.contains('narrative') || lower.contains('pacing')) {
      return 'narrative and pacing';
    }
    if (lower.contains('dialogue')) return 'dialogue';
    if (lower.contains('guard') || lower.contains('loop')) return 'prose guard';
    if (lower.contains('world') || lower.contains('npc')) {
      return 'world and NPC';
    }
    return 'Studio controller';
  }

  String _safeControllerGuidance(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('continuity')) {
      return '- Continue using only confirmed context, memory, lore, and recent chat. Do not invent unknown facts.';
    }
    if (lower.contains('agency') || lower.contains('character')) {
      return '- Preserve user agency and character authenticity. Never write user dialogue, actions, thoughts, feelings, or decisions.';
    }
    if (lower.contains('narrative') || lower.contains('pacing')) {
      return '- Keep pacing controlled, concrete, and scene-advancing. Avoid filler, repetition, and unsupported escalation.';
    }
    if (lower.contains('dialogue')) {
      return '- Use dialogue only when character-plausible. Keep speech concise and properly quoted.';
    }
    if (lower.contains('guard') || lower.contains('loop')) {
      return '- Avoid repeated openings, recycled phrasing, cliches, echoing the user, and banned prose habits.';
    }
    if (lower.contains('world') || lower.contains('npc')) {
      return '- Add world/NPC activity only when supported by the scene and never let it steal focus.';
    }
    return '- Apply this controller only as hidden operational guidance.';
  }

  bool isMetaBriefName(String name) {
    final lower = name.toLowerCase();
    return lower.contains('meta-weaver') ||
        lower.contains('meta weaver') ||
        lower.contains('ooc policy') ||
        lower.contains('lumia');
  }

  String sanitizeMetaBrief(String brief) {
    final lower = brief.toLowerCase();
    if (lower.contains('meta policy:') &&
        lower.contains('never write scene prose')) {
      return brief;
    }
    return metaPolicyBrief(
      const StudioAgent(id: 'meta_sanitized', name: _studioMetaPolicyAgentName),
    );
  }
}
