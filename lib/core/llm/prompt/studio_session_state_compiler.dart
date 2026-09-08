import '../../models/tracker.dart';

/// Test-accessible alias for [compileStudioSessionState].
/// Only use in test code — production code calls [compileStudioSessionState]
/// directly inside `PromptPayloadBuilder.buildFromSession`.
// ignore: non_constant_identifier_names
String? kCompileStudioSessionStateForTest(
  List<Tracker> trackers,
  String sessionId, {
  String latestUserText = '',
  String latestAssistantText = '',
}) => compileStudioSessionState(
  trackers,
  sessionId,
  latestUserText: latestUserText,
  latestAssistantText: latestAssistantText,
);

/// Compile ledger tracker rows into a `<studio_session_state>` system block.
///
/// Groups rows by namespace (npc, relationship, arc, world, scene) and
/// applies canon_override:* values when present. Locked rows without an
/// override are emitted as-is. Empty or diagnostic rows are skipped.
///
/// Mentioned-entity detection (plan §Prompt Injection Test 8):
///   - Always include npc/rel/arc rows for entities whose name appears in
///     [latestUserText] or in recent context.
///   - Always include arcs with do_not_reopen=true (card-baseline guard).
///   - Always include world/scene rows (compact; included unconditionally).
///   - If no [latestUserText] is provided, all rows are included (same as
///     original behaviour).
///
/// Present/absent section (plan §Present Characters + Test 21):
///   - scene.present_entities → explicit "Present now" list.
///   - scene.absent_backstory_entities → explicit "Absent/backstory" list.
///   - Prompt instructs model not to give dialogue/actions to absent chars.
///
/// Plan §Prompt Injection — minimum injected block:
/// ```xml
/// <studio_session_state>
/// These are established facts from this chat…
/// Lucyna Kushinada:
/// - relationship_to_user: fragile alliance
/// …
/// </studio_session_state>
/// ```
String? compileStudioSessionState(
  List<Tracker> trackers,
  String sessionId, {
  String latestUserText = '',
  String latestAssistantText = '',
}) {
  // Build a name→value map with override support. Keys:
  //   npc:Name.field, relationship:A:B.field, arc:id.field, world:key, scene.key
  // Override keys: canon_override:npc:Name.field → beats ledger value.
  final overrides = <String, String>{};
  final regular = <String, String>{};

  for (final t in trackers) {
    if (t.name.startsWith('canon_override:')) {
      final key = t.name.substring('canon_override:'.length);
      overrides[key] = t.value;
    } else if (!t.name.startsWith('canon_lock:') &&
        !t.name.startsWith('_ledger:')) {
      regular[t.name] = t.value;
    }
  }

  if (regular.isEmpty && overrides.isEmpty) return null;

  // Apply overrides.
  for (final entry in overrides.entries) {
    regular[entry.key] = entry.value;
  }

  if (regular.values.every((value) => value.trim().isEmpty)) return null;

  // Group by namespace.
  final npcMap = <String, Map<String, String>>{};
  final relMap = <String, Map<String, String>>{};
  final arcMap = <String, Map<String, String>>{};
  final worldLines = <String>[];
  // scene.present_entities and scene.absent_backstory_entities get special
  // treatment; remaining scene.* go to generic sceneLines.
  String? presentEntities;
  String? absentEntities;
  final sceneLines = <String>[];

  for (final entry in regular.entries) {
    final k = entry.key;
    final v = entry.value;
    if (v.isEmpty) continue;

    if (k.startsWith('npc:')) {
      final rest = k.substring('npc:'.length);
      final dotIdx = rest.indexOf('.');
      if (dotIdx < 0) continue;
      final name = rest.substring(0, dotIdx);
      final field = rest.substring(dotIdx + 1);
      // Legacy `knowledge` values were historical concatenations. Durable
      // propositions now live in character_knowledge_fact_rows and are
      // projected separately, so never let these blobs consume current-state
      // budget or crowd out relationships/world state.
      if (field != 'knowledge') {
        npcMap.putIfAbsent(name, () => {})[field] = v;
      }
    } else if (k.startsWith('relationship:')) {
      final rest = k.substring('relationship:'.length);
      final dotIdx = rest.indexOf('.');
      if (dotIdx < 0) continue;
      final pair = rest.substring(0, dotIdx);
      final field = rest.substring(dotIdx + 1);
      relMap.putIfAbsent(pair, () => {})[field] = v;
    } else if (k.startsWith('arc:')) {
      final rest = k.substring('arc:'.length);
      final dotIdx = rest.indexOf('.');
      if (dotIdx < 0) continue;
      final arcId = rest.substring(0, dotIdx);
      final field = rest.substring(dotIdx + 1);
      arcMap.putIfAbsent(arcId, () => {})[field] = v;
    } else if (k.startsWith('world:')) {
      final field = k.substring('world:'.length);
      worldLines.add('$field: $v');
    } else if (k == 'scene.present_entities') {
      presentEntities = v;
    } else if (k == 'scene.absent_backstory_entities') {
      absentEntities = v;
    } else if (k.startsWith('scene.')) {
      final field = k.substring('scene.'.length);
      sceneLines.add('$field: $v');
    }
  }

  // ── Mentioned-entity filtering (plan §Prompt Injection Test 8) ──────────
  // When latestUserText or latestAssistantText is non-empty, filter npc/rel/
  // arc to entities whose name/title/id is mentioned in either message.
  // World, scene, and arcs with do_not_reopen are always included regardless
  // (card-baseline guard).
  //
  // Additionally, any NPC listed in scene.present_entities is always included
  // — they are physically in the scene and their canon state is needed even
  // when the user referred to them indirectly ("белобрысая нетраннерша").
  final combinedText = '$latestUserText\n$latestAssistantText';
  final lowerCtx = combinedText.toLowerCase();
  final filterByMention = combinedText.trim().isNotEmpty;

  // Build a set of present-entity names for the bypass.
  final presentNames = <String>{};
  if (presentEntities != null) {
    for (final n in presentEntities.split(RegExp(r'[;,\n]+'))) {
      final trimmed = n.trim().toLowerCase();
      if (trimmed.isNotEmpty) presentNames.add(trimmed);
    }
  }

  // Build a name → location-keywords map from npc:Name.location tracker
  // values. This lets the filter match when the user mentions a location
  // ("захожу в посмертие") and an NPC is canonically at that location
  // (npc:Клэр.location: Посмертие → "посмертие" in context → Клэр included).
  //
  // Only the `location` field is used — other canon fields (mood, relationship)
  // could create false positives (e.g. an NPC at "home" whose mood field
  // coincidentally contains a word from the user's message).
  final npcLocationKeywords = <String, List<String>>{};
  for (final entry in npcMap.entries) {
    final loc = entry.value['location'];
    if (loc == null || loc.trim().isEmpty) continue;
    final keywords = loc
        .toLowerCase()
        .split(RegExp(r'[\s,;]+'))
        .where((w) => w.length >= 4)
        .toList();
    if (keywords.isNotEmpty) {
      npcLocationKeywords[entry.key.toLowerCase()] = keywords;
    }
  }

  // Helper: true when [name] tokens appear in the lower-cased context.
  bool mentioned(String name) {
    if (!filterByMention) return true;
    final lower = name.toLowerCase();
    // Present-entity bypass: always include NPCs physically in the scene.
    if (presentNames.contains(lower)) return true;
    // Direct substring match.
    if (lowerCtx.contains(lower)) return true;
    // Partial match: any word ≥ 4 chars of the name appears.
    if (lower
        .split(RegExp(r'[\s:]+'))
        .where((w) => w.length >= 4)
        .any(lowerCtx.contains)) {
      return true;
    }
    // Location-keyword match: NPC is canonically at a location whose name
    // appears in the context. Closes the "зашёл в локацию" gap — the user
    // enters a location and all NPCs canonically present there get their
    // canon injected without an extra LLM call.
    final locKeywords = npcLocationKeywords[lower];
    if (locKeywords != null && locKeywords.any(lowerCtx.contains)) {
      return true;
    }
    return false;
  }

  final filteredNpc = filterByMention
      ? Map.fromEntries(npcMap.entries.where((e) => mentioned(e.key)))
      : npcMap;

  final filteredRel = filterByMention
      ? Map.fromEntries(
          relMap.entries.where((e) {
            // pair is "A:B" — check if either entity is mentioned.
            final parts = e.key.split(':');
            return parts.any(mentioned);
          }),
        )
      : relMap;

  final filteredArc = filterByMention
      ? Map.fromEntries(
          arcMap.entries.where((e) {
            final f = e.value;
            final doNotReopen = f['do_not_reopen']?.toLowerCase() == 'true';
            // Always keep do_not_reopen arcs (card-baseline regression guard).
            if (doNotReopen) return true;
            final title = f['title'] ?? e.key;
            return mentioned(title) || mentioned(e.key);
          }),
        )
      : arcMap;

  // ── Build output ─────────────────────────────────────────────────────────
  final buf = StringBuffer();
  buf.writeln('<studio_session_state>');
  buf.writeln(
    'These are established facts from this chat. They override character-card '
    'baseline when conflicting. MemoryBook/raw-chat evidence is lower than this '
    'current state but higher than a conflicting card baseline. Source-material '
    'knowledge may fill gaps and an omitted card fact is not automatically '
    'unknown.',
  );

  // ── Present / Absent section (plan §Present Characters + Test 21) ────────
  // Always inject presence data when available — it prevents absent NPCs
  // from acting in the scene.
  if (presentEntities != null || absentEntities != null) {
    buf.writeln();
    if (presentEntities != null) {
      buf.writeln('Present now:');
      for (final name in presentEntities.split(RegExp(r'[;,\n]+'))) {
        final n = name.trim();
        if (n.isNotEmpty) buf.writeln('- $n');
      }
    }
    if (absentEntities != null) {
      buf.writeln('Absent/backstory only:');
      for (final name in absentEntities.split(RegExp(r'[;,\n]+'))) {
        final n = name.trim();
        if (n.isNotEmpty) buf.writeln('- $n');
      }
      buf.writeln(
        'Do not give dialogue or physical actions to absent characters '
        'unless through memory, recording, call, or explicit scene entry.',
      );
    }
  }

  // Relationship truth and card-regression guards precede descriptive NPC
  // state so the hard cap can never discard established trust in favor of a
  // long mood/boundary description.
  if (filteredRel.isNotEmpty) {
    buf.writeln('\nRelationships:');
    for (final pair in filteredRel.keys.toList()..sort()) {
      buf.writeln('$pair:');
      final fields = filteredRel[pair]!;
      for (final field in fields.keys.toList()..sort()) {
        buf.writeln('- $field: ${fields[field]}');
      }
    }
  }

  if (filteredArc.isNotEmpty) {
    final completed = <String>[];
    final active = <String>[];
    final other = <String>[];
    for (final arcId in filteredArc.keys) {
      final f = filteredArc[arcId]!;
      final status = f['status'] ?? '';
      if (status == 'completed' ||
          status == 'failed' ||
          status == 'abandoned' ||
          status == 'superseded') {
        completed.add(arcId);
      } else if (status == 'active') {
        active.add(arcId);
      } else {
        other.add(arcId);
      }
    }
    if (completed.isNotEmpty) {
      buf.writeln('\nResolved arcs:');
      for (final id in completed..sort()) {
        final f = filteredArc[id]!;
        final summary = f['summary'] ?? '';
        final noReopen = f['do_not_reopen']?.toLowerCase() == 'true';
        final override = f['card_override'] ?? '';
        buf.write('- ${f['title'] ?? id} is completed.');
        if (summary.isNotEmpty) buf.write(' $summary');
        if (noReopen) buf.write(' Do not reopen as active conflict.');
        if (override.isNotEmpty) buf.write(' $override');
        buf.writeln();
      }
    }
    if (active.isNotEmpty || other.isNotEmpty) {
      buf.writeln('\nActive arcs:');
      for (final id in [...active, ...other]..sort()) {
        final f = filteredArc[id]!;
        final summary = f['summary'] ?? '';
        if (summary.isNotEmpty) {
          buf.writeln('- ${f['title'] ?? id}: $summary');
        }
      }
    }
  }

  if (filteredNpc.isNotEmpty) {
    const priority = [
      'trust_to_user',
      'relationship_to_user',
      'card_overrides',
      'boundaries',
      'attitude_to_user',
      'current_emotional_residue',
      'current_goal',
      'persistent_condition',
      'location',
    ];
    for (final name in filteredNpc.keys.toList()..sort()) {
      buf.writeln('\n$name:');
      final fields = filteredNpc[name]!;
      final ordered = [
        ...priority.where(fields.containsKey),
        ...fields.keys.where((field) => !priority.contains(field)).toList()
          ..sort(),
      ];
      for (final field in ordered) {
        buf.writeln('- $field: ${fields[field]}');
      }
    }
  }

  if (worldLines.isNotEmpty) {
    buf.writeln('\nWorld:');
    for (final line in worldLines) {
      buf.writeln('- $line');
    }
  }

  if (sceneLines.isNotEmpty) {
    buf.writeln('\nScene:');
    for (final line in sceneLines) {
      buf.writeln('- $line');
    }
  }

  buf.write('</studio_session_state>');
  final result = _dedupeAndCapStudioState(buf.toString()).trim();
  // If we only wrote the header and footer with no content, skip injection.
  final onlyHeader =
      result ==
      '<studio_session_state>\nThese are established facts from this chat. '
          'They override character-card baseline when conflicting.\n</studio_session_state>';
  if (onlyHeader) return null;
  return result.isEmpty ? null : result;
}

