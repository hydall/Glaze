import '../models/memory_book.dart';
import '../models/tracker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerPrompt
//
// Builds the prompt for the Studio Ledger LLM call.
// Pure, stateless — all inputs are passed explicitly.
//
// Based on the Studio Ledger prompt contract: the ledger is an internal
// continuity/state extractor that maintains session-canon facts for future
// generations. It does NOT write story prose. It preserves prior state unless
// contradicted, distinguishes event states
// (planned/suggested/threatened/attempted/completed/failed/cancelled/unknown),
// and never converts threats/plans/questions/offers/pending choices into
// completed facts. Returns <studio_ledger> + <glaze_memory_export> JSON,
// preferring patch ops in `ops` for persistence.
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the non-streaming prompt sent to the Studio Ledger model.
class StudioLedgerPrompt {
  const StudioLedgerPrompt();

  /// Build the full ledger prompt from the turn's context.
  ///
  /// [finalAssistantText] — cleaned final assistant response (post-cleaner
  /// output when enabled, raw response otherwise).
  ///
  /// [recentHistoryText] — last ~10 user+assistant turns in plain text,
  /// for scene/entity context.
  ///
  /// [currentTrackers] — current tracker_rows for this session (entity,
  /// relationship, arc, world, scene state written by prior ledger runs).
  ///
  /// [recentMemoryEntries] — up to 20 active MemoryBook entries (title + keys
  /// only, content omitted to keep prompt lean).
  String build({
    required String finalAssistantText,
    required String recentHistoryText,
    required List<Tracker> currentTrackers,
    required List<MemoryEntry> recentMemoryEntries,
  }) {
    final trackerBlock = buildCurrentStateBlock(
      currentTrackers,
      '$recentHistoryText\n$finalAssistantText',
    );
    final keyCatalog = buildExistingKeyCatalog(currentTrackers);
    final memoryBlock = _buildMemoryBlock(recentMemoryEntries);

    return '''$_systemPrompt

<current_state>
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
<studio_ledger>
Compact continuity snapshot here.
</studio_ledger>

The <glaze_memory_export> block MUST come first, before <studio_ledger>.
It must contain a single JSON object with "ops" and "knowledgeFacts" arrays.
When there are no state changes or knowledge facts, output empty arrays —
do NOT skip the block.

Ops format:
{"ops":[{"op":"set","key":"npc:Name.field","value":"…","evidence":"…","eventState":"completed"},…],"knowledgeFacts":[{"knowerKey":"entity:lucy","knowerName":"Lucy","subjectKey":"entity:danvi","subjectName":"Danvi","factClass":"relationship","scopeKey":"relationship:danvi","predicate":"trusts","object":"Trusts Danvi.","epistemicState":"confirmed","confidence":0.9,"importance":0.8,"entities":["Lucy"],"topics":["trust"],"supersedesId":null}]}

Allowed namespaces: npc:, relationship:, arc:, world:, scene.
Allowed ops: set, delete. Every set replaces the complete current value.
Do not write npc:*.knowledge — use knowledgeFacts instead.
Allowed eventState: planned, suggested, threatened, attempted, completed, failed, cancelled, unknown (or omit).
Allowed factClass: knowledge, relationship, behavior_change, commitment, goal, persistent_condition, identity_development.
Allowed epistemicState: observed, heard_claim, inferred, confirmed, disbelieved, forgotten, retracted.
knowledgeFacts rules:
- One proposition per fact. Never summarize prior facts.
- supersedesId only when correcting a known injected fact ID.
- Distinguish direct observation, heard claim, inference, confirmation, disbelief, and correction.
- Never output future events as facts.
- scopeKey: narrowest defensible scope (e.g. relationship:danvi), never global for convenience.''';
  }

  /// Full values for state relevant to this turn. This filters rows, never
  /// truncates them; persisted tracker data remains lossless.
  String buildCurrentStateBlock(List<Tracker> trackers, String turnContext) {
    if (trackers.isEmpty) return '(no prior state)';
    // Show only ledger-scope trackers (entity/relationship/arc/world/scene).
    final ledgerTrackers = trackers
        .where((t) => t.scope == 'ledger' || t.scope == 'chat')
        .where(
          (t) =>
              (t.name.startsWith('npc:') && !t.name.endsWith('.knowledge')) ||
              (t.name.startsWith('relationship:') &&
                  !t.name.endsWith('.knowledge')) ||
              t.name.startsWith('arc:') ||
              t.name.startsWith('world:') ||
              t.name.startsWith('scene.'),
        )
        .where((tracker) => _isRelevantTracker(tracker, turnContext))
        .toList();
    if (ledgerTrackers.isEmpty) return '(no prior state)';
    return ledgerTrackers.map((t) => '${t.name}: ${t.value}').join('\n');
  }

  bool _isRelevantTracker(Tracker tracker, String turnContext) {
    if (tracker.name.startsWith('world:') ||
        tracker.name.startsWith('scene.')) {
      return true;
    }
    final haystack = _searchTerms(turnContext);
    final key = tracker.name.split('.').first;
    final identifiers = key
        .split(':')
        .skip(1)
        .expand((part) => _searchTerms(part))
        .where((term) => term.length > 2);
    return identifiers.any(haystack.contains);
  }

