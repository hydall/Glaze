# Roadmap

## Purpose

This file tracks the current implementation roadmap for the chat context pipeline, summary flow, lorebook retrieval, and future memory systems.

It is the source of truth for:
- what is already done;
- what was intentionally rejected;
- what is currently planned next;
- the intended architecture direction, so work can resume after unrelated tasks without re-deciding old questions.

## Task Tracking Rules

Every roadmap item should be broken into smaller concrete subtasks whenever possible.

For each task or subtask, always record:
- completion status: `done` or `not done`
- testing status: `tested` or `not tested`

If something is only partially complete, split the unfinished portion into a separate follow-up subtask instead of leaving one broad mixed-status item.

`Roadmap.md` should also explicitly call out what still requires manual user verification, so pending checks are visible and can be tested directly from the roadmap.

## Current Direction

The current roadmap is:

1. Finalize the summary block
2. Implement vectorization
3. Add vector-based lorebook entries and retrieval
4. Build memory books on top of that foundation

This roadmap intentionally assumes the tokenizer and current context UI are already in place and are not being redesigned again unless a new decision is made explicitly.

## Decisions Already Made

These decisions are considered settled unless explicitly reopened:

- Source-based token breakdown is the correct direction.
- The tokenizer stays in the current UI flow.
- The previously discussed top tokenizer button / separate top bar is not part of the plan.
- Lorebook reserve stays in the current model; the earlier idea of moving it outside the context budget was rejected.
- History management is based on hiding the upper part of history rather than introducing a separate trim model.
- The tokenizer color model is already implemented and should be preserved unless there is a specific bug.

## Done

The following work is considered completed:

- Reworked token breakdown from heuristic estimation toward source-based attribution.
- Split context attribution into:
  - Character
  - Preset
  - Summary
  - Author's Note
  - Lorebook
  - History
- Fixed attribution issues caused by macro replacement order.
- Fixed lorebook attribution bleed when lorebook content is injected through macros like `{{lorebooks}}`.
- Moved tokenizer/context access from header UI into MagicDrawer.
- Renamed the quick-access entry to `Tokenizer`.
- Moved `Hide top messages` into the tokenizer sheet above `Settings`.
- Preserved the current hide flow, including summary handoff and related settings.
- Added and stabilized the current tokenizer color-based presentation.
- Fixed legacy / SillyTavern-style preset block ID compatibility for token counting and attribution.
- Added per-character `{{char}}` macro override support via a dedicated character card field, so macro naming can differ from the card title.

## Rejected / Not Planned

These items were discussed previously but are currently not part of the roadmap:

- Moving lorebook reserve outside the context budget.
- Reintroducing a top tokenizer button / top progress bar entry point.
- Replacing the current hide-based history flow with a separate trimming model.

These should stay documented so they are not accidentally reintroduced during future refactors.

## Active Roadmap

### 1. Summary Block (core implementation done)

Goal:
Make summary generation and summary saving a first-class, explicit workflow with clear user actions and predictable prompt behavior.

Summary is not just a recap feature. It is intended to serve as a practical fallback alternative to Memory Books for users who do not have access to embedding models.

Target behavior:
- The summary area should expose three explicit actions:
  - Summarize without block
  - Summarize with block
  - Save
- The distinction between "without block" and "with block" must be clear in logic and UI.
- `Summarize without block` is the clean rebuild path:
  - intended for a new chat with no prior summary;
  - still remains available later if the user wants to regenerate summary from scratch.
- `Summarize with block` is the update path:
  - intended for an existing chat with saved summary;
  - updates the current memory-like summary instead of rebuilding from zero.
- Saving summary content must remain possible independently from generation.
- The summary workflow should be easy to extend later when memory systems are introduced.
- The summary workflow must support user-defined summarization instructions without overloading the main UI.
- Summary should be designed around structured sections instead of one monolithic text block.

Architecture direction:
- Summary generation should not depend on the active preset pipeline in the same way normal generation does.
- Summary prompting should use its own dedicated request path.
- The summary request should be structured so it can evolve independently from normal chat generation.
- The summary result should be storable as durable chat state and also remain usable by the tokenizer/context UI.
- Summary should be stored as structured sections rather than plain text.
- Summary updates should support delta-based regeneration using messages since the last summary point plus an overlap window.
- The overlap window should allow the model to preserve continuity around the handoff boundary.
- Hidden messages should remain usable as summary input when building or updating summary, as long as the request remains within the available context budget.

Implementation status (done):
- `src/core/services/summaryModel.js` — section parser, serializer, model CRUD, delta range, per-section prompts, update from generation results
- `src/core/services/__tests__/summaryModel.test.js` — 28 unit tests
- `src/views/ChatView.vue` — model-aware persistence (openChat, asyncSave, deep watcher), legacy string migration
- `src/views/PresetView.vue` — per-section generation (parallel with sequential fallback), per-section regenerate buttons, token budget
- `src/core/services/generationService.js` — generateSummary with proper prompt passthrough

Implemented features:
- Section-based storage: timeline, characterArcs, conflictsThreads, notHappenedYet, notes
- Delta-based updates with configurable overlap (10 messages)
- Token budget: uses 50% of (contextSize - maxTokens) instead of hardcoded slice(-50)
- Multi-request generation: 5 parallel API requests (one per section), falls back to sequential on error
- Per-section regenerate buttons in advanced sheet
- Per-section prompt templates with focused instructions
- Two generation paths: fresh (full history) and update (delta + current sections)
- Metadata tracking: updatedAt, messageCount, tokenCount, lastMessageIndex
- Backward compatible: legacy string summaries auto-migrate to section model
- Two modes: Advanced (per-section generation, instruction editing, second screen) and Simple (single-request, no second screen)
- Advanced mode toggle persisted in localStorage (`gz_summary_mode`)
- Per-section custom instructions with Save/Restore Default UI in advanced sheet
- Sections with empty custom instructions are dimmed and skipped during generation
- Simple mode uses `buildSummaryPromptForFresh`/`buildSummaryPromptForUpdate` — one API request, result parsed into sections
- Persistence on Done/Back in advanced sheet — `char._summaryModel` always stays in sync

Remaining work:
- **Simple mode prompts need proper defaults and editability.** Currently simple mode uses a generic "Summarize the following roleplay conversation..." prompt. This needs:
  - Two distinct, well-written default prompts: one for fresh summary, one for update.
  - A way for the user to view and edit these prompts without adding clutter to the main screen.
  - Possible approach: a small "edit prompt" link/button that expands an inline textarea, similar to the instruction UI pattern in advanced mode.
  - The prompts should support `{{char}}`, `{{user}}`, `{{history}}` macros at minimum.
  - Stored per-chat or globally (likely globally in localStorage or in the preset).
- **Grouped section updates** (e.g. two sections at a time) — infrastructure ready, not wired in UI.
- **Summary UI polish** — deferred until the model is battle-tested in real usage.

### 2. Vectorization (stable — WORKS, do not touch unless there is a concrete bug)

Goal:
Introduce vector infrastructure so semantic retrieval can be added cleanly instead of relying only on keyword activation.

Tokenizer commits are preserved in `archive/feat/tokenizer` (4 cherry-picks from `archive/feat/summary`):
- `dc43605` feat: add chat context breakdown controls
- `2fc893a` feat: source-based token breakdown, tokenizer sheet in MagicDrawer, summary refactor, lorebook reserve mode
- `b73d9a0` fix: normalize legacy preset block ids for token counting
- `8eceba4` feat: add per-character {{char}} macro override

Decisions made:
- **Separate embedding API config** — endpoint, model, key, identical UX to LLM API settings. Toggle "Use same as LLM" enabled by default. Local embeddings work by pointing endpoint at localhost (Ollama, LM Studio, text-embeddings-inference — all expose OpenAI-compatible `/embeddings`).
- **Endpoint normalization** — the user can paste either `https://api.rout.my/v1/embeddings` or `https://api.rout.my/v1` and it works. Code strips trailing `/embeddings` then appends it back on API call.
- **No chat vectorization** — chat messages are embedded on-the-fly per generation as a query vector, never stored. The query is assembled statelessly from the last N messages at generation time and discarded after matching.
- **Only lorebook entries (and later memory books) get stored vectors.** Infrastructure is extensible for future source types but chat is explicitly out of scope.
- **Embedding target is configurable:** user chooses whether to embed entry content or entry keys. Setting lives in the embedding API config. Default is content (richer embeddings, better semantic matching). Keys option available for very long entries or models with small context.
- **Storage:** IndexedDB, separate `embeddings` store. Schema: `{ id, sourceType, sourceId, vector[], textHash, updatedAt }`. `sourceType` allows future expansion (`"lorebook_entry"`, `"memory"`, etc.). Vectors are NOT exported with lorebook JSON — they stay in IndexedDB only.
- **Invalidation:** `textHash` (SHA-256) on stored vectors. If entry content changes, hash differs → re-embed on next index.
- **Search:** cosine similarity between query vector (from chat) and stored entry vectors. Top-K results above configurable threshold. Results merged with keyword matches (deduplicated by entry id).
- **Vector search depth:** configurable parameter (how many recent chat messages to include in query), similar to keyword scan depth.
- **Auto-chunking:** `maxChunkTokens` setting (default 8192). Long texts are auto-split at sentence/paragraph boundaries, chunks are embedded separately, then averaged into a single vector.
- **Bulk operations:** "Enable/Disable Vector Search All" toggle and "Index All Vector Entries" action available per lorebook via entries menu.
- **Default topK:** 10 (was 5, raised because users with large lorebooks need more results).

Architecture direction:
- Vectorization is implemented as infrastructure first, not lorebook-specific hacks.
- Embedding generation, storage, invalidation, and lookup are separated from the UI layer.
- The retrieval layer is designed so memory books can reuse it later.
- Vector search runs AFTER the keyword-based worker scan, in `generationService.js`. Results are merged (union, deduped by entry id). This keeps the worker synchronous and avoids IPC complexity.
- `embeddingService.js` handles both native (CapacitorHttp) and web (fetch) paths, same pattern as `llmApi.js`.

