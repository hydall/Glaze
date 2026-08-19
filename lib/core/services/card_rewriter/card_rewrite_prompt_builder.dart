import 'dart:convert';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

/// Builds deterministic writer-lane prompts. Pure: no DB, UI, network, or
/// lorebook reads; untrusted output is screened separately by
/// `CardRewriteOperationParser`.
///
/// Determinism: identical inputs always produce byte-identical prompts. Every
/// dynamic input is serialized through [CardCanonicalizer] (stable key order,
/// null text normalized) and there are no timestamps, randomness, or
/// environment lookups.
abstract final class CardRewriterPromptBuilder {
  static String buildEvolution({
    required Character character,
    required String instruction,
    List<Map<String, Object?>> accumulatedObservations = const [],
  }) {
    final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(character);
    final snapshot = Map<String, Object?>.from(
      CardCanonicalizer.snapshot(character),
    );
    for (final field in CardRewritePolicy.evolutionFields) {
      if (!writableFields.contains(field)) snapshot.remove(field.wireName);
    }
    final writableFieldNames = writableFields
        .map((field) => field.wireName)
        .join(', ');
    final buffer = StringBuffer()
      ..writeln(
        'You are the Glaze card rewriter. Propose small anchored scalar patches '
        'for the character card below.',
      )
      ..writeln()
      ..writeln('# Writable fields')
      ..writeln(
        writableFields.isEmpty
            ? 'No card field is writable: description, personality, and scenario '
                  'are all empty and are intentionally omitted from this request.'
            : 'Only these non-empty fields are writable: $writableFieldNames. '
                  'Empty fields are omitted and MUST NOT appear in operations. '
                  'Omit a field when its current text does not need a durable change.',
      )
      ..writeln()
      ..writeln('# Response format')
      ..writeln(
        'Respond with exactly one JSON object and nothing else: '
        '{"operations":[{"field":"description|personality|scenario",'
        '"patches":[{"scopeKey":"...","anchor":"...",'
        '"anchorSha256":"...","value":"..."}],"transition":'
        '{"id":"...","scopeKey":"...","canonicalClaim":"...",'
        '"promotionDestination":"...","affectedTrackerKeys":[],'
        '"factIds":[],"chatSessionId":null}}]}.',
      )
      ..writeln(
        'Each field may occur at most once. Return an empty "operations" list '
        'ONLY when the chat and Ledger contain no supported durable change for '
        'any writable field. A Ledger fact is accepted evidence, not a reason '
        'to omit a card patch. Use one or more exact anchors per changed field, '
        'never a full-field rewrite.',
      )
      ..writeln(
        'Prefer replacing or refining an existing outdated card fragment over '
        'appending a new standalone fact. Append only when no existing fragment '
        'can accurately absorb the durable development. This keeps the card '
        'compact while allowing it to grow gradually when necessary.',
      )
      ..writeln(
        'Minimal means the smallest exact anchors, not the fewest patches. When '
        'one durable change makes multiple fragments in the same writable field '
        'outdated or mutually contradictory, include a separate minimal patch '
        'for every directly conflicting fragment in that field. Do not update '
        'only the first occurrence while leaving the rest of the card describing '
        'the obsolete state as current canon.',
      )
      ..writeln(
        'The card is a long-term character reference, not an event log. Keep '
        'one-off actions, recent scene beats, invitations, travel, meals, and '
        'temporary relationship moods or scene-level dynamics in Ledger. Do not '
        'patch the card '
        'merely because {{user}} and the character went somewhere or did '
        'something together. Patch it only when the evidence establishes a '
        'lasting change in personality, relationship pattern, enduring goal, '
        'boundary, worldview, or baseline premise that future scenes need. A '
        'durable relationship-status transition such as an engagement forming '
        'or ending, marriage, divorce, or an enduring alliance or enmity changes '
        'the baseline premise and belongs in the card when supported.',
      )
      ..writeln(
        'For example, accepting a drink is a Ledger event; a repeatedly '
        'demonstrated shift from guarded distrust to cautious trust may justify '
        'a small card refinement. Do not turn a single event into a permanent '
        'trait or relationship claim.',
      )
      ..writeln()
      ..writeln('# Patch rules')
      ..writeln(
        '- scopeKey supports npc:<subject>, relationship:<subject>, '
        'arc:<subject>, world:<subject>, or scene.<subject>. Every patch and '
        'its transition must use the same scopeKey. Preserve exact RP-language '
        'Unicode identities from supplied Ledger keys; never translate, '
        'transliterate, case-fold, or invent an identity.',
      )
      ..writeln(
        '- Each anchor must occur exactly once in its current field and its '
        'anchorSha256 must be present as a string; the application recomputes '
        'it from the anchor bytes. '
        'Empty anchors are forbidden. Use a meaningful literal phrase of at '
        'least 12 code units, never an isolated word, number, punctuation mark, '
        'or identifier. Never '
        'use chat-history text as an anchor: anchors are copied only from the '
        'canonical card field you are patching.',
      )
      ..writeln(
        '- Preserve every {{...}} macro token byte-for-byte in a replacement. '
        'Never replace {{user}} with a character name or persona name.',
      )
      ..writeln(
        '- Strict character boundary: a patch modifying one character\'s profile '
        'MUST NOT insert description or background for other characters, the user, '
        'or third parties. Each character\'s section must remain strictly about that character.',
      )
      ..writeln(
        '- Treat the immutable chat history and Ledger facts as evidence for '
        'card evolution. Ledger may establish the evidence, but its event '
        'records are not themselves card content. Avoid duplication only '
        'against the supplied injected lorebook entries, not against chat '
        'history or Ledger.',
      )
      ..writeln('- Emit no keys beyond those shown above.')
      ..writeln()
      ..writeln('# User instruction')
      ..writeln(instruction)
      ..writeln()
      ..writeln('# Canonical character card snapshot (read-only)')
      ..write(jsonEncode(snapshot));
    if (accumulatedObservations.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('# Accumulated candidates from observation journal')
        ..writeln(
          'Evaluate these candidates independently. Status "active" means the '
          'candidate alone is not yet confirmed and remains discretionary. '
          'Status "promoted" is stronger confirmed evidence. Use repeatCount, '
          'confidence, evidence clusters, chat, card, and Ledger together. When '
          'the supplied immutable chat or Ledger confirms a durable candidate '
          'that directly contradicts supplied card text, emit the smallest valid '
          'patch that resolves the contradiction regardless of whether the '
          'candidate status is "active" or "promoted", unless no writable field '
          'or valid character-boundary-preserving anchor can do so. An empty '
          'operations list is not valid for such a confirmed, resolvable '
          'contradiction. Return no patch only when evidence is insufficient or '
          'the durable fact is already canonical.',
        )
        ..write(jsonEncode(accumulatedObservations));
    }
    return buffer.toString();
  }