  Set<String> _searchTerms(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((term) => term.isNotEmpty)
      .toSet();

  /// Names only, so aliases can resolve to an existing canonical key without
  /// injecting every stored value into the Ledger prompt.
  String buildExistingKeyCatalog(List<Tracker> trackers) {
    final keys =
        trackers
            .where(
              (tracker) => tracker.scope == 'ledger' || tracker.scope == 'chat',
            )
            .map((tracker) => tracker.name)
            .where(_isLedgerKey)
            .toSet()
            .toList()
          ..sort();
    return keys.isEmpty ? '(no prior keys)' : keys.join('\n');
  }

  bool _isLedgerKey(String name) =>
      name.startsWith('npc:') ||
      name.startsWith('relationship:') ||
      name.startsWith('arc:') ||
      name.startsWith('world:') ||
      name.startsWith('scene.');

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

  static const String _systemPrompt =
      '''You are Studio Ledger, an internal continuity and state extractor.
You do not write story prose.
You maintain session-canon facts for future generations.

Use the final assistant response, latest user message, previous ledger, recent chat, current state, and existing memory.

Rules:
- Preserve prior state unless contradicted by the final response.
- Treat accepted assistant prose as evidence of what was narrated, not proof of
  hidden motives, unseen research, ownership, causation, or off-screen events.
  Persist only explicit observations, actions, dialogue, user corrections, and
  already-established canon. If a claim is merely plausible, omit it from
  current state; use an epistemically qualified knowledgeFact only when useful.
- Never turn guesses, rhetorical flourishes, metaphors, probabilistic language,
  or a character's interpretation into objective current state.
- Temporary posture/outfit/props stay in the visible ledger unless they became important.
- Do not create quests unless an explicit task/goal exists.
- Do not create persona stats unless already tracked.
- Do not infer romance/trust jumps without evidence in the final response.
- Session state overrides character-card baseline.
- Source priority is: explicit user correction and established session canon;
  then episodic MemoryBook/raw recall; then character card and supplied lore;
  then model knowledge of the source material.
- Source-material knowledge is allowed to fill genuine gaps. Absence from the
  character card does NOT mean a known canon person or fact is unknown.
- Model knowledge must not contradict explicit session canon, episodic evidence,
  or explicit card/lore claims. An omitted card fact is a gap, not a conflict.
  When unsure, omit the claim instead of recording it as session fact.
- A model-known source fact becomes session canon only after it is stated in an
  accepted user/assistant turn. The Ledger may then persist it with evidence.
- A retcon invalidates only the fact or condition it identifies. It does not
  prevent a later, explicitly established event from creating a new state of
  the same category. Keep the old fact deleted and store the newer state with
  its later evidence anchor.
- If an arc from the card is resolved in session canon, mark it completed with do_not_reopen=true.
- Never write future events as facts.
- Pending user choices are hooks, not completed events.
- Do not convert threats, plans, questions, offers, or pending choices into completed facts.
- Distinguish planned, suggested, threatened, attempted, completed, failed, cancelled, and unknown event states.
- Do not mark an entity present only because it is mentioned.
- Do not mark an entity absent unless it explicitly leaves, dies, is left behind, or the scene changes.
- Locations are current state, not history. When the scene or time advances and
  an NPC's current location is no longer established, delete npc:Name.location
  instead of retaining a stale location or inventing where the NPC went.
- Keep current_goal limited to the entity's active immediate objective. Remove
  completed, abandoned, and merely remembered tasks; never use it as a backlog.
- Return <studio_ledger> plus <glaze_memory_export> JSON.
- Prefer patch ops in the ops list for persistence. Do not rewrite the whole world state.
- Reuse an exact key from <current_state> or <existing_keys> when it represents the same fact. Update it with set; do not create a synonym key.
- Identity resolution overrides exact-key reuse. When chat establishes that a
  placeholder or alias (for example "Unidentified Netrunner") is a named
  entity, migrate every relevant field to one canonical npc:Name key and emit
  delete ops for every obsolete placeholder/alias key. Preserve only supported
  values during the merge; do not duplicate the entity under two names.
- Explicit user corrections have highest priority. Apply the correction to all
  affected current-state keys and delete incompatible or obsolete keys in the
  same patch.
- Keep entity/relationship/arc/world state compact. Update current truth; do not create a history log.
- Never output ledger text as story prose or a chat message.
- Entity state keys: npc:Name.relationship_to_user, npc:Name.attitude_to_user, npc:Name.trust_to_user, npc:Name.boundaries, npc:Name.card_overrides, npc:Name.location, npc:Name.current_emotional_residue, npc:Name.current_goal, npc:Name.persistent_condition
- Relationship keys: relationship:A:B.trust, relationship:A:B.status, relationship:A:B.relationship, relationship:A:B.attitude, relationship:A:B.boundaries, relationship:A:B.card_override
- Never write npc:*.knowledge or relationship:*.knowledge. Use knowledgeFacts.
- Arc keys: arc:id.status, arc:id.summary, arc:id.do_not_reopen, arc:id.card_override
- World/scene keys: world:location, world:time, world:date, world:active_threats, scene.present_entities, scene.absent_backstory_entities''';
}