Implementation pieces (done):
- `src/core/config/embeddingSettings.js` — embedding API config (endpoint, model, key, target, scanDepth, threshold, topK, maxChunkTokens), endpoint normalization, "use same as LLM" toggle
- `src/core/services/embeddingService.js` — `getEmbedding(text)`, `getEmbeddings(texts[])`, auto-chunking, Capacitor native + web fetch, `testEmbeddingConnection()`
- `src/utils/vectorMath.js` — `cosineSimilarity(a, b)`, `findTopK(queryVector, candidates, k, threshold)`
- `src/utils/db.js` — `embeddings` IndexedDB store (DB_VERSION 7), CRUD methods: `getEmbedding`, `getAllEmbeddings`, `getEmbeddingsBySource`, `saveEmbedding`, `deleteEmbedding`, `deleteEmbeddingsBySource`
- `src/core/states/lorebookState.js` — `indexLorebookEntry` (single, hash-check), `indexLorebookEntries` (bulk, per-entry hash-check, progress callback, failed count), `getEmbeddingStatus`, `vectorSearchLorebooks`; entries with `vectorSearch` flag are excluded from keyword matching
- `src/core/services/generationService.js` — vector search merged into `generateChatResponse` after worker returns
- `src/workers/generationWorker.js` — entries with `vectorSearch` flag excluded from `scanLorebooksPure`
- `src/views/ApiView.vue` — embedding settings section: enable toggle, use-same-as-LLM toggle, endpoint/model/key fields, target selector, scan depth, threshold slider, topK, max chunk tokens, test connection button
- `src/components/sheets/LorebookSheet.vue` — per-entry `vectorSearch` toggle, "Index Entry" button with status, visible toolbar with "Enable/Disable Vector All" and "Index All" buttons, progress display (X of Y), result summary (indexed/skipped/failed), `vec` + `idx` badges in entries list, injection position restricted to @worldInfoBefore/@worldInfoAfter with macro override hint
- `src/locales/en/index.json` + `src/locales/ru/index.json` — i18n keys for vector search UI
- Retrieval metadata is auto-generated during embedding indexing and stored alongside embedding records as `retrievalHints` (derived from `comment`, `keys`, and early `content` lines / `Label: Value` fragments).
- Embedding invalidation now fingerprints both indexed text and `retrievalHints`, so `Index All` can refresh stale retrieval metadata without requiring content edits.
- Retrieval now combines `focused` user/current-query search with `fallback` recent-context search instead of choosing only one path.
- Ranking now applies lightweight `hybridBoost` (`comment`/`keys`) and `descriptorBoost` (early `content` + `retrievalHints`) on top of vector similarity.
- Indexing now stores per-entry diagnostics for failed embeddings, including user-visible error status (`err`), reason text, and retry-only-failed flow.
- A reproducible automated QA check now covers the vector-only path end-to-end:
  - entry indexes successfully;
  - semantic retrieval matches it;
  - it appears in `triggeredLorebooks`/`loreEntries`;
  - it is injected into the final prompt.

Current status:
- **Vector lorebook retrieval is considered working.**
- **Do not reopen or refactor vector backend now unless there is a concrete regression or a narrowly scoped bug.**
- Remaining vector work, if any, should be treated as optional quality tuning rather than foundational backend work.

Known issues / remaining:
- **Vector ranking is still too scene-biased for some character retrieval.** Real test case: after an opening message about `Forum`/`Sina` and a follow-up request describing a blue-haired catgirl, retrieval still ranked `Forum`, `Sina`, `girls dormitory`, `Siri Wing`, `Orel`, `Dara`, etc. above `Asei`, even after reindexing and auto-hints. This confirms the pipeline works technically, but ranking still needs stronger entity/appearance-aware bias and/or weaker fallback influence.
- Summary simple mode prompts still need proper defaults and editability.

Expected result:
- The project gains a reusable vector layer rather than a one-off lorebook feature.

### 3. Vector Lorebook Entries (merged into phase 2 above)

Merged with vectorization — building both together since lorebook is the primary consumer.

Design answers:
- Vector search is **per-entry** toggle (each entry can opt in).
- Vector search **replaces** keywords for entries with `vectorSearch` enabled — those entries are excluded from keyword scan and only matched via semantic similarity.
- Number of vector matches controlled by existing lorebook reserve/budget logic.
- Collisions handled by deduplication — if keyword match already found the entry, vector match is skipped.

### 4. Memory Books

Goal:
Build a higher-level long-term memory system on top of the already stabilized summary and vector layers, without introducing a second fragile lore/memory pipeline that will need a rewrite later.

Current pain points that must be solved:
- [done | tested] First memory creation is no longer manual — Scan Chat + Generate Drafts batch flow available.
- [done | tested] Per-message markers: MEM (approved), DRAFT (pending drafts), PENDING (automation queue), REBUILD, STALE badges.
- [done | not tested] Deleting messages or branching a chat can leave orphaned / stale memories that no longer match the current chat history.
- [done | tested] Imported chats can use Scan Chat to segment history and Generate Drafts to bootstrap memory entries. Auto-draft on import disabled; user must manually trigger.
- [not done | not tested] Memory books need to behave like lorebooks for retrieval features (vectors, keys, Glaze keys), but they must inject into the summary area and have a separate activation/count budget from normal lorebooks.
- [not done | not tested] Memory usage should appear in the tokenizer/context UI as summary-like context, not as normal lorebook context.
- [not done | not tested] Import/export and future cloud sync integration must not break when memory books are introduced.
- [done | not tested] Cloud sync already exists on `feat/cloud-sync` / PR #20 with `syncEngine`, `syncService`, `syncQueue`, conflict resolution UI, encryption, and `updatedAt`-aware DB changes. Memory books must plug into that model instead of inventing a parallel sync path.

Architecture direction:
- [done | not tested] Reuse the existing vector infrastructure rather than creating a separate memory retrieval engine. The current embeddings schema already supports future `sourceType` expansion beyond `lorebook_entry`.
- [done | not tested] Reuse lorebook-style entry semantics for memory entries: keys, vector search, retrieval hints, and inspectable entry records remain the correct primitive.
- [done | not tested] Do not make memory books just a hidden naming convention inside normal lorebooks. They need their own container/type so lifecycle, injection budget, UI, and sync/import behavior are explicit.
- [done | not tested] Keep memory entries structurally compatible with lorebook entries where possible, but store memory-book metadata separately from normal lorebook presentation concerns.
- [done | not tested] Message-range ownership must be first-class. Memory entries should track the message range or explicit message IDs they summarize so lifecycle operations can be deterministic.
- [done | not tested] Memory retrieval injects into the summary block path with its own budget. Memory injection filter: entries only eligible when first segment message leaves context window.

Recommended implementation shape:
- [done | not tested] Introduce a dedicated memory book container persisted per chat/session, instead of storing memory books as ordinary lorebooks only.
- [done | not tested] Keep each memory entry lorebook-compatible internally at the schema level: `content`, `keys`, `vectorSearch`, and `glazeKeys` are now present so retrieval wiring can build on stable entry fields.
- [done | not tested] Add memory-specific metadata on top of the entry data:
  - `messageRange` / explicit message IDs covered by the entry
  - source session ID
  - derived segment hash/fingerprint
  - lifecycle status (`active`, `stale`, `orphaned`, `needs_rebuild`)
  - creation mode (`manual`, `auto`, `import_bootstrap`)
- [not done | not tested] Treat the memory book as a dedicated chat-level data container that can feed a summary-like prompt block during generation while still reusing indexing/search internals.

Why this shape is preferred:
- [done | not tested] The generation pipeline already distinguishes `summary` and `lorebook` token sources, so memory books can be integrated as a summary-adjacent source without pretending they are ordinary lorebook injections.
- [done | not tested] Messages already expose `triggeredLorebooks`, which means the chat UI already has a pattern for showing source-trigger metadata on individual messages.
- [done | not tested] Chat lifecycle events already exist in `ChatView.vue` for delete, branch, import, and save flows, which gives a clear place to attach memory lifecycle maintenance.
- [done | not tested] Import/export already goes through centralized chat/backup services, so a dedicated memory container is safer than hiding memory state inside ad hoc lorebook fields.

Planned execution order:
- [done | not tested] 4.1. Data model and persistence foundation.
- [done | not tested] 4.2. Lifecycle maintenance tied to chat mutations.
- [done | not tested] 4.3. Retrieval and prompt injection integration.
- [done | not tested] 4.4. UI and tokenizer visualization.
- [done | not tested] 4.5. Import/export/bootstrap and cloud-sync-safe serialization foundation in this branch.
- [not done | not tested] 4.6. Automation rules and quality tuning.

4.1. Data model and persistence foundation:
- [done | not tested] Add a dedicated persisted memory-book container per chat/session.
- [done | not tested] Define a memory entry schema that extends lorebook-compatible entry fields with message ownership metadata.
- [done | not tested] Add deterministic identifiers for memory books and entries so imports, sync merges, and branch operations can reconcile data instead of duplicating it.
- [done | not tested] Decide whether message ownership uses stable message IDs, timestamps, or both. Current recommendation: introduce explicit stable message IDs and keep timestamps as secondary metadata.
- [done | not tested] Add DB migration / persistence support so memory books survive chat reloads, backup restore, and future sync.
- [not done | not tested] Align memory persistence with the cloud-sync data model from PR #20: stable IDs, `updatedAt`, conflict-safe records, and deterministic serialization.

4.2. Lifecycle maintenance tied to chat mutations:
- [done | not tested] On message deletion, detect memory entries whose covered range is now invalid and mark or rebuild them instead of leaving stale memories behind.
- [done | not tested] On chat branching, reconcile memory books explicitly instead of copying them blindly.
- [done | not tested] Copy only memory entries whose covered message IDs/ranges are fully preserved inside the new branch history.
- [done | not tested] If a memory entry only partially survives the fork boundary, do not keep it active; mark it as `needs_rebuild` or convert it into a draft for re-approval.
- [done | not tested] If a memory entry belongs only to messages that do not exist in the child branch, remove it from the child branch entirely.
- [not done | not tested] Add a maintenance pass that can recompute memory coverage for an entire session and clean up orphaned entries.
- [not done | not tested] Surface stale/orphaned state in the memory UI instead of silently keeping broken data.

4.3. Retrieval and prompt injection integration:
- [done | not tested] Reuse vector indexing/search for memory entries via a separate `sourceType` such as `memory_entry`.
- [done | not tested] Support the same activation styles as lorebooks where useful: vectors, keys, and Glaze keys.
: runtime retrieval now supports key/glaze-key matching plus vector-backed memory entry search; deeper worker-level unification can remain follow-up cleanup.
- [done | not tested] Keep normal lorebook activation limits separate from memory activation limits.
- [done | not tested] Inject retrieved memories into the summary block path or an adjacent dedicated memory-summary block, not into the normal lorebook block.
- [done | not tested] Expose separate memory context accounting in generation metadata so the UI can show memory independently from lorebooks.
- [done | not tested] Memory retrieval already behaves like a lightweight lorebook-style top-k selection pass: relevant entries are searched, ranked, capped by session settings, and injected into the prompt.
- [done | not tested] Session settings already include a `maxInjectedEntries`-style memory cap (`количество мемори в памяти`) that controls how many retrieved memory entries can be added to the prompt.
- [done | not tested] Expose an explicit memory injection target setting in UI so the user can choose whether memory entries are injected into the dedicated summary block path or through the `{{summary}}` macro location.