  static String buildObservationPass({
    required Character character,
    required List<Map<String, Object?>> activeObservations,
    required String instruction,
  }) {
    final buffer = StringBuffer()
      ..writeln(
        'You are an observation journal keeper for a roleplay character card. '
        'You do NOT edit the card. You record and confirm observations about '
        'durable character changes.',
      )
      ..writeln()
      ..writeln('# Rules')
      ..writeln(
        '- An observation is a candidate durable change, NOT a confirmed edit.',
      )
      ..writeln(
        '- One-off events (going somewhere, eating, single conversations) are '
        'NOT observations.',
      )
      ..writeln(
        '- Temporary state (current mood, location, clothing, injury) is NOT '
        'an observation.',
      )
      ..writeln(
        '- Repeatedly demonstrated shifts in preference, attitude, relationship '
        'dynamics, or lasting character development ARE observations.',
      )
      ..writeln(
        '- retrievalKeys must contain exact, stable, case-preserving Unicode '
        'Ledger GROUP keys (for example npc:Квинн, '
        'relationship:Гильда:Квинн, arc:Спонсорство) from '
        'availableObservationRetrievalTargets in the supplied snapshot. Never '
        'return volatile field suffixes such as .location or .trust. Never '
        'translate, transliterate, or invent a key.',
      )
      ..writeln(
        '- targetKind is main_character_card for the main character\'s enduring '
        'traits or relationships, or injected_lorebook_entry for NPC-owned '
        'facts. NPC-owned facts may target only an existing injected lorebook '
        'entry; they must never target the main character card.',
      )
      ..writeln(
        '- Each observation has a narrow semantic scope key '
        '(e.g. character.preference.X).',
      )
      ..writeln(
        '- Confidence 0.0-1.0 reflects how strongly the chat history supports '
        'this change.',
      )
      ..writeln()
      ..writeln('# Active observations from previous passes')
      ..writeln(jsonEncode(activeObservations))
      ..writeln()
      ..writeln('# Actions')
      ..writeln('For each existing observation, choose:')
      ..writeln(
        '- "confirm": a causally independent new opportunity in supplied chat '
        'supports this change. Include its message IDs and update confidence.',
      )
      ..writeln(
        '- "no_evidence": there is no new independent support. Absence of the '
        'character or behavior is no_evidence and changes nothing.',
      )
      ..writeln(
        '- "contradict": supplied chat contains explicit incompatible evidence. '
        'Include its message IDs. Mere absence or lack of support is never a '
        'contradiction.',
      )
      ..writeln('For new observations, choose:')
      ..writeln(
        '- "new": a new candidate durable change is evident from the chat '
        'history. Include the supporting supplied message IDs.',
      )
      ..writeln(
        'Every new/confirm evidence set must be one causally independent cluster '
        'or new opportunity, not a continuation of the same moment. Overlapping '
        'windows or messages cannot reconfirm. One day may contain multiple '
        'independent clusters, while 200 messages may remain one cluster when '
        'they belong to the same causal moment.',
      )
      ..writeln(
        'Use only message IDs present in the supplied immutable chat history. '
        'Never fabricate IDs.',
      )
      ..writeln()
      ..writeln('# Response format')
      ..writeln(
        'Respond with exactly one JSON object and nothing else: '
        '{"observations":[{"action":"new|confirm|no_evidence|contradict","scopeKey":"...",'
        '"observedChange":"...","canonicalClaim":"...",'
        '"retrievalKeys":["exact Ledger key"],'
        '"targetKind":"main_character_card|injected_lorebook_entry",'
        '"evidenceMessageIds":[],"cardFieldPath":"personality"|null,'
        '"lorebookEntryId":"bookId:entryId"|null,"confidence":0.0-1.0}]}.',
      )
      ..writeln(
        'Return an empty "observations" list ONLY when the chat history '
        'contains no new durable changes and no existing observation needs '
        'confirmation or explicit contradiction.',
      )
      ..writeln()
      ..writeln('# Instruction')
      ..writeln(instruction)
      ..writeln()
      ..writeln('# Canonical character card snapshot (read-only)')
      ..write(jsonEncode(CardCanonicalizer.snapshot(character)));
    return buffer.toString();
  }

