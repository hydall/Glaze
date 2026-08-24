# Database Rules

Rules for all code that reads from or writes to the Drift database.

---

## One repo per table

All DB access goes through a repo class in `lib/core/db/repositories/`.
Never query Drift tables directly from a provider, service, or UI file.

```
UI → Provider → Service → Repo → Drift table
```

---

## No raw SQL outside repos

All queries use Drift's type-safe API. Raw SQL (`customSelect`, `customInsert`) is
allowed only inside the repo for the table it owns.

---

## Atomic read-mutate-write for chat sessions

`ChatRepo.put()` is a full-row write for authoritative creation, import, or
replacement. It must not commit a mutation derived from a previously read
`ChatSession`: that snapshot may overwrite newer messages, drafts, variables, or
metadata.

```dart
// NEVER:
final session = await chatRepo.getByCharacterId(charId);
session.messages.add(newMsg);
await chatRepo.put(session); // race: another write may have happened between read and write

// ALWAYS: mutate the latest durable row inside the repository.
final durable = await chatRepo.mutateMessage(
  sessionId: sessionId,
  messageId: messageId,
  updatedAt: now,
  mutate: (latest) => latest.copyWith(isHidden: true),
);
```

Services/providers must not open an ad hoc transaction merely to perform
`get -> copyWith -> put`. Prefer the narrowest repository method:
`mutateMessage`, `mutateMessages`, `mutateAuthorsNote`, `renameSession`, draft
and session-variable methods, or swipe-specific methods. Use `mutateSession`
only when several session fields must change atomically. Other dedicated methods
include `appendSwipeToMessage`,
`appendAgentSwipe({kind: 'cleaned' | 'final'})` (nested blue sub-swipe +
`_syncAgentSwipesToMeta`), `updateAgentSwipeContent` / `removeAgentSwipe`
(in-place swipe editers used by the swipe-first cleaner flow — re-sync
`swipesMeta` the same way), and the chat/character variable-scope methods.

---

## Save before state cleanup

When finalizing a generation, persist data to DB **before** clearing reactive state.
If you clear `ChatState.isGenerating = false` first and the DB write fails, data is lost.

Order:
1. Await the targeted repository mutation.
2. Receive the exact durable `ChatSession` returned by the repository (or reload
   after a conflict/failure).
3. Publish that durable session to `ChatSessionService` cache/state.
4. Set `isGenerating` / post-generation state to settled.

Never cache an optimistic, generated, restoration, or pre-write snapshot.

---

## Schema migrations

All schema changes go in `AppDatabase.migration` in `app_db.dart`.
Bump the schema version and add a `from → to` migration step.
Never modify existing column types without a migration.

Current version: **124**