4.4. UI and tokenizer visualization:
- [done | not tested] Add per-message markers showing whether a message is already covered by a memory segment / memory entry.
- [done | not tested] Add a way to inspect which memory entry covers which message range directly from the chat UI.
- [done | not tested] Add a dedicated memory books window/sheet rather than burying the feature entirely inside the lorebook sheet.
- [done | not tested] In the tokenizer/context breakdown, display memory usage as summary-like context rather than lorebook usage.
- [done | not tested] In message trigger UI, show memory-triggered entries distinctly from regular lorebook hits.

Current implementation status notes:
- [done | not tested] Messages now store compact `contextRefs` and `memoryCoverage` metadata.
- [done | not tested] Manual memory creation/removal from selected messages is available.
- [done | not tested] A first visible `Memory Books` entry point exists in the magic drawer.
- [done | not tested] `Memory Generation` currently supports provider source selection (`current` vs `custom`) and reuses the main API settings for `current` mode.
- [done | not tested] `Current provider` mode now supports an optional model override without duplicating endpoint/key fields from the main API settings.
- [done | not tested] `Memory Generation` now has its own rules/prompt preset selection, custom prompts, and temperature override, so memory generation can bypass the main preset configuration.
- [done | not tested] Prompt rules can now be previewed before selection, and custom prompts can be viewed/edited directly from the manager.
- [done | not tested] Closing prompt preview now returns to the originating memory sheet flow instead of dropping the user out of the settings/manager stack.
- [done | not tested] Draft generation now includes a first continuity layer from nearby approved memories instead of sending the segment alone.
- [done | not tested] Draft generation now also includes compact historical lore-trigger candidates and a summary excerpt for higher-quality extraction context.
- [done | not tested] Normal generation now injects selected memory-book entries as a separate memory context block and records triggered memories on the source message.
- [done | not tested] Dialog export now includes a Glaze full-fidelity chat format that preserves memory books, message refs, and memory coverage metadata.
- [done | not tested] ST chat import/export now preserves Glaze message IDs, context refs, memory coverage, and triggered memories in `extra` when available.
- [done | not tested] Memory entries and drafts now persist retrieval-facing fields (`keys`, `glazeKeys`, `vectorSearch`) and surface them in Memory Books preview UI.
- [done | not tested] Approved memory entries can now be edited after approval, including title/content/keys/Glaze keys updates, per-entry `vectorSearch` toggle changes, and manual `Reindex` actions from the Memory Books UI.
- [done | not tested] Memory Books now expose a session-level vector-search toggle and a selectable key match mode; keyword retrieval uses only the entry `Keys` field while preview cards keep inline `Edit` / `Reindex` / `Delete` actions.
- [done | not tested] Memory Books now expose a user-facing session-level retrieved-entry cap (`maxInjectedEntries`) as the "количество мемори в памяти" control.
- [done | not tested] Memory generation prompts now ask for both memory text and optional retrieval keys in a simple text format (`Memory:` / `Keys:`), avoiding JSON-only contracts.
- [done | not tested] Draft parsing now supports vector-first usage: if the model leaves `Keys:` empty, fallback keys are generated automatically while vector retrieval can still dominate when configured.
- [not done | not tested] Replace the temporary bottom-sheet implementation with a dedicated polished memory sheet component before considering the UI complete.
- [done | not tested] Add an explicit session setting for "раз в сколько сообщений создается мемори" so automation/bootstrap can use a user-configurable interval instead of a hardcoded threshold.
- [done | not tested] Add an explicit session setting for memory injection target selection: `{{summary}}` macro slot vs dedicated chat summary block injection.
- [done | not tested] Lorebook insertion now has a global default injection position and per-entry `Match Global` / `{{lorebooks}}` targets, so the `{{lorebooks}}` macro is legal at the lorebook-entry level instead of acting as a preset-wide override.
- [done | not tested] Lorebook ST round-trip now preserves Glaze-specific injection targets via `glazeMetadata`, so `Match Global` / `{{lorebooks}}` are not collapsed during export/import back into Glaze.

4.5. Import/export/bootstrap and cloud-sync-safe serialization:
- [done | not tested] On chat import, add an initial segmentation/bootstrap flow that can create first-pass memory drafts automatically from imported message history when the imported session has no existing memory-book state yet.
- [done | not tested] Ensure exported chat or backup data includes memory book state in a deterministic form that can be rehydrated without manual repair.
- [done | not tested] Keep SillyTavern-compatible chat export separate from full-fidelity Glaze-to-Glaze export. ST export may stay lossy, but Glaze-to-Glaze export/import must preserve memory books, message coverage markers, context refs, and related session metadata.
- [done | not tested] Add a dedicated Glaze-to-Glaze chat/session format or extension path so memory-book state can round-trip without relying on ST JSONL fields that do not support Glaze metadata.
- [not done | not tested] Keep embeddings export rules explicit: vectors may stay rebuildable/derived, but the core memory entries and message ownership metadata must persist.
- [done | not tested] Design the stored format so cloud sync can merge or replace memory books predictably using stable IDs and updated timestamps, instead of treating them as opaque blobs.
- [not done | not tested] Reuse the cloud-sync conflict model from PR #20 so memory books can participate in manual conflict resolution rather than bypassing it.
- [not done | not tested] Extend cloud sync to include memory-book records and per-message memory metadata, so sync does not silently drop memory coverage or leave orphaned memory state across devices.

4.6. Automation rules and quality tuning:
- [not done | not tested] Define when automatic memory creation runs: for example after N new messages, after summary update, or on explicit background maintenance.
- [done | not tested] Make the automatic creation interval user-configurable in UI as "раз в сколько сообщений создается мемори" instead of hardcoding the trigger threshold.
- [done | not tested] Add a user-facing toggle for delayed automation (`работать с отставанием`) so automatic memory creation can intentionally wait for an extra user+assistant exchange before materializing a memory entry.
- [done | not tested] Define delayed-trigger semantics for `Create memory every N messages`: when the threshold is reached on an assistant reply, wait until the user replies and receives one more assistant reply; when the threshold is reached on a user message, wait until that user message gets an assistant reply and then wait for one more full user+assistant exchange before creating the memory entry.
- [done | not tested] Keep delayed automation as the recommended default so users can still edit their last user turn or regenerate the latest assistant reply before a memory entry becomes fixed.
- [done | not tested] A first session-level delayed automation engine now tracks pending auto-memory triggers and evaluates them after stable assistant reply completion in the normal generation flow.
- [done | tested] Allow the system to create memory entries via Scan Chat + Generate Drafts when enough chat history exists. Auto-creation on import disabled to prevent unwanted drafts.
- [done | not tested] Define a first segmentation policy for auto/bootstrap flows: start from the user-configured `N`-message interval, but prefer ending segments on a nearby assistant reply so generated memory windows align better with completed exchanges.
- [done | not tested] Add a first deduplication/conflict layer so exact-duplicate and high-overlap memory segments are blocked during draft generation and draft approval.
- [done | not tested] Add a first session-wide Memory Books maintenance pass that can reconcile coverage, clear orphaned pending drafts, remove fully orphaned approved entries, and optionally reindex approved memory entries.
- [done | not tested] Surface lifecycle state in the Memory Books manager with visible status badges and summary counters for active entries, drafts, needs-rebuild entries, and stale message coverage.
- [not done | not tested] Add recency/importance controls only after the core lifecycle model is stable.
- [done | not tested] Add a proper first-pass memory-generation rules manager with built-in prompt presets, user-defined prompts, preview support, and prompt selection independent from the main chat preset.
- [done | not tested] Add memory-generation temperature override independent from the main chat preset.
- [done | not tested] Allow `current provider` memory generation to override only the model while still reusing the main endpoint/key.
- [done | not tested] Ensure memory generation can preview the selected rule text before running drafts.
- [done | not tested] Ensure prompt preview close returns to the relevant memory settings/manager sheet.

Memory extraction context algorithm (fixed direction):
- [not done | not tested] Do not reconstruct extraction context from the current live lorebook inject alone. It may differ from the lore context that existed when the target messages were generated.
- [not done | not tested] Do not send the full set of triggered lore entries from all messages in the segment to the model. Message-level trigger history is an audit/debug source, not direct prompt payload.
- [not done | not tested] For each message, store only compact trigger references needed for UI and reconstruction candidates:
  - stable entry ID
  - source type (`lorebook` / `memory`)
  - optional compact label/title
- [not done | not tested] For a target segment, build extraction context in two stages.

Stage A. Candidate collection:
- [not done | not tested] Collect the target message segment.
- [not done | not tested] Collect the union of lore entry IDs that were actually triggered on messages inside the segment.
- [done | not tested] Collect the nearest approved memory entries adjacent to the segment.
- [done | not tested] Run lightweight retrieval on the segment text itself to get current top lore candidates.
- [done | not tested] Optionally collect a compact summary excerpt and minimal setting context.

Stage B. Candidate compression:
- [not done | not tested] Rank lore candidates by a weighted score combining:
  - trigger frequency within the segment
  - recency inside the segment (later messages weigh more)
  - direct entity/key overlap with the segment text
  - current retrieval score from vector/keyword lookup
- [not done | not tested] Deduplicate by entry ID before scoring.
- [not done | not tested] Keep only a hard-capped top-k lore set for the model.
- [not done | not tested] Keep only a hard-capped top-k memory continuity set for the model.
- [not done | not tested] Drop low-value context aggressively instead of letting the prompt expand without bound.

Prompt payload limits (initial target):
- [not done | not tested] Message segment: one target segment only.
- [done | not tested] Memory continuity context: 1-3 approved memory entries max.
- [not done | not tested] Lore context: 3-5 lore entries max.
- [not done | not tested] Summary context: one compact excerpt only when needed.
- [not done | not tested] Setting/card context: compact fallback only, not full card by default.

Initial ranking formula direction:
- [not done | not tested] Historical trigger score is primary when reconstructing older segments.
- [not done | not tested] Current retrieval score is secondary and used as a tie-breaker / recovery signal, not the sole source of truth.
- [not done | not tested] Memory continuity relevance outranks generic recency.
- [not done | not tested] Entries that match both historical triggers and current retrieval should be preferred.