  static String buildLorebookEvolution({required String instruction}) {
    return '''You are the Glaze lorebook rewriter. The shared read-only context below contains the character card, recent chat, Ledger facts, and exact lorebook entries actually injected into that chat.

# Writable targets
Only the supplied lorebookId/entryId pairs are writable. Do not create, delete, move, rename, or change keys/settings. Do not output card patches. The shared context includes the current card and the card writer's proposed operations. Avoid only card-lorebook duplication: do not patch an entry with a fact already represented in the current card or proposed card operations. Chat history and Ledger are evidence, not alternate durable targets; do not omit a supported lorebook patch merely because Ledger already records the fact.
NPC-owned facts may patch only an existing supplied injected lorebook entry. Main-character relationships may patch the card instead. Preserve exact RP-language Unicode Ledger identities; never translate or transliterate them.

# Response format
Respond with exactly one JSON object and nothing else:
{"operations":[{"lorebookId":"...","entryId":"...","baseContent":"...","expectedContentHash":"...","patches":[{"anchor":"...","anchorSha256":"...","value":"..."}]}]}
Each target may occur at most once. Return an empty "operations" list ONLY when no supported durable update belongs in any supplied target. A Ledger fact is accepted evidence, not a reason to omit an eligible lorebook patch. baseContent and expectedContentHash must exactly echo the supplied target. Each anchor must occur exactly once in its supplied current content; anchorSha256 is its lowercase SHA-256 UTF-8 hash. Use smallest exact fragment replacements, never rewrite an entire entry. Preserve every {{...}} macro token byte-for-byte.

# Instruction
$instruction''';
  }