/// Dedupes repeated rendered canon lines and caps the block to a bounded size.
///
/// This is the MVP implementation of plan §Prompt Dedupe / Prompt Budget:
/// it prevents duplicate canon claims inside the high-authority Studio state
/// block and caps tail growth before lower-authority recall/memory blocks are
/// considered. The ordering of [compileStudioSessionState] intentionally puts
/// manual overrides, presence, and resolved do_not_reopen arcs before lower-
/// priority world/scene details, so tail trimming preserves conflict-preventing
/// canon first.
String _dedupeAndCapStudioState(String raw) {
  const maxChars = 6000;
  final seen = <String>{};
  final lines = <String>[];
  for (final line in raw.split('\n')) {
    final trimmed = line.trim();
    // Keep structural blank lines, but dedupe actual claim lines.
    if (trimmed.isNotEmpty) {
      // CanonClaim-lite normalization: for bullet claims, dedupe by the fact
      // value after the first colon so the same claim rendered under two low-
      // authority field names appears once.
      final claimText = trimmed.startsWith('- ') && trimmed.contains(':')
          ? trimmed.substring(trimmed.indexOf(':') + 1).trim()
          : trimmed;
      final normalized = claimText.toLowerCase().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      if (!seen.add(normalized)) continue;
    }
    lines.add(line);
  }
  var out = lines.join('\n');
  if (out.length <= maxChars) return out;
  final close = '</studio_session_state>';
  final trimNotice = '[trimmed lower-priority canon details]';
  final budget = maxChars - close.length - trimNotice.length - 2;
  if (budget <= 0) return out.substring(0, maxChars);
  final packed = <String>[];
  var used = 0;
  for (final line in lines) {
    final cost = line.length + 1;
    if (used + cost > budget) break;
    packed.add(line);
    used += cost;
  }
  out = packed.join('\n').trimRight();
  return '$out\n$trimNotice\n$close';
}