Implementation start order (to avoid refactor later):
- [done | not tested] Step 1. Add stable message IDs and compact per-message trigger references.
- [done | not tested] Step 2. Add dedicated memory book container + entry schema with message ownership metadata.
- [done | not tested] Step 3. Add lifecycle helpers for delete/branch/import rebuild detection.
- [done | not tested] Step 4. Add extraction-context builder with top-k compression.
: implemented as a compact heuristic layer for memory continuity + lore-trigger candidates + summary excerpt; vector-backed memory retrieval is still future work.
- [done | tested] Step 5. Add draft/approval workflow for one or multiple sequential memory generation jobs (batch generation with Scan Chat + Generate Drafts).
- [done | not tested] Step 6. Add summary-path injection + tokenizer visualization.
- [done | not tested] Step 7. Add backup/sync-safe persistence integration.

Manual verification that must stay visible in the roadmap:
- [not done | not tested] Verify that deleting covered messages marks the related memory entries stale or removes them correctly.
- [not done | not tested] Verify that branching from the middle of a chat does not carry over active memories for messages that no longer exist in the child branch.
- [not done | not tested] Verify that partially preserved memory entries after branch are downgraded to `needs_rebuild` instead of staying active.
- [not done | not tested] Verify that imported chats can bootstrap first memories without requiring a manually created seed entry.
- [not done | not tested] Verify that `Current provider` generation uses the override model while still keeping the main endpoint/key path unchanged.
- [not done | not tested] Verify that closing prompt preview returns to `Memory Generation` or the prompt manager instead of closing the whole flow.
- [not done | not tested] Verify that memory injections count separately from lorebook injections during generation.
- [not done | not tested] Verify that tokenizer visualization shows memory usage with summary-style accounting.
- [not done | not tested] Verify that editing an approved memory entry correctly updates persisted content/keys and does not break message coverage metadata.
- [not done | not tested] Verify that disabling `vectorSearch` deletes the memory-entry embedding, and re-enabling or manual `Reindex` rebuilds it correctly.
- [not done | not tested] Verify that the Memory Books key match mode (`plain` / `glaze` / `both`) changes retrieval as expected while using only the `Keys` field.
- [not done | not tested] Verify that `Create memory every N messages` respects delayed mode correctly on both threshold cases: assistant-triggered thresholds wait one extra user+assistant exchange, and user-triggered thresholds wait for the current assistant reply plus one extra user+assistant exchange.
- [not done | not tested] Verify that disabling `работать с отставанием` switches automation back to immediate threshold behavior without breaking edit/regenerate workflows.
- [not done | not tested] Verify that lorebook entries set to `Match Global`, `@worldInfoBefore`, `@worldInfoAfter`, and `{{lorebooks}}` inject at the expected locations without preset-level override regressions.
- [not done | not tested] Current known limitation: lorebook/memory entries now aggregate into single injected blocks per target, but when the target is a macro inside another preset block, the injected content still lands as a separate block adjacent to that area rather than truly inside the host block. Revisit later.
- [not done | not tested] Verify that Glaze lorebook export/import preserves `Match Global` and `{{lorebooks}}` through the new `glazeMetadata` round-trip path.
- [not done | not tested] Verify that backup export/import preserves memory books and rebuilds any derived vectors safely.
- [not done | not tested] Verify that future cloud-sync serialization can round-trip memory books without duplication or orphaned entries.
- [not done | not tested] Verify that Glaze-to-Glaze export/import preserves memory books, per-message markers, and memory generation settings without loss.

Important constraint:
- [done | not tested] Do not implement memory books as a quick lorebook hack that hides lifecycle state in entry text or comments. That would reintroduce later refactor pressure.
- [done | not tested] Summary and vector foundations are stable enough to build on, but memory books should be added as a thin new layer over those primitives, not by forking them.

Expected result:
- [not done | not tested] A durable memory layer with deterministic ownership over chat history, reusable retrieval infrastructure, separate injection accounting, and import/export/sync-safe persistence.
- [done | not tested] A durable memory layer foundation with deterministic ownership over chat history, separate injection accounting, tokenizer visibility, and Glaze chat round-trip persistence is now in place.

## Post-Merge Conflict Audit (COMPLETED — 2026-04-16)

Upstream принял PR #20 (cloud sync) → после этого PR #24 (vectorization-v2) показал 17 конфликтов. Upstream зарезолвил их сам. Наш PR #27 (memory books + lorebook fixes) тоже был принят.

Current active work branch: `fast-fixes` (branched from `upstream/dev` after audit)

### Merge topology
```
efbb4e5  ← common ancestor (tokenizer features)
  ├── 9cff2fc  ← PR #20 merge (cloud sync into dev)
  │     └── 15920df  ← merge dev into feat/vectorization-v2 (17 conflicts resolved here)
  │           └── 906ee75  ← PR #24 merge (vectorization-v2 into dev)
  │                 └── 886b4b1  ← merge dev into feat/memorybook
  │                       └── 8ec4ff0  ← PR #27 merge (memorybook into dev)
  │                             └── 8c58ff4, 867ff8d, 45cde4d  ← upstream fixes
  └── c43a820  ← feat/vectorization-v2 branch tip
```

### Conflicting files (intersection of changes on both sides)
7 files had overlapping changes between cloud sync and vectorization-v2:
1. `.gitignore` — **A (structural)**: both added entries
2. `CLAUDE.md` — **A (structural)**: both updated instructions
3. `src/components/sheets/LorebookSheet.vue` — **B+C (behavioral + UI)**: vector UI + sync event listeners
4. `src/core/states/lorebookState.js` — **B+D (behavioral + data model)**: vector indexing + sync force init + position handling
5. `src/locales/en/index.json` — **A (structural)**: both added i18n keys
6. `src/locales/ru/index.json` — **A (structural)**: both added i18n keys
7. `src/utils/db.js` — **D (data model)**: embeddings store + sync helpers + updatedAt timestamps

Additionally, `src/views/ChatView.vue` was changed on cloud sync side only (auto-sync + tokenizer property removal), but cloud sync PR itself had removed tokenizer computed properties. Our PR #27 restored them.

### Audit results — ALL CLEAR

| File | Status | Details |
|------|--------|---------|
| `generationService.js` | **IDENTICAL** upstream/dev ↔ our branch | All 6 memory/lorebook injection features present |
| `generationWorker.js` | **IDENTICAL** | All 6 lorebook fixes present |
| `lorebookState.js` | **upstream/dev is BETTER** | All 14 features present: vector + cloud sync + memory book |
| `LorebookSheet.vue` | **upstream/dev is BETTER** | All 8 features present: vector UI + sync listeners + matchGlobal |
| `ChatMessage.vue` | **IDENTICAL** | Memory coverage badge present |
| `ChatView.vue` | **upstream/dev is COMPLETE** | Tokenizer props restored + auto-sync + all memory book code |
| `db.js` | **upstream/dev is BETTER** | Cloud sync helpers added alongside vector storage |
| Locale files | **IDENTICAL** | No diff |

### Key findings
1. **Tokenizer computed properties**: cloud sync PR (`9cff2fc`) accidentally removed them from ChatView.vue. Our PR #27 (`8ec4ff0`) restored them because our branch still had them. Final state in upstream/dev is correct.
2. **LorebookSheet sync integration**: cloud sync added `sync-data-refreshed` event listener and `onUnmounted` cleanup. Our branch had a simpler `updateVectorReindexNotice`. Upstream/dev correctly merged both: the sync-aware version that checks ALL lorebooks + the event listener.
3. **LorebookState force init**: cloud sync added `force` parameter and state reset. Upstream/dev correctly merged this alongside vectorization functions.
4. **Minor edge case**: `lorebooksMacro` position slot in generationWorker.js is initialized but `injectLore('lorebooksMacro')` is never called directly. Entries with `position: 'lorebooksMacro'` only surface via `{{lorebooks}}` macro in preset blocks. Not a regression, pre-existing.

### Decision
- **No corrective branch needed.** All conflicts resolved correctly.
- **Local `dev` synced** with `upstream/dev` at `45cde4d`.

### Branch cleanup
Deleted local branches:
- `archive/feat/summary`
- `archive/feat/tokenizer`
- `feat/cloud-sync`
- `feat/memorybook`
- `feat/vectorization`
- `feat/vectorization-v2`
- `test-cloud-sync`

Deleted remote branches on origin:
- `origin/archive/feat/summary`
- `origin/archive/feat/tokenizer`
- `origin/feat/cloud-sync`
- `origin/feat/memorybook`
- `origin/feat/vectorization-v2`
- `origin/fix/lorebook-macro-resolution`
- `origin/test-cloud-sync`

Remaining branches: `dev`, `main` (local); `upstream/dev`, `upstream/main`, `upstream/feature/desktop-layout` (remote).

## Suggested Execution Order

The intended order of work is:

1. Finish the summary block and summary request path.
2. Build reusable vector infrastructure.
3. Attach vector retrieval to lorebook entries.
4. Build memory books using summary + vectors as the base.

This order is deliberate:
- summary creates durable structured context;
- vectorization creates reusable retrieval infrastructure;
- vector lorebooks validate the retrieval layer on an existing system;
- memory books are then implemented on top of proven components.

## Next Up

The immediate next milestone is:
- [done | not tested] Lorebook injection/export fixes are folded into `feat/memorybook`; continue shipping them together with Memory Books instead of splitting a separate PR/branch.
- [done | not tested] Vectors are in maintenance mode: WORKS, do not touch without a concrete bug report.
- [not done | not tested] Improve vector ranking only if a real user-facing retrieval miss forces it.
- [not done | not tested] Summary simple mode prompts — proper defaults and editability.
- [done | not tested] Memory books data model foundation exists; continue with generation UX, inspection UX, lifecycle cleanup, and automation instead of reopening the schema.
- [not done | not tested] Finish the remaining Memory Books gaps in this branch, then ship one combined PR with both Memory Books and lorebook fixes.

## Resume Notes

When returning to this roadmap after unrelated work:
- do not reopen rejected tokenizer / reserve ideas unless there is a new explicit decision;
- vectorization infrastructure is done on `feat/vectorization-v2` (clean branch from `upstream/dev`);
- entries with `vectorSearch: true` are excluded from keyword matching (both `lorebookState.js` and `generationWorker.js`);
- vector QA coverage now includes automated end-to-end verification of the vector-only retrieval path;
- feature work now continues from `feat/memorybook`, created on top of `feat/vectorization-v2`;
- memory books should converge vectorization and future cloud-sync-safe data modeling instead of inventing a third storage path;
- cloud sync implementation lives in `feat/cloud-sync` / PR #20 and already includes encryption, delta sync, queueing, conflict resolution, and `updatedAt` support that memory books must reuse;
- keep future retrieval work aligned with reusable vector infrastructure, not feature-specific hacks.