  static String build({
    required Character character,
    required CardRewriteField field,
    required String instruction,
  }) {
    final snapshot = CardCanonicalizer.snapshot(character);
    final canonicalJson = jsonEncode(snapshot);
    final currentValue = snapshot[field.wireName]! as String;
    final writableFields = CardRewritePolicy.writableFields
        .map((candidate) => candidate.wireName)
        .join(', ');

    final buffer = StringBuffer()
      ..writeln(
        'You are the Glaze card rewriter. Propose anchored scalar patches for '
        'exactly one field of the character card below.',
      )
      ..writeln()
      ..writeln('# Target field')
      ..writeln('- field: ${field.wireName}')
      ..writeln('- currentFieldCodeUnits: ${currentValue.length}')
      ..writeln()
      ..writeln('# Writable fields')
      ..writeln('Writable fields across this workflow: $writableFields.')
      ..writeln(
        'For THIS operation only "${field.wireName}" is writable. Never emit '
        'patches for any other field; every non-target field and every other '
        'JSON key of the card snapshot is read-only and MUST NOT appear in '
        'your response.',
      )
      ..writeln()
      ..writeln('# Response format')
      ..writeln(
        'Respond with exactly ONE JSON object and nothing else (no prose, no '
        'markdown fences). Shape:',
      )
      ..writeln(
        '{"field":"${field.wireName}","patches":[{"scopeKey":"...","anchor":"...",'
        '"anchorSha256":"...","value":"..."}],"transition":{"id":"...","scopeKey":"...",'
        '"canonicalClaim":"...","promotionDestination":"...","affectedTrackerKeys":[],'
        '"factIds":[],"chatSessionId":null}}',
      )
      ..writeln('Rules:')
      ..writeln('- "field" MUST be exactly "${field.wireName}".')
      ..writeln(
        '- "patches" MUST be a non-empty list of objects with exactly the '
        'keys scopeKey, anchor, anchorSha256, value.',
      )
      ..writeln(
        '- "scopeKey" MUST parse as one of npc:<subject>, '
        'relationship:<subject>, arc:<subject>, world:<subject>, or '
        'scene.<subject> (lowercase alphanumerics plus _ - segments; scene '
        'allows dotted segments). Every patch and the transition MUST use the '
        'SAME scopeKey.',
      )
      ..writeln(
        '- "anchor" MUST be a literal fragment of the current '
        '"${field.wireName}" text that occurs there EXACTLY ONCE; each anchor '
        'is replaced by its "value". If and only if the current field is empty, '
        'use an empty anchor with its SHA-256 to initialize it.',
      )
      ..writeln(
        '- "anchorSha256" MUST be the lowercase hex SHA-256 of the anchor\'s '
        'UTF-8 bytes. The receiver recomputes it and rejects any mismatch.',
      )
      ..writeln(
        '- "transition.id", "transition.canonicalClaim", and '
        '"transition.promotionDestination" MUST be non-empty strings.',
      )
      ..writeln(
        '- "transition.affectedTrackerKeys" MUST be present (an empty list '
        'is allowed); "transition.factIds" MAY be omitted (defaults to '
        'empty).',
      )
      ..writeln(
        '- "transition.chatSessionId" MUST be null or omitted: only global '
        'transitions are accepted.',
      )
      ..writeln('- Emit no keys beyond those shown in the shape above.')
      ..writeln()
      ..writeln('# Macro preservation')
      ..writeln(
        'Macros are literal template tokens like {{user}}, {{char}}, '
        '{{description}}, or any custom {{...}} name. NEVER expand, '
        'substitute, rename, translate, or delete them. If a macro occurs '
        'inside an anchor, include it there exactly as written, and every '
        'macro carried into a replacement "value" MUST stay byte-for-byte '
        'identical. {{...}} tokens are literal text for hashing purposes.',
      )
      ..writeln()
      ..writeln('# User instruction')
      ..writeln(instruction)
      ..writeln()
      ..writeln(
        '# Canonical character card snapshot (read-only context; missing '
        'text fields are normalized to empty strings)',
      )
      ..write(canonicalJson);
    return buffer.toString();
  }
}
