# Roadmap

## Purpose

This file tracks the current implementation roadmap for the chat context pipeline, summary flow, lorebook retrieval, and future memory systems.

It is the source of truth for:
- what is already done;
- what was intentionally rejected;
- what is currently planned next;
- the intended architecture direction, so work can resume after unrelated tasks without re-deciding old questions.

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

### 4. Memory Books

Goal:
Build a higher-level long-term memory system once summary and vector retrieval are in place.

Target behavior:
- The app can retain important long-term facts or developments beyond the immediate visible chat history.
- Memory books should be retrievable and context-aware.
- They should not be a fragile bolt-on; they should sit on top of summary + vector infrastructure.

Architecture direction:
- Memory books should come after summary and vector layers are stable.
- They should likely use:
  - summary output as one source of durable information
  - vector search for retrieval
  - explicit storage and lifecycle rules
- Memory entries should be manageable, inspectable, and eventually editable.

Probable future components:
- memory extraction rules
- memory storage schema
- retrieval strategy
- conflict / duplication handling
- recency / importance weighting
- UI for browsing and managing memories

Important constraint:
- Do not start implementing memory books before the summary block and vector foundations are stable, otherwise the feature will be rebuilt later.

Expected result:
- A durable memory layer built on stable primitives rather than temporary shortcuts.

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
- vectors are in maintenance mode: WORKS, do not touch without a concrete bug report;
- improve vector ranking only if a real user-facing retrieval miss forces it;
- summary simple mode prompts — proper defaults and editability.

## Resume Notes

When returning to this roadmap after unrelated work:
- do not reopen rejected tokenizer / reserve ideas unless there is a new explicit decision;
- vectorization infrastructure is done on `feat/vectorization-v2` (clean branch from `upstream/dev`);
- entries with `vectorSearch: true` are excluded from keyword matching (both `lorebookState.js` and `generationWorker.js`);
- vector QA coverage now includes automated end-to-end verification of the vector-only retrieval path;
- local `dev` branch merges both `feat/cloud-sync` and `feat/vectorization-v2` for integration testing;
- keep future retrieval work aligned with reusable vector infrastructure, not feature-specific hacks.