## Fast Fixes — Mobile Testing Batch (ORDERED: easy → hard)

Active branch: `fast-fixes`

### ✅ DONE (Batch 1)
1. **Fix: `memoryDraftTimer` is not defined (CRITICAL CRASH)**
   - Status: `done | tested (code path)`
   - Fix: Moved functions from `<script>` to `<script setup>` scope
   - Testing: Message with `isTyping` should not crash Vue

2. **Fix: vector search toggle should disable keyword search UI**
   - Status: `done | tested (code path)`
   - Fix: Hide keys/secondary keys/logic selectors when `vectorSearch=true`
   - Testing: Enable vector search on entry → UI shows only index button and vector badges

3. **Fix: embedding API key inheritance bug**
   - Status: `done | tested (code path)`
   - Fix: Reset `endpoint/key/model` fields when `useSame=true` in `loadEmbeddingSettings()`
   - Testing: Switch from "Use LLM API" → fields should clear, not show LLM key

4. **Fix: tokenizer doesn't count vector lorebook tokens in breakdown**
   - Status: `done | tested (code path)`
   - Fix: Add `vectorLore` to context breakdown, aggregate tokens from `newVectorEntries`
   - Testing: Generate with vector lorebook entries → breakdown shows purple "Vector Lorebook" segment

5. **Add NovelAI model to Naistera image generation**
   - Status: `done | tested (code path)`
   - Fix: Add 'novelai' to `normalizeNaisteraModel()`, UI selector, disable references for it
   - Testing: Select NovelAI → no reference images sent (per API behavior)

6. **Fix: LorebookSheet.vue build error (Invalid end tag)**
   - Status: `done | tested`
   - Fix: Removed extra `</div>` at line 1001, changed `<template v-if>` to `<div v-if>` for reliability
   - Testing: `npm run build` passes without Vue template errors

7. **Fix: Memory books Key Match Mode visible during vector search**
   - Status: `done | not tested`
   - Fix: Wrap Key Match Mode selector in `${!vectorEnabled ? '...' : ''}` in `openMemoryBooksSheet()`
   - Testing: Enable vector search in Memory Books → Key Match Mode should be hidden

### ✅ DONE (Batch 3 — merged into PR #30)

8. **Fix: lorebook injections shown for user but not assistant messages**
    - Status: `done | tested`
    - Complexity: easy
    - Issue: Injection badges only appear on user messages, missing on assistant replies
    - Root cause: `onPromptReady` in `ChatView.vue` redirected `triggeredLorebooks`/`triggeredMemories`/`contextRefs` to `msgIndex - 1` (user message) only
    - Fix: Assign refs to both assistant message at `msgIndex` AND preceding user message at `msgIndex - 1`
    - PR: #30

9. **Add i18n keys for new features**
    - Status: `done | tested`
    - Complexity: easy
    - Added 12 missing keys + 2 asymmetric fixes to both `en/index.json` and `ru/index.json`
    - New keys: `api_create_preset_desc`, `api_presets`, `avatar`, `desc_show_reasoning`, `error_generation`, `imggen_notification_body`, `imggen_notification_title`, `label_custom_model`, `label_model`, `label_show_reasoning`, `no_models_found`, `no_prompt`
    - Symmetry fixes: `top_p` → en, `regex_slash_commands` → ru
    - PR: #30

10. **Fix: streaming quote formatting breaks mid-quote**
    - Status: `done | tested`
    - Complexity: medium
    - Issue: Blue quote styling doesn't apply to streaming text when opening quote arrives without closing quote
    - Root cause: `textFormatter.js` regex matches complete quote pairs only
    - Fix: Added 6 regex patterns after the paired-quote matcher to handle unclosed `"`, `"`, `«` at end of text during streaming
    - PR: #30

11. **Fix: messages stuck in "generating" state**
    - Status: `done | tested`
    - Complexity: medium-hard
    - Issue: Message stays with typing indicator after generation should complete (both streaming and non-streaming)
    - Root causes found:
      - Non-streaming mode: Invalid API responses (missing `data.choices[0]`) caused crashes without calling `onComplete`
      - `onComplete`/`onError` handlers could fail with exceptions, leaving `isTyping=true`
      - `onUnmounted` cleared timers but did NOT abort controllers or delete `generatingStates`, allowing background responses to update unmounted components
      - No defensive checks in non-streaming JSON parsing
    - Fixes applied:
      - Added defensive validation before accessing `data.choices[0].message` in both Native and Web non-streaming paths (`llmApi.js:95-99, 276-280`)
      - Wrapped `onComplete` handler in try/catch with `ensureCleanup()` fallback to guarantee `isTyping` cleared even on handler exceptions (`ChatView.vue:3734-3951`)
      - Wrapped `onError` handler in try/catch with `ensureTypingCleared()` fallback (`ChatView.vue:3542-3638`)
      - Added controller abort, timer cleanup, and localStorage flag removal in `onUnmounted` for ALL `generatingStates` (`ChatView.vue:5122-5159`)
    - Files modified:
      - `src/core/services/llmApi.js` (defensive checks for invalid API responses)
      - `src/views/ChatView.vue` (robust error handling + unmount cleanup)
    - PR: #30

12. **Multi-vector retrieval with MaxSim and dual-channel lorebook search**
    - Status: `done | tested`
    - Complexity: hard
    - Implementation:
      - **Multi-vector storage**: Entries chunked (512 tokens default), each chunk embedded separately
      - **MaxSim algorithm**: Query-chunk × candidate-chunk matrix, take maximum similarity score
      - **Dual-channel retrieval**: Vector entries now participate in BOTH keyword scan AND vector search
      - **Keyword priority**: Keyword matches always ranked above vector matches during injection
      - **OOC stripping**: Strip `[OOC: ...]` from query before embedding
      - **Force reindex**: Legacy single-vector embeddings auto-detected and reindexed
      - **DB migration v8**: Convert old `vector` field to new `vectors[]` format
      - **Debug logging**: Per-chunk similarity breakdown for diagnostics
    - Architecture:
      - `vectorMath.js`: `findTopKMulti()` — cross-product MaxSim implementation
      - `lorebookState.js`: `vectorSearchLorebooks()` — dual-channel merge, keyword priority
      - `embeddingService.js`: `getEmbeddings()` returns `[[{text, vector}, ...], ...]`
      - `db.js`: Migration v8, backward-compatible legacy format support
    - Testing:
      - Indexed 102 entries (Vareti lorebook) + Project Tokyo lorebooks with bge-m3
      - Verified keyword matches appear above vector matches
      - Verified Asei entry retrieved via keyword dual-channel
      - Verified semantic retrieval for character descriptions
      - Verified OOC-stripped queries produce cleaner embeddings
      - Verified force-reindex rebuilds legacy embeddings
    - PR: #30
    - Branch: `feat/multi-vector-retrieval` (linear chain from `feat/fast-fixes-batch3`)

### ⏳ PENDING

13. **Sync infrastructure fixes — encryption optional + redirect URI fix**
    - Status: `done | not tested`
    - Complexity: medium-hard
    - Branch: `feat/sync-infrastructure-fixes` (linear chain from `feat/multi-vector-retrieval`)
    - Changes:
      - **Encryption is now optional**: Sync works without encryption key. Data stored as plain `.json` instead of `.enc`. If key exists — encrypts as before.
      - **Redirect URI fix**: Both Dropbox and Google Drive adapters now use configurable redirect URIs via env vars (`VITE_DROPBOX_REDIRECT_NATIVE`, `VITE_DROPBOX_REDIRECT_WEB`, `VITE_GDRIVE_REDIRECT_NATIVE`, `VITE_GDRIVE_REDIRECT_WEB`). Web defaults to `window.location.origin` instead of hardcoded `localhost:5173`.
      - **Electron OAuth**: Added Electron-specific OAuth flow for Dropbox (loopback server pattern, same as gdrive already had).
      - **Error 400 root cause**: `redirect_uri` must exactly match what's registered in the OAuth console (Dropbox App Console / Google Cloud Console). Hardcoded `localhost:5173` only works in dev. Fixed: now uses `window.location.origin` as default.
      - **Backward compatibility**: `readCloudEntityByEntry` tries both `.enc` and `.json` extensions. `decryptEntity` auto-detects encrypted vs plain payload.
      - **SyncSheet UI**: Push/Pull/Auto-sync available without encryption. Encryption shown as optional section. `doWipe` no longer forces new key generation.
    - Files modified:
      - `src/core/services/syncEngine.js` — `_encryptionEnabled` state, `ext()`, optional encrypt/decrypt, dual-extension fallback
      - `src/core/services/syncService.js` — removed mandatory `hasSyncKey` checks, uses `detectEncryptionState()`
      - `src/core/services/adapters/dropboxAdapter.js` — configurable redirect URIs, Electron OAuth, `isElectron()` helper
      - `src/core/services/adapters/gdriveAdapter.js` — configurable redirect URIs, `window.location.origin` default
      - `src/components/sheets/SyncSheet.vue` — encryption optional in UI, new states (`ready`, `has_cloud_data`)
    - Manual verification needed:
      - [ ] Verify Dropbox connect/disconnect works on native (Android/iOS) with correct `com.hydall.glaze://oauth/dropbox`
      - [ ] Verify Google Drive connect/disconnect works on native
      - [ ] Verify Push/Pull works WITHOUT encryption key (plain JSON)
      - [ ] Verify Push/Pull works WITH encryption key (encrypted `.enc`)
      - [ ] Verify fallback: pull from cloud with old `.enc` files when encryption is disabled
      - [ ] Verify error 400 is fixed after setting correct redirect URI in OAuth console
      - [ ] Verify Electron OAuth flow works on Windows/Linux desktop builds

14. **Infrastructure: Sync service migration to upstream project**
    - Status: `not done`
    - Complexity: hard
    - Goal: Move cloud sync infrastructure (encryption, delta, queueing) to developer's repo
    - Deliverables:
      - Sync endpoint configuration guide (PC/Linux/iOS/Android)
      - Error 400/402 troubleshooting runbook
      - OAuth/app token setup instructions per platform