Migration history:
- v18: added `characters.picksHash`
- v19: added `characters.createdAt` + data migration (`SET created_at = updated_at WHERE created_at = 0`)
- v20: added `extension_presets` and `info_blocks` tables (extension system)
- v21: added `api_configs.cacheControlTtl` (Anthropic prompt cache control: 'off' | '5min' | '1h')
- v22: added `info_blocks.status` TEXT DEFAULT `'done'` + `info_blocks.order_` INTEGER DEFAULT 0 (block execution order + run status for ext blocks redesign)
- v23: added `api_configs.protocol` TEXT DEFAULT `'openai'` — wire protocol selector (openai / anthropic / gemini / openrouter). Drives `ChatTransport` factory routing
- v24: added `api_configs.topK` INTEGER DEFAULT 0, `api_configs.frequencyPenalty` REAL DEFAULT 0, `api_configs.presencePenalty` REAL DEFAULT 0
- v25: added `api_configs.cacheBreakpointMode` TEXT DEFAULT `'depth'` — Anthropic/OpenRouter prompt cache marker placement (`depth` / `stable_prefix`); `api_configs.sessionIdMode` TEXT DEFAULT `'openrouter'` — controls when `session_id` is sent for provider sticky routing
- v26: version bump only — no schema change (guards added to v20–v25 migration blocks)
- v27: added `info_blocks.swipe_id` INTEGER DEFAULT 0 (scopes ext blocks per message swipe); backfill `api_configs` columns missing from partial migrations (`top_k`, penalties, cache/session modes)
- v28: data migration — `UPDATE info_blocks SET swipe_id = 0 WHERE swipe_id IS NULL` (backfill for rows that survived v27 with NULL)
- v29: added `memory_catalog_rows` table for rebuildable per-session Memory Catalog state
- v30: added `chat_summaries.enabled` BOOL DEFAULT 1 (+ backfill NULL → 1)
- v31: added `character_folders` + `character_folder_members` tables (local character folders; composite PK `{folderId, charId}` enforces no-duplicate-within-folder)
- v32: added `characters.tokenCount` INTEGER DEFAULT 0 (cached estimated token count; computed on import/save, backfilled in background for existing rows)
- v33: added `characters.variantGroupId` TEXT + `characters.variantName` TEXT + `characters.variantOrder` INTEGER (character variations: rows sharing `variant_group_id` collapse to one list card; backfill sets each existing character's group to its own `char_id`)
- v34: added `characters.hidden` BOOL DEFAULT 0 (hideable characters: excludes a character/group from the My Characters list)
- v35: added Memory Graph tables (`memory_entity_rows`, `memory_salience_rows`, `memory_cadence_rows`, `memory_consolidation_rows`)
- v36: added `studio_config_rows`
- v37: added Studio `buildApiConfigId` / `runApiConfigId`
- v38: added Studio selected block ids fields
- v39: added Studio `finalPresetId`
- v40: added Studio request preset ids
- v41: added Studio preset overrides JSON
- v42: added Studio `profileId` / `profileName` for reusable session-bound profiles (removed in v101 — profiles retired, `studio_config_rows` is now session-only activation)
- v43: added Studio `builderPromptTemplate` override for editable Studio rebuild prompts
- v44: added Studio `maxFinalHistoryMessages` INTEGER DEFAULT 15 (raised to 30 in v64 and 50 in v123). It is now a high-water mark: after a completed assistant turn crosses the message limit or the 70K history-token limit, the stable final-generator window rotates forward by roughly half on a complete chunk boundary. Studio trackers retain their own `StudioAgent.contextSize` (default 5, hard-cap 200) — see INV-ST1/INV-ST2 in `docs/INVARIANTS.md`.
- v45: added `tracker_rows` table — lightweight key-value session state. Composite PK `{sessionId, name}`; indexed on `{sessionId, scope}`. Studio Ledger is the sole automatic model writer for canonical tracker state; manual canon overrides/locks use the same infrastructure. Rows are deleted in `chatRepo.deleteByCharacterId` and `characterRepo.delete` cascades and are shown in the Agentic Ops “Tracker values” tab.
- v46: added `studio_config_rows.routing_mode` TEXT DEFAULT `'verbatim'` — controls how preset blocks become agent instructions (`verbatim` = blocks concatenated дословно, no LLM call; `compiled` = legacy LLM digest). The decomposition service (`studio_decomposition_service.dart`) was later deleted during the user-preset unbind; agents are now defined directly in `StudioPreset.agents` with explicit `controllerId` routing. `routing_mode` itself was dropped in v55.
- v50: added `tracker_snapshots` table — per-agent-swipe immutable snapshots of all trackers (mirrors Marinara-Engine's `game_state_snapshots`). Composite PK `{sessionId, messageId, swipeId, agentSwipeId}`; columns `trackersJson` (JSON array of `Tracker.toJson`), `committed` (0/1), `createdAt` (epoch seconds). Three indexes on `(sessionId, committed, createdAt)` support fast `getLatestCommitted` reads. `TrackerSnapshotRepo` owns all access; snapshots preserve Ledger state for deletion, regeneration, swipe, and branch rollback.
- v51: data migration — aggregates `tracker_rows` per session into a baseline snapshot at the sentinel anchor `(messageId='', committed=1)`. Legacy sessions that had `tracker_rows` but no snapshots get a one-time baseline so the snapshot-first read path (Phase 3) finds data immediately. The sentinel anchor is never dropped by `deleteForMessage` (only by `deleteBySessionId` / `deleteByCharacterId`).
- v52: dropped `pipeline_settings_rows` — pipeline settings moved to a singleton in SharedPreferences (key `pipelineSettings`), per-session overrides abandoned. SharedPreferences payload unaffected.
- v53: added `info_blocks.agentSwipeId` INTEGER DEFAULT -1 — binds ext blocks to the blue cleaned sub-swipe so blocks launched after the POST-cleaner target the cleaned text. -1 = "no agent swipe" (legacy blocks, match by `(messageId, swipeId)` only).
- v54: added `studio_preset_rows` table — Studio prompts (controller ontology, runtime envelope, final brief, cleaner and Ledger prompts, beauty shard, extractors, block router, brief parser, shard synthesizers) migrated to   a DB table so the user can edit them without code changes. Seeded with the then-current hardcoded values via a single INSERT. See `docs/plans/studio-preset-db.md`.
- v55: Studio config overhaul — added `studio_preset_id`, `expensive_api_config_id`, `cheap_api_config_id`, `cleaner_api_config_id`; dropped `source_preset_id`, `source_preset_hash`, `routing_mode`, `agent_studio_preset_id`, `final_studio_preset_id`, `studio_preset_overrides_json`, `builder_prompt_template`, `selected_block_ids_json`, `selected_block_ids_initialized`, `build_api_config_id`, `build_model_override`. Unbinds Studio from user presets, switches to 3 API config slots + `studioPresetId`.
- v56: historical data migration — originally added `cleaner_beauty` and refreshed the then-active `writeloop_system` block. The generic write-loop is retired; current migration code adds current missing seed blocks but preserves existing user `writeloop` JSON as inert data.
- v57: data migration — moves `cleaner_beauty` to the end of the cleaner section (`order` 99) so the LLM sees styling instructions last among preset blocks (recency effect).
- v58: data migration — `<lumiaooc>` coloring moved out of the LLM cleaner prompt into deterministic code (`wrapLumiaOocColors` in `beauty_state_parser.dart`). Force-updates the `cleaner_beauty` and `final_lumia_ooc` blocks in the existing `default` preset from the updated seed so the old lumiaooc coloring rule and the `reserved.lumia_ooc` JSON-shape field are dropped. Existing user customizations to other blocks are preserved.
- v68: added `character_knowledge_fact_rows` and `character_session_baseline_rows` for provenance-backed character developments and card baselines.
- v71: removed the retired `durableFacts` contract from the default Ledger prompt.
- v73: added `ledger_reconciliation_checkpoints` for reconciliation cadence and deduplication.
- v77: added `ledger_reconciliation_cleanup_journals` for reversible knowledge cleanup when deleting reconciled history.
- v78: versioned upgrade action initializes the
  `gz_disabled_third_party_providers` SharedPreferences key when absent (no
  Drift table change).
- v79: added `api_configs.reasoningHistoryCount`; existing rows are backfilled
  from `includeLastReasoning`.
- v80: added `api_configs.useResponsesApi`.
- v81: added composite index `idx_embeddings_source_type_id` on
  `(source_type, source_id)`.
- v82: added durable card-rewriter revisions, jobs, operations, evidence,
  transitions, references, and numeric revision provenance columns.
- v83: rebuilt the unreleased v82 TEXT revision columns as INTEGER columns,
  preserving rows, uniqueness, and indexes while normalizing numeric lineage.
- v85: added durable rewrite job/operation CAS, decision/validation, and applied
  character revision fields; rebuilt `rewrite_operations` after adding neutral
  defaults so upgraded databases retain rows/indexes and enforce the fresh-schema
  decision, validation-status, and revision CHECK constraints.
- v86: added the durable Phase-4 rewrite job lifecycle columns
  (`rewrite_jobs.status_reason` TEXT NULL, `canon_stamp` TEXT NOT NULL
  DEFAULT '', `request_key` TEXT NULL with the unique
  `idx_rewrite_job_request_key` index — NULL keys stay distinct) and rebuilt
  both `rewrite_jobs` (status CHECK: generating/pending/failed/cancelled/
  applied) and `rewrite_operations` (status CHECK: pending/reviewable/applied,
  with the four v85 CHECKs and the apply-CAS index retained). Out-of-domain
  legacy statuses are normalized fail-closed before the rebuild (jobs →
  'cancelled', operations → 'pending'); rows are preserved.
- v99: moved Studio agents, the three API slots, and final-history limit from
  `studio_config_rows` to dedicated `studio_preset_rows` columns. Distinct
  canonical profile payloads are retained as deterministic migrated presets;
  config rows now retain only activation, identity, and timestamps.
- v100: added `studio_preset_rows.runtime_settings_json` TEXT NOT NULL DEFAULT
  `'{}'` for canonical nested Studio runtime settings storage.
- v101: retired the old Studio profile system. `studio_config_rows` rebuilt to
  session-only columns (`session_id`, `enabled`, `created_at`, `updated_at`);
  `profile_id`, `profile_name`, `broadcast_blocks_json`, and all other profile
  columns dropped. Legacy `broadcast_blocks_json` is merged into each preset's
  `runtime_settings_json.broadcastBlocks` during migration. Only rows whose
  `session_id` exists in `chat_sessions` are retained; canonical profile-only
  rows are dropped (their runtime payloads were already preserved as migrated
  presets in v99).
- v103: added `preset_folders` + `preset_folder_members` tables (folders for the
  Presets list, mirroring the character folders). Membership PK is
  `{folderId, presetId, kind}` — `kind` is `normal` for rows in `presets` and
  `agentic` for rows in `studio_preset_rows`, whose id spaces are independent,
  so it must be part of the key. Deleting a preset must also drop its member
  rows (`PresetFolderRepo.deleteMembersForPreset`).
- v105: removes the retired default Studio write-loop block (`writeloop_system`)
  from stored presets. Idempotent — presets without the block are skipped.
- v106: repairs the `injectionPoint` field of stored preset blocks whose routing
  was corrupted by the canonical codec shipped in nightly #197 (which did not
  read `injectionPoint` from JSON, defaulting every block to `pregen`). Runs
  `migrateStudioPresetBlocksToV2` on each preset's blocks and writes the
  repaired JSON back. Idempotent — presets that were never affected are skipped.
- v107: added `api_configs.exclude_reasoning_from_context_budget` BOOLEAN
  DEFAULT 0.
- v108: added `card_evolution_observations`.
- v109: rewrites `protocol = 'openai'` rows with `use_responses_api = 1` to
  `protocol = 'openai_responses'`. The Responses API is now a protocol of its
  own instead of a boolean opt-in, and `use_responses_api` is derived from it.
- v110: added `api_configs.use_system_instruction` BOOLEAN NOT NULL DEFAULT 1 —
  whether the leading system run is lifted into the provider's own field.
  Defaults on, which is the behaviour that shipped before the toggle existed.
- v111: collapses `api_configs.session_id_mode` to a two-state toggle. The
  retired default `'openrouter'` meant "send only to openrouter.ai", so rows
  still holding it become `'always'` when the preset is an OpenRouter one (by
  protocol or by endpoint) and `'off'` otherwise. Explicit `'always'`/`'off'`
  rows are untouched.
- v112: renames `api_configs.gemini_use_system_instruction` to
  `use_system_instruction` — the toggle covers Anthropic's `system` as well as
  Gemini's `system_instruction`. Guarded: runs only on databases that still
  carry the prefixed name (v110/v111 builds of the branch that introduced it).
- v113: added independent evidence clusters to card evolution observations and
  migrated legacy evidence into one canonical cluster.
- v114: rebuilt `character_revision_rows` so revision hashes are non-unique.
  Returning to earlier card content now appends a valid lineage entry; a
  non-unique `(character_id, revision_hash)` index retains lookup performance.
- v121: added append-only `session_canon_checkpoint_rows`, append-only
  `session_lorebook_revision_rows`, and durable
  `session_lorebook_embedding_job_rows` for branch-scoped Card Rewriter state.
  Message deletion rolls invalidated canon forward by appending a rollback
  checkpoint and restoration history; it never updates immutable rows. Because
  v121 has no lore tombstone, an overlay target absent at the selected
  checkpoint is restored to its recorded source/base content.
- v122: added `api_configs.embedding_requests_per_minute` INTEGER NOT NULL
  DEFAULT 50 for the process-wide embedding request rate limit.
- v123: raised the default Studio final history limit from 30 to 50
- v124: added bounded local `llm_request_capture_rows` diagnostics

---

## Atomic single-column updates

For status fields that change frequently (e.g. block run status during extension
post-generation), use a dedicated repo method that updates only the target column
rather than reading and re-writing the entire row:

```dart
// GOOD — atomic, minimal I/O
Future<void> updateStatus(String id, BlockRunStatus status) =>
    (db.update(db.infoBlocks)..where((t) => t.id.equals(id)))
        .write(InfoBlocksCompanion(status: Value(status.name)));

// BAD — full row read-mutate-write for a single column change
final block = await getById(id);
await put(block.copyWith(status: status));
```

Pattern: `InfoBlocksRepository.updateStatus()` is the canonical example.

---

## Atomic read-mutate-write for JS variable scopes

The JS bridge (`JsBridgeService._updateScope`) writes four variable
scopes. The `chat` and `character` scopes go through dedicated repo
methods that wrap the read-modify-write in a Drift transaction so two
concurrent bridge calls cannot interleave:

```dart
// ChatRepo.updateSessionVarsJson
await db.transaction(() async {
  final session = await repo.getById(sessionId);
  final next = mutator(_decodeChatVars(session.sessionVars));
  if (next.isEmpty) session.sessionVars.remove(_chatVarsKey);
  else session.sessionVars[_chatVarsKey] = jsonEncode(next);
  await repo.put(session);
});

// CharacterRepo.updateExtensionsJson — same shape, on the extensions map.
```

`global` variables go through `GlobalVariablesRepo` (SharedPreferences
JSON) with a serialized write lock (`_writeLock`) and a 64 KiB payload
cap. `message` variables are in-memory only (`MessageVariablesNotifier`).

**Never** do `getById → mutate → put` for any of these scopes —
always go through the dedicated repo method.

---

## Embedding storage

Table: `Embeddings`
Schema: `{ entryId, sourceType, sourceId, vectorsBlob (BLOB), textHash, retrievalHintsJson (JSON text), errorJson (JSON text), updatedAt }`

- Vectors stored as binary float32 BLOB via `vectorListToBytes()` free function in `vector_math.dart` (not a method on `EmbeddingRepo`).
- `textHash` used for dirty-check: if hash matches stored hash, skip re-embedding.
- `sourceType`: `'lorebook_entry'` | `'memory_entry'` | `'chat_message'`
- `entryId` namespaced as `lorebookId_entryId` to prevent cross-lorebook collisions.
- `retrievalHintsJson` is JSON text (not BLOB).
- `errorJson` stores embedding error details (classification via `EmbeddingErrorLabel`).

---

## Deletion and clear lifecycles

`SessionDeletionQueries` is the canonical DB-only session cascade.
`SessionDeletionRepo.deleteSession` wraps it for one session;
`ChatRepo.deleteByCharacterId` applies it to every character session; and
`CharacterDeletionRepo.deleteCharacters` composes the complete character
cascade in one transaction.

The session cascade removes MemoryBook state, Memory Catalog/Graph rows, live
trackers and snapshots, reconciliation checkpoints/journals, character
knowledge, summaries, InfoBlocks, chat/message-memory embeddings, session
baseline, Studio config, chat-scoped lorebooks and their embeddings, and the
chat row. Character deletion additionally removes character-scoped lorebooks
and embeddings, folder memberships, character rows, and promotes a remaining
variation representative when required.

`CharactersNotifier.removeMany` performs sync tombstones, preference cleanup,
and filesystem cleanup only after the DB transaction commits. Remote sync
deletion uses the same neutral deletion stores without creating local
tombstones.

**Clear chat is not delete session.** `SessionDeletionRepo.clearSession`
transactionally replaces messages and clears message-derived runtime state,
while retaining session identity/settings, baseline, Studio config, chat
bindings, and the MemoryBook settings row (entries/drafts are reset). In-chat
clear rebuilds its greeting, resets the branch stamp, and counts deleted
messages; history-list clear supplies an empty replacement without those
options.

When adding session- or character-owned storage, update the shared lifecycle
queries and their full-cascade/clear/rollback tests rather than adding a new
provider-level deletion list.

---

## Reactive streams

`CharacterRepo.watchAll()` returns a `Stream<List<Character>>` (Drift reactive query).
`CharactersNotifier` subscribes to this stream — UI rebuilds automatically on any change.

For other tables that need reactive updates, add a `watch*` method to the repo.
Do not poll; use Drift streams.

---

## MemoryBook compatibility cleanup (v66)

`MemoryBookRows.entriesJson` and `pendingDraftsJson` are JSON TEXT blobs, so
adding model fields requires no Drift schema migration. Pre-v66 builds could
create `source: 'agentic'` entries through the generic tracker write-loop.
That writer is retired.

`AppDatabase.purgeRetiredAgenticMicroMemory()` is intentionally retained for
schema upgrades and backup/cloud restores. It removes only those historical
agentic entries/drafts and their derived embedding/catalog/entity/salience rows;
it preserves manual entries, scan drafts, range summaries, Studio Ledger facts,
and MemoryBook settings. Normal MemoryBook scan and approval flows remain
user-directed and go through `MemoryBookRepo`.

Deleting an assistant message still calls
`MemoryBookRepo.deleteForMessage(sessionId, messageId)` to retract any normal
MemoryBook items sourced from that message.

---

## Tracker snapshot rollback system

`tracker_snapshots` is an immutable per-agent-swipe snapshot of canonical
tracker state, written after Studio Ledger applies an accepted update. Rollback
is **emergent**: deleting rows makes the preceding committed snapshot the
latest, then `tracker_rows` is restored from it.

### Granularity

Each snapshot is anchored at `(sessionId, messageId, swipeId, agentSwipeId)`:
- `messageId` — the assistant message whose accepted state Ledger recorded.
- `swipeId` — which swipe of that message (regen creates new swipes).
- `agentSwipeId` — which agent sub-swipe (e.g. `'final'` vs `'cleaned'`).

This per-agent-swipe granularity (chosen explicitly over per-message or
per-session) lets the rollback system restore state at the exact level the
user navigates: swiping back through agent sub-swipes restores the matching
tracker state.

### Sentinel anchor for legacy data

Migrated `tracker_rows` (Phase 7 migration v51) become a baseline snapshot
at the sentinel anchor `(messageId='', committed=1)`. This anchor is
**never** dropped by `deleteForMessage` (only by `deleteBySessionId` /
`deleteByCharacterId`), so legacy sessions always have a baseline until the
session itself is deleted.

### Write path

Studio Ledger applies typed tracker operations, re-reads the resulting state,
and upserts an immutable snapshot at that anchor via
`TrackerSnapshotRepo.upsertTrackers`. The snapshot is initially `committed=0`.

`commitLatest` is called by `ChatNotifier.sendMessage` just before the next
generation starts. Committed snapshots are surfaced by the read path;
uncommitted snapshots are tentative state from the most recent Ledger pass.

`post_cleaner_service.applyCleanedText` (Phase 2) clones the parent
message's snapshot into the new `'cleaned'` agent-swipe anchor so the
cleaned sub-swipe inherits the parent's tracker state.

### Read path (snapshot-first)

The Ledger and tracker-values UI call `getLatestCommitted` / `getLatest` and
fall back to `trackerRepoProvider.getBySessionId` when no snapshot exists
(legacy sessions that have not yet produced a snapshot).

### Rollback paths

| User action | Repo method | Effect |
|-------------|-------------|--------|
| Delete a message | `ChatRepo.deleteMessage` → `trackerSnapshotRepo.deleteForMessage` + `trackerRepo.replaceForSession` + `memoryBookRepo.deleteForMessage` | All snapshots at that `messageId` are dropped; the preceding committed snapshot becomes the latest. The live `tracker_rows` store is restored from it, so Tracker values and Studio state reflect the prior accepted message. MemoryBook items whose `messageIds` contains the deleted `messageId` are also dropped. |
| Delete a session | `chat_history_provider.deleteSession` → `deleteBySessionId` + `SyncDeletionTracker.record('tracker_snapshot', sessionId)` | All snapshots for the session are dropped; cloud sync deletion is tracked. |
| Clear chat | `SessionDeletionRepo.clearSession` | Replaces messages and purges message-derived runtime rows, including snapshots, while preserving the session, baseline, Studio config, bindings, and MemoryBook settings. |
| Delete by character | `CharacterDeletionRepo.deleteCharacters` → shared session cascade | All snapshots and other session-owned rows for all character sessions are dropped atomically. |
| Swipe removal | `trackerSnapshotRepo.shiftSwipeIdsAfterRemoval` | Re-keys snapshots whose `swipeId` > removed id, preserving continuity. |
| Branch session | `chat_session_service.branchSession` → `copyForSessionBranch` | Copies snapshots for sliced message IDs to the new session ID. |

### Cloud sync coverage (Phase 9)

`tracker_snapshots` entered the backup format at v5 and remains in the current
backup whitelist (`backup_exporter.dart`, backup schema v10). It has full cloud
sync coverage via
`SyncTrackerSnapshotStore` + `TrackerSnapshotSyncStore` adapter. Sync
follows the InfoBlock per-session collection pattern: one entry per
session, payload `{__trackerSnapshots:true, items:[...]}`. Deletes are
tracked via `SyncDeletionTracker.record('tracker_snapshot', sessionId)`.

### Never

- **Never** read-modify-write a `ChatSession` / `Character` from outside
  the dedicated atomic repo methods (this applies to the chat/character
  variable scopes — see "Atomic read-mutate-write for JS variable scopes"
  above). Tracker snapshots follow the same rule: use
  `TrackerSnapshotRepo.upsertTrackers` / `deleteForMessage` /
  `deleteBySessionId` etc. — never `getById → mutate → put`.
- **Never** mutate an existing snapshot row. Snapshots are write-once; the
  only allowed writes are `upsertTrackers` (insert-or-replace by PK),
  `commit` / `commitLatest` (flip `committed` 0→1), and delete methods.
- **Never** drop the sentinel anchor `(messageId='')` via
  `deleteForMessage`. Only `deleteBySessionId` / `deleteByCharacterId`
  may drop it.

---

## Session branch policy

`ChatSessionService.branchSession` creates the branch, copies DB state,
reconstructs live tracker rows, and updates the character's current session in
one Drift transaction. Session baseline and
Studio configuration are copied as settings. Provenance-backed state is copied
only when its complete source range is retained: tracker snapshots, character
knowledge facts, reconciliation checkpoints, cleanup journals (copied with the
fact provenance operation), completed
InfoBlocks, and MemoryBook entries/drafts with non-empty `messageIds`.

Live tracker rows are reconstructed from the latest copied snapshot. Generated
summary content is reset while its enabled/prompt settings are retained.
MemoryBook settings are retained, but unprovenanced entries and drafts are
reset; retained items receive branch-local IDs. Memory Catalog, Memory Graph
(entity/salience/cadence/consolidation), and memory embeddings are not copied:
they are derived indexes and must rebuild from the branch's retained MemoryBook
and chat history. Preference bindings live in SharedPreferences and are copied
only after the database transaction commits and are best-effort follow-up
state; they cannot roll back the durable branch.