14. **Fix: Tokenizer lorebook display and reserve visualization**
    - Status: `done | tested`
    - Complexity: medium
    - Branch: `bug-fixes`
    - Issue: Lorebook tokens not counted or displayed incorrectly in tokenizer breakdown
    - Root causes:
      - Vector lorebooks marked as `source: 'lorebook'` instead of `source: 'vectorLore'`
      - Worker didn't recognize `vectorLore` as valid source (not in `sourceKeys` array)
      - `calculateContext()` didn't run vector search, so tokenizer showed 0 for vector lorebooks
      - Lorebooks displayed in main bar instead of inside reserve zone
    - Fixes applied:
      - Changed vector lorebook source from `'lorebook'` to `'vectorLore'` in `generationService.js`
      - Added `'vectorLore'` to `sourceKeys` array in `generationWorker.js`
      - Added `vectorLore` field to breakdown structure in worker
      - Updated `fixedBase` calculation to include `vectorLore`
      - Added vector search to `calculateContext()` for accurate tokenizer display
      - Modified UI to show lorebooks **inside** reserve zone, not in main bar
      - Created nested reserve visualization: reserve contains keyword + vector lorebooks + unused space
      - Updated labels: "Keyword Lorebook", "Vector Lorebook", "Lorebook Total"
      - Added `.chat-context-reserve-container` CSS for nested segment display
    - Files modified:
      - `src/workers/generationWorker.js` — add vectorLore to sourceKeys, breakdown, fixedBase calculation
      - `src/core/services/generationService.js` — change source to vectorLore, add vector search to calculateContext
      - `src/views/ChatView.vue` — nested reserve visualization, updated labels, CSS changes
    - Additional fixes (second commit):
      - Fixed `remaining` calculation: changed from `safeContext - totalUsed` to `contextSize - totalUsed`
      - Excluded lorebook/vectorLore from `fixedBase` (they're inside reserve, not in base)
      - Now `fixedBase = character + preset + summary + authorsNote` (without lorebooks)
      - Result: `remaining` now shows correct value relative to full context (80000)
    - Testing:
      - Tokenizer now correctly shows keyword lorebook (0 tokens) + vector lorebook (~8657 tokens)
      - Visual bar: lorebooks display inside green reserve zone on the right
      - Reserve shows: [Vector Lorebook (purple)] [Unused Reserve (green)]
      - Main bar shows: Character, Preset, Summary, Memory, History (no lorebooks)
      - Remaining calculation: 80000 - totalUsed (instead of 72000 - totalUsed)
    - Commits: `f33a9d3`, `915dbf3`
    - PR: pending

15. **Image Generation Improvements — Info Blocks & Dynamic Character State**
    - Status: `not started`
    - Complexity: hard
    - Branch: `img-gen-improve` (from `dev`)
    - Goal: Implement comprehensive image generation system with dynamic character state tracking, dual API endpoints, and quick generation workflow
    
    **Phase 1: Info Blocks — Dynamic State Tracking**
    - Problem: User persona describes "favorite outfit: tweed", but user wrote "wearing hoodie today" 20 messages ago. Current system uses static persona, not dynamic session state.
    - Proposed Solution: **Info Blocks** — dedicated structured data blocks that track current session state
    - Info Block Structure:
      - `current_outfit_user`: What {{user}} is wearing right now
      - `current_outfit_char`: What {{char}} is wearing
      - `current_location`: Current scene location  
      - `time_of_day`: Morning/afternoon/evening/night
      - `lighting`: Scene lighting conditions
      - `weather`: If outdoors
      - `current_pose`: Action/position of characters
    - Implementation:
      - Create new Memory Book type: `info_blocks` (high priority, always included)
      - Auto-extract from chat: Pattern matching for outfit/location/time changes (keywords: "wearing", "dressed in", "changed into", "now in")
      - Manual edit: UI for quick state updates (floating button or context menu)
      - Image gen integration: Use info_blocks as primary source, persona as fallback
    - Alternative Approaches Considered:
      - Parsing last N messages: Too slow, unreliable with complex descriptions
      - Static Memory Books: Requires manual updates, not automatic
    
    **Phase 2: Dual API Setup (SFW/NSFW)**
    - Support two separate image generation endpoints:
      - SFW endpoint: Standard generation (OpenAI/Gemini/Naistera)
      - NSFW endpoint: Uncensored generation (NovelAI/Naistera specialized)
    - Settings:
      - Two sets of credentials: `sfw_endpoint`, `sfw_key`, `nsfw_endpoint`, `nsfw_key`
      - Default toggle: Auto-detect content type or manual selection
      - Style presets per endpoint
    - Use case: Different models for different content types without switching settings manually
    
    **Phase 3: Quick Image Generation Button**
    - Location: Bottom-left button group in ChatInput (4th button or replace existing image-gen)
    - Workflow:
      1. Long-press or context menu: Choose SFW/NSFW/Settings
      2. Click: Quick menu with options:
         - "Generate scene" (uses current info_blocks + last 3 messages)
         - "Generate portrait - {{char}}" (character focus)
         - "Generate portrait - {{user}}" (user focus)
         - "Custom prompt..." (manual override)
      3. Auto-prompt building from:
         - Info blocks (primary)
         - Current macros: {{char}}, {{user}}, {{scenario}}, {{persona}}
         - Last 3-5 chat messages for context
      4. Direct generation without waiting for model response
      5. Insert as new message or inline in chat
    
    **Phase 4: Multi-Character Support**
    - Problem: Character cards can define multiple characters (main + NPCs)
    - Solution: Parse character definitions from card and lorebooks
    - Auto-detect speaking characters from recent messages
    - Generate composite prompts with all present characters
    - Per-character outfit tracking in info_blocks
    
    **Pre-Generation Preview (Optional Enhancement)**
    - Show detected state before generation:
      - Detected: "You in hoodie and jeans, {{char}} in dress, location: cafe, evening"
      - Editable fields for quick correction
      - Generate button
    - Benefits: User can fix misdetected state before wasting API call
    
    **Technical Notes:**
    - Prerequisite for reliable automated image generation
    - Without accurate state tracking, generated images mismatch actual scene
    - Info blocks solve the "static vs dynamic" state problem
    - Dual API enables content-appropriate generation without manual switching
    
    **Files to Modify (Future):**
    - `src/core/services/imageGenService.js` — dual API support, auto-prompt builder
    - `src/components/sheets/ImageGenSheet.vue` — dual endpoint settings UI
    - `src/components/chat/ChatInput.vue` — quick gen button
    - `src/core/services/infoBlockService.js` — new service for state tracking
    - `src/core/services/characterExtractor.js` — multi-char parsing
    - `src/components/sheets/InfoBlockEditor.vue` — manual state editor
    
    **Deferred for Later:**
    - Advanced pattern matching for outfit changes
    - Automatic pose detection from action verbs
    - Scene mood extraction from dialogue tone
    - Background/location detail enrichment from lorebooks

### Branch Strategy (updated)
- Current: `feat/refactor-tokenizer-memorybooks` (from `origin/dev` at 210efa4)
- Previous: Merged branches deleted (bug-fixes, feat/dual-lorebook-debug)
- Policy: **Linear chain workflow** — each feature branches from previous feature OR origin/dev for new chains
- Never create branches from dev that contain multiple unmerged features
- All PRs target `upstream/dev`, never `main`

## Refactoring Phase — Tokenizer, Memory Books, Vectors/Lorebooks (Active)

Branch: `feat/refactor-tokenizer-memorybooks`
Status: In progress
Goal: Clean up technical debt, fix UX issues, improve user-facing workflows

### Analysis Summary

Three deep-dive explorations completed on 2026-04-17:
1. **Tokenizer**: Currently working correctly, recently fixed. No critical issues found. Uses SheetView bottom sheet pattern. Architecture is clean.
2. **Memory Books**: Functionally complete but uses temporary bottom sheet UI. Many features marked `done | not tested`. Needs polished dedicated component.
3. **Vectors/Lorebooks**: Backend dual-channel (vector+keyword) works correctly, but UI presents it as mutually exclusive. Creates user confusion.

### Phase 1: Vector/Lorebook UX Fixes (CRITICAL — misleading UI)

Status: `done | ready for testing` (Commit: d215502)

**Problem**: Dual-channel retrieval is implemented and working in backend, but UI hides keyword fields when vector is enabled and shows "Vector search replaces keys" message. This is factually incorrect.

**Root Cause Analysis**:
- Backend (generationWorker.js:167): ALL entries participate in keyword scan regardless of `vectorSearch` flag
- Backend (generationService.js:230-242): Vector results are merged with keyword results, deduplicated, keyword matches prioritized
- Frontend (LorebookSheet.vue:922): Hides keyword UI when `vectorSearch: true`
- Frontend (LorebookSheet.vue:921): Shows misleading "replaces keys" message

**Tasks**:
1. [done | ready for testing] **Remove keyword UI hiding** (LorebookSheet.vue:922)
   - Change: Removed `&& !activeEntry.vectorSearch` condition from `v-if`
   - Show keyword fields at all times — they work regardless of vector flag
   
2. [done | ready for testing] **Fix misleading "replaces keys" message** (LorebookSheet.vue:921)
   - Old: "Vector search replaces keys"
   - New: "Vector search supplements keyword matching (dual-channel retrieval)"
   - Color changed to green (--text-success) to indicate positive feature
   
3. [done | ready for testing] **Add retrieval source visibility**
   - Added badges in triggered lorebooks UI: `[keyword]` (green), `[vector]` (purple)
   - Uses existing `_source` tags from generationService.js:237-238
   - CSS: .retrieval-badge, .keyword-badge, .vector-badge
   
4. [intentional design | not changed] **Decouple constant from vectorSearch**
   - Decision: Keep mutual exclusion (constant entries don't need vector retrieval)
   - Constant entries are always active, so vectorSearch is redundant
   
5. [deferred | future work] **Optional: Add hybrid scoring visibility**
   - Show `hybridBoost` and `descriptorBoost` values in debug/advanced UI
   
6. [done | ready for testing] **Cleanup: Remove debug code** (lorebookState.js:1080-1110)
   - Removed 31 lines of Asei-specific debug logging from production code
   
7. [deferred | future work] **Add keyword+vector statistics**
   - Show summary in tokenizer or lorebook manager: "X by keyword, Y by vector, Z hybrid"

**Files modified**:
- `src/components/sheets/LorebookSheet.vue` — keyword UI visibility, message text, normalize useKeywordSearch
- `src/core/states/lorebookState.js` — removed debug code
- `src/components/chat/ChatMessage.vue` — retrieval source badges, CSS
- `src/workers/generationWorker.js` — filter vector-only entries (useKeywordSearch=false)
- `src/locales/en/index.json` — new i18n keys
- `src/locales/ru/index.json` — new i18n keys

**Testing**: See TESTING_CHECKLIST.md section 1

### Phase 2: Memory Books UX Improvements

Status: `partially done | ready for testing` (Commits: b5857d0, 78be7ed)

**Problem**: Memory Books UX had multiple usability issues: timer not updating, no regenerate button, navigation confusing, prompts too weak.

**Completed Tasks**:
1. [done | ready for testing] **Add PENDING badge for messages awaiting auto-generation**
   - Messages in `automation.pendingTrigger.messageIds` show gold pulsing PENDING badge
   - Users can now see which messages will be processed next by automation
   - Computed: `pendingMemoryMessageIds` ref, updated on chat open and after automation runs
   
2. [done | ready for testing] **Fix draft generation timer updates**
   - Removed refresh-based timer (no more sheet close/reopen flickering)
   - Added watch on `memoryDraftState.elapsedMs` → updates DOM directly via getElementById
   - Timer updates smoothly every 100ms without interruption
   - Message changed: "The timer will update automatically while generation is in progress"
   
3. [done | ready for testing] **Add regenerate button to draft preview**
   - Draft preview now shows "Regenerate" button (not available for approved entries)
   - Calls `generateMemoryDraftForMessages` with same message range
   - Shows toast on success/failure
   - Returns to Memory Books sheet after regeneration
   
4. [done | ready for testing] **Fix navigation: Back vs Close buttons**
   - Draft preview: shows "Back" button → returns to Memory Books sheet
   - Approved entry preview: shows "Close" button → closes preview only
   - Proper navigation flow restored
   
5. [done | ready for testing] **Improve memory generation prompts** (based on SillyTavern-MemoryBooks)
   - Replaced 3 weak prompts with 4 detailed, structured prompts:
     - `detailed_beats` (recommended, new default): beat-by-beat with Timeline/Story Beats/Key Interactions/Notable Details/Outcome
     - `concise_narrative`: 3-5 sentence compact summary
     - `structured_markdown`: markdown structure with clear sections
     - `minimal_factual`: 1-2 sentence minimal summary
   - Keyword guidelines: 5-30 concrete scene-specific keywords (locations, objects, proper nouns, unique actions)
   - Explicitly exclude: abstract themes, emotions, character names, [OOC] conversation
   - Default preset changed: `strict_factual` → `detailed_beats`
   - Reference: https://github.com/aikohanasaki/SillyTavern-MemoryBooks

**Remaining Tasks**:
1. [not done | not tested] **Extract memory books UI into dedicated component**
   - Create `src/components/sheets/MemoryBooksSheet.vue`
   - Move logic from ChatView.vue:1684-2070 (openMemoryBooksSheet)
   - Move settings from ChatView.vue:1300-1551 (openMemoryGenerationSettings)
   - Move prompt manager from ChatView.vue:1553-1629 (openMemoryPromptManager)
   - Deferred: Technical debt, not blocking users
   
2. [not done | not tested] **Fix: Memory menu in chat doesn't persist settings state**
   - Settings from main Memory Books sheet should sync with in-chat memory UI
   - Both should use same session.memoryBooks[sessionId].settings source
   - Deferred: Need to investigate where in-chat memory menu is located
   
3. [not done | not tested] **Add comprehensive testing for memory lifecycle**
   - Test: Message deletion → memory reconciliation (ChatView.vue:2072-2096)
   - Test: Memory automation triggers (ChatView.vue:1022-1092)
   - Test: Vector search toggle for memories
   - Test: Draft generation and approval flow

**Files modified**:
- `src/views/ChatView.vue` — PENDING badge, timer watch, regenerate handler, navigation fix, improved prompts
- `src/components/chat/ChatMessage.vue` — PENDING badge prop, styling with pulse animation
- `src/utils/db.js` — default promptPreset changed to detailed_beats

**Testing**: See TESTING_CHECKLIST.md sections 3-6

### Phase 3: Tokenizer Performance & Loading

Status: `done | ready for testing` (Commit: b5857d0)

**Problem**: Tokenizer shows "Context breakdown is not ready yet" on first open and takes long time to open repeatedly.

**Completed Tasks**:
1. [done | ready for testing] **Fix "not ready yet" error on first open**
   - Added timeout-based wait in `openContextSheet()`: Promise.race with 5s timeout + 1s buffer
   - Improved error message: "Context calculation is taking longer than expected. Please check that your API settings are configured correctly"
   - No more confusing "not ready yet" on normal usage
   
2. [done | ready for testing] **Optimize tokenizer recalculation performance**
   - Added `debouncedUpdateContextCutoff()` helper with 300ms delay
   - Applied debounce to non-critical calls: delete messages, hide messages
   - Reduced redundant recalculations during rapid operations
   - Tokenizer now opens faster on repeated access

**Remaining Tasks (Deferred)**:
1. [not done | not tested] **Migrate tokenizer sheet display to dedicated component** (Optional)
   - Refactor ChatView.vue:2633-2745 (openContextSheet) to use SheetView.vue pattern
   - Note: This is LOW priority — current implementation works fine
   
2. [not done | not tested] **Add separate menus for different injection types**
   - Current: All lorebooks shown together in one view
   - Requested: Separate views for vector-only, keyword-injected, memory books
   
3. [not done | not tested] **Fix: All menus should return to previous screen on save/cancel**
   - Apply to: Tokenizer, Memory Books, Lorebook sheets
   - Use navigation stack pattern (already exists for prompt preview)

**Files modified**:
- `src/views/ChatView.vue` — timeout handling, debounce timer, debouncedUpdateContextCutoff()

**Testing**: See TESTING_CHECKLIST.md section 2

### Phase 4: Lorebook Optional Keyword Search for Vectorized Entries

Status: `done | ready for testing` (Commit: d215502)

**Problem**: When vector search is enabled for a lorebook entry, keyword search also runs (dual-channel), but user cannot optionally disable it.

**Solution**: Added `useKeywordSearch` flag with UI checkbox. Makes dual-channel optional instead of hardcoded.

**Tasks**:
1. [done | ready for testing] **Add `useKeywordSearch` flag to entry schema**
   - Default: `true` (preserves current dual-channel behavior for backward compatibility)
   - Only applies when `vectorSearch: true`
   - When `false`: entry excluded from keyword scan, vector-only retrieval
   - Normalized on `selectEntry()` for existing entries (defaults to true)
   
2. [done | ready for testing] **Update worker to respect flag**
   - generationWorker.js:167-169 — Filter entries with `vectorSearch && useKeywordSearch === false`
   - Comment updated: "DUAL-CHANNEL: All entries participate in keyword scan, unless vectorSearch is enabled AND useKeywordSearch is explicitly disabled"
   - Keeps current behavior for entries with `vectorSearch && useKeywordSearch`
   
3. [done | ready for testing] **Add UI checkbox in LorebookSheet**
   - Shows only when `vectorSearch: true` and `!constant`
   - Label: "Also use keyword matching"
   - Description: "Enable dual-channel retrieval: both vector similarity and keyword matching (recommended)"
   - Default: checked
   - i18n: `label_use_keyword_search`, `desc_use_keyword_search`

**Files modified**:
- `src/components/sheets/LorebookSheet.vue` — UI checkbox, normalize useKeywordSearch on selectEntry, schema default
- `src/workers/generationWorker.js` — keyword scan filter for vector-only entries
- `src/locales/en/index.json`, `src/locales/ru/index.json` — i18n keys

**Testing**: See TESTING_CHECKLIST.md section 1

### Phase 5: Memory Injection, Deletion Protection, Import Cleanup (2026-04-18)

Status: `done | ready for testing` (Commits: 3d5abbd, ddeb132, 587d83c, 7c320b8)
PR: #34

**5.1. Memory Injection Filter**
- [done | ready for testing] Entries only injected when first message of segment leaves context window
- Before: all active entries scored by overlap with recent history (+8 if any messageId in context)
- After: `eligibleEntries` filter — if `messageIds[0]` still in `recentMessageIds`, entry excluded from injection
- Entries without messageIds (manually created) always eligible
- File: `generationService.js:811-816`

**5.2. Delete Protection — Only Last Message(s)**
- [done | ready for testing] Selection toolbar: Delete button hidden unless selected messages are consecutive from end
- [done | ready for testing] Single message actions menu (open-actions): Delete option only for last message
- [done | ready for testing] Safety fallback in `deleteSelectedMessages()` — silently returns if not consecutive from end
- Files: `ChatInput.vue` (v-if canDeleteSelected), `ChatView.vue` (selectionIncludesLast computed, openMessageActions guard)

**5.3. Batch Draft Generation**
- [done | tested] Scan Chat: finds uncovered messages, segments by interval, stores in `automation.plannedSegments`
- [done | tested] Generate Drafts: quick picks (1/3/5/All) + custom number input field
- [done | tested] Sequential generation with progress toasts, planned segments removed after success
- [done | tested] DRAFT badge (purple) on messages covered by pending drafts
- Files: `ChatView.vue` (runBatchDraftGeneration, Scan Chat handler, batch UI), `ChatMessage.vue` (isDraftMemory prop, draft-memory CSS)

**5.4. Import Cleanup**
- [done | ready for testing] `chatImporter.js`: clear `pendingDrafts`, `pendingTrigger`, `plannedSegments` on import
- [done | ready for testing] `chatImporter.js`: reset invalid `promptPreset` (e.g. stale `durable_events` key) to `detailed_beats`
- [done | ready for testing] `chatImporter.js`: clear `generationModel` and `generationUseCurrentModelOverride` (model may not exist on another device)
- [done | ready for testing] `ChatView.vue`: after import, set `lastProcessedMessageCount` = total messages to prevent auto-trigger

**5.5. Prompt Preset Validation**
- [done | ready for testing] Preview Rule: fallback to `options[0]` when preset key not found
- [done | ready for testing] Settings state builder: validate `promptPreset` against `getMemoryPromptOptions()`, fallback to `detailed_beats`
- Root cause: exported chats contained stale preset key `durable_events` which no longer exists in built-in prompts

**5.6. Draft Stop Button**
- [done | ready for testing] `memoryDraftAbortController` — AbortController passed to `generateMemoryDraft()`
- [done | ready for testing] Red "Stop" button in progress card, calls `cancelMemoryDraft()`
- [done | ready for testing] Batch generation loop checks `aborted` signal before each iteration
- [done | ready for testing] CSS: `.context-sheet-btn-destructive` (red background)

**5.7. scanDepth Default Fix**
- [done | ready for testing] Changed global `scanDepth` from `1000` to `10`
- [done | ready for testing] Changed per-entry fallback: `entry.scanDepth ?? globalSettings.scanDepth ?? 10`
- [done | ready for testing] "Apply Global Settings" resets `entry.scanDepth` to `null`

**5.8. Draft Generation Fixes (from 09f8adf)**
- [done | ready for testing] Manual draft skips conflict check (source `manual_draft`/`manual_regenerate`)
- [done | ready for testing] `generateMemoryDraft`: added `onError` callback, `stream: false` parameter
- [done | ready for testing] Error toast now visible (closeBottomSheet before showToast)
- [done | ready for testing] Memory Books sheet opens immediately for manual draft (shows progress card)

### Testing Results & Known Issues (2026-04-18)

**Verified Working:**
- ✅ Tokenizer cache works (instant second open)
- ✅ Match Whole Words updated to ST/Glaze/Off format
- ✅ Regenerate button added for approved entries and drafts
- ✅ PENDING badges show on messages awaiting auto-generation
- ✅ Back navigation for prompt preview works
- ✅ Scan Chat + Generate Drafts batch flow works
- ✅ DRAFT badges (purple) show on messages covered by pending drafts
- ✅ Generate Drafts menu: quick picks + custom number input
- ✅ Draft generation with progress and sequential processing

**Bugs Found During Testing (fixed in this branch):**
1. ✅ **Draft generation status not showing** — FIXED (watch on memoryDraftState, onError callback, stream:false)
2. ✅ **Delete from middle of chat possible** — FIXED (two paths: selection toolbar + open-actions menu)
3. ✅ **Auto-draft triggers on import** — FIXED (cleared pendingDrafts/pendingTrigger, set lastProcessedMessageCount)
4. ✅ **Prompt preset not loading** — FIXED (stale `durable_events` key, added validation + fallback)
5. ✅ **Generate Drafts button did nothing** — FIXED (`action` → `onClick` for BottomSheet items)

**Known Issues (not fixed):**
1. ❌ **Retrieval badges still not showing after regeneration** (HIGH)
   - Issue: _source added to triggeredLorebooks, but badges still invisible
   - Status: `not fixed | pending investigation`

2. ⚠️ **Tokenizer first load slow (4.6s)** (MEDIUM)
   - Acceptable — cache works, optimization deferred
   - Status: `acceptable | optimization deferred`

### Execution Order

1. ✅ **Phase 1** (Vector/Lorebook UX) — COMPLETED
2. ✅ **Phase 4** (Optional keyword search) — COMPLETED
3. ✅ **Phase 2** (Memory Books UX) — COMPLETED (5/5 tasks + extras)
4. ✅ **Phase 3** (Tokenizer) — COMPLETED (2/3 tasks, remaining deferred)
5. ✅ **Phase 5** (Injection filter, deletion, import, batch, stop) — COMPLETED

### Remaining Work (Deferred)

**HIGH Priority:**
- [ ] Fix retrieval badges not showing after regeneration

**MEDIUM Priority:**
- [ ] Memory Books settings sync (main ↔ in-chat menu)
- [ ] Extract Memory Books UI to dedicated component (reduce ChatView ~1000 lines)
- [ ] Separate menus for injection types (vector/keyword/memory)

**LOW Priority:**
- [ ] Background tokenizer pre-calculation (battery consideration)
- [ ] Extract tokenizer to dedicated component
- [ ] Universal navigation stack for all sheets

### Phase 6: Component Extraction Refactoring (2026-04-18)

**Goal:** Reduce ChatView.vue complexity by extracting large UI sections into dedicated SheetView-based components.

**Status:** `in progress`

**Branch:** `feat/component-extraction` (from `origin/dev` at `1434aa3`)

**Motivation:**
- ChatView.vue is ~7000 lines, making it difficult to maintain and navigate
- Tokenizer, Memory Books, and Vectorization UIs are implemented as inline HTML in `showBottomSheet` calls
- Moving to dedicated Vue components improves:
  - Code organization and reusability
  - Type safety and IDE support
  - Testing capabilities
  - Maintainability

**Tasks:**

1. **Extract Tokenizer to TokenizerSheet.vue**
   - Status: `done | tested`
   - Create `src/components/sheets/TokenizerSheet.vue` using SheetView
   - Props: breakdown, historyHidePreview, contextSegments, contextLegendItems, contextBreakdownItems, shouldRecommendHide, historyUsagePercent, isCalculating
   - Emits: close, hide-messages, open-settings
   - Replace `openContextSheet()` in ChatView with `tokenizerSheetRef.open()`
   - Files modified:
     - [x] `src/components/sheets/TokenizerSheet.vue` (created, 543 lines)
     - [x] `src/views/ChatView.vue` (integrate component, remove ~100 lines inline HTML)
   - Build: passes ✓
   - Commit: `3d03952`

2. **Extract Memory Books to MemoryBooksSheet.vue**
   - Status: `done | tested`
   - Create dedicated component for memory book management UI
   - Extract `openMemoryBooksSheet()` logic (~500+ lines inline HTML)
   - Complexity: high — many event handlers, dynamic sections (drafts/entries/settings)
   - Props: memoryBook, currentMessages, characterName, sessionId, memoryDraftState, pendingMemoryMessageIds
   - Emits: 11 events (approve-draft, delete-draft, scan-chat, batch-generate, open-settings, open-maintenance, etc.)
   - Files modified:
     - [x] `src/components/sheets/MemoryBooksSheet.vue` (created, 883 lines)
     - [x] `src/views/ChatView.vue` (removed ~500 lines inline HTML, added 11 event handlers, added `loadCurrentMemoryBook()` helper)
   - Build: passes ✓
   - Commit: `f332d0f`

3. **Extract Vectorization UI to VectorizationSheet.vue**
   - Status: `deferred`
   - Priority: low (vectorization UI is relatively small and already modular)
   - Create dedicated component for lorebook vectorization UI
   - Extract embedding status, reindex, and vector search settings

**Summary:**
- ✅ TokenizerSheet.vue (543 lines) — DONE
- ✅ MemoryBooksSheet.vue (883 lines) — DONE
- ⏸️ VectorizationSheet.vue — DEFERRED (low priority)
- ✅ ChatView.vue reduced by ~600 lines of inline HTML (6982 → 6764 lines)

**Impact:**
- Improved code organization: separate components vs inline HTML strings
- Better type safety and IDE support
- Enhanced testability: components can be tested in isolation
- Easier maintenance: changes isolated to specific components

### Testing Checklist

After each phase:
- [x] `npm run build` passes without errors
- [x] Manual testing in browser (web build)
- [x] Verify backward compatibility (existing lorebooks/memories load correctly)
- [x] Check console for errors
- [x] Test on mobile: batch generation, delete protection, import cleanup
- [x] PR created: #34

## Sync Setup Guide — For Developers

### How Cloud Sync Works

Glaze syncs data to cloud storage (Dropbox or Google Drive) using an incremental manifest-based approach:
1. **Manifest** (`manifest.json`) tracks every entity with `{type, id, path, updatedAt, hash, deleted}`
2. **Push**: Compare local manifest vs cloud manifest → upload only changed entities
3. **Pull**: Compare cloud manifest vs local manifest → download only newer entities
4. **Conflicts**: If local is newer AND cloud is newer → surface conflict for manual resolution

### Platform Setup

#### 1. Dropbox

**Create a Dropbox App:**
1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app" → choose "Scoped access" → "Full Dropbox" (or "App folder" if preferred)
3. Note your **App key**

**Configure OAuth redirect URIs:**
- In the Dropbox App Console → Settings → OAuth 2 → Redirect URIs
- Add ALL redirect URIs you will use:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/dropbox`
  - **Web (production)**: `https://yourdomain.com/oauth/dropbox/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/dropbox/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_DROPBOX_APP_KEY=your_app_key_here
# Optional overrides (defaults shown):
# VITE_DROPBOX_REDIRECT_NATIVE=com.hydall.glaze://oauth/dropbox
# VITE_DROPBOX_REDIRECT_WEB=https://yourdomain.com/oauth/dropbox/redirect.html
```

**Android/iOS config:**
- Ensure `capacitor.config.json` has `"appId": "com.hydall.glaze"` (must match redirect URI scheme)
- For Android: `android/app/src/main/AndroidManifest.xml` must have intent-filter for `com.hydall.glaze://`
- For iOS: `ios/App/App/AppDelegate.swift` handles URL scheme via Capacitor

#### 2. Google Drive

**Create a Google Cloud project:**
1. Go to https://console.cloud.google.com
2. Create a project → Enable Google Drive API
3. Go to "Credentials" → "Create OAuth client ID" → "Web application"
4. Note your **Client ID** (and optionally **Client Secret**)

**Configure redirect URIs:**
- In Google Cloud Console → Credentials → your OAuth client → "Authorized redirect URIs"
- Add ALL redirect URIs:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/gdrive`
  - **Web (production)**: `https://yourdomain.com/oauth/gdrive/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/gdrive/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_GDRIVE_CLIENT_ID=your_client_id_here
VITE_GDRIVE_CLIENT_SECRET=your_client_secret_here
# Optional overrides:
# VITE_GDRIVE_REDIRECT_NATIVE=com.hydall.glaze://oauth/gdrive
# VITE_GDRIVE_REDIRECT_WEB=https://yourdomain.com/oauth/gdrive/redirect.html
```

### Error 400 Troubleshooting

**Error 400 on OAuth token exchange** = `redirect_uri` mismatch.

The `redirect_uri` sent in the OAuth authorize request must **exactly match** the `redirect_uri` sent in the token exchange request AND must be registered in the provider's OAuth console.

Common causes:
1. **Hardcoded localhost in production**: Old code used `http://localhost:5173/...` — this only works in dev. Fixed: now uses `window.location.origin` as default.
2. **Missing redirect URI in OAuth console**: The URI you deploy with must be added to the app's redirect URI list in Dropbox/Google console.
3. **Platform mismatch**: Native builds use `com.hydall.glaze://...` scheme. Web builds use `https://...`. Each platform needs its own redirect URI registered.
4. **Port mismatch for Electron**: Electron uses loopback `http://127.0.0.1:PORT/oauth/callback` with a random port. The OAuth provider must allow loopback redirects (Google does by default for "Desktop app" client type; Dropbox requires adding it explicitly).

### Error 401/403 Troubleshooting

- **401**: Access token expired → auto-refresh via `refresh_token`. If refresh also fails → user must reconnect.
- **403**: App permissions revoked or API quota exceeded. User must reconnect.

### Encryption (Optional)

Encryption uses AES-256-GCM via Web Crypto API, key derived from a 12-word BIP39 mnemonic.
- **Without encryption**: Data stored as plain JSON in cloud. Simple, portable, debuggable.
- **With encryption**: Each entity encrypted before upload. Recovery phrase required to decrypt on other devices.
- **Migration**: If cloud has `.enc` files and encryption is disabled, the system attempts to read both `.enc` and `.json` variants.
- **Key files**: `src/core/services/crypto/syncCrypto.js` (AES-GCM), `src/core/services/crypto/keyManager.js` (BIP39, storage)
