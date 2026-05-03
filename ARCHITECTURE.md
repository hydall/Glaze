# Architecture Audit — Tokenizer, Vectorization, MemoryBooks, Macros, Cloud Sync

Related docs:
- Refactor history (Phases 0–14): `docs/refactoring/completed-phases.md`
- Forward plan (async integrity, DB safety): `docs/refactoring/async-integrity.md`
- Deferred items: `docs/refactoring/deferred-items.md`
- Known gaps: `docs/rules/known-gaps.md`
- Vue guard rails: `docs/rules/vue-components.md`
- Generation invariants: `docs/rules/generation.md`
- Race condition rules: `docs/rules/race-conditions.md`
- Database rules: `docs/rules/database.md`
- Formal invariants with code refs: `docs/INVARIANTS.md`

## 0. Architecture Overview

Refactor phases 1–14 are complete. History and details: `docs/refactor-history.md`.

### Target Architecture

```text
UI
  -> Use Cases
    -> Ordered Pipelines
      -> Transport

Side effects / observers
  <- Event Hub <- Use Cases / Pipelines
```

- `UI` gathers user intent and renders state.
- `Use Cases` own actions like chat generation, summary generation, and memory-draft generation.
- `Ordered Pipelines` preserve correctness-critical ordering for prompt and request flow.
- `Event Hub` carries domain facts and optional side effects, but does not replace orchestration.

### Event System

56 canonical events across 4 namespaces (`nav.*`, `domain.*`, `debug.*`, `ui.*`).
All internal events use `publishAppEvent()` / `subscribeAppEvent()`. Cancelable events via `publishCancelableAppEvent()`.
Dead code events and known gaps: `docs/rules/known-gaps.md`.

## 0.1 Directory Tree

```text
src/
├── assets/                    # Static resources
│   ├── css/                   # Global styles
│   ├── logos/                 # App logos
│   └── presets/               # Default LLM presets (renri, fawnie, etc.)
├── components/                # Reusable Vue components
│   ├── chat/                  # ChatInput, ChatMessage, MagicDrawer
│   ├── editors/               # GenericEditor, FullScreenEditor
│   ├── layout/                # AppHeader, BottomNavigation, AppLoader
│   ├── media/                 # HoloCardViewer, ImageViewer
│   ├── sheets/                # Bottom sheet content (LorebookSheet, RegexSheet, SyncSheet, etc.)
│   └── ui/                    # Generic UI primitives (BottomSheet, FabButton, SheetView)
├── composables/               # Vue composables (extracted from views)
│   ├── api/                   # API/runtime config composables
│   ├── app/                   # App-level init, event subscriptions, onboarding
│   ├── character/             # Character editor, thumbnails, import/export
│   ├── chat/                  # Chat generation, context, memory, message selection, auto-sync
│   ├── lorebook/              # Lorebook vector status, embedding logic
│   ├── theme/                 # Theme presets, settings, renderer
│   └── ui/                    # Header, glossary, viewer composables
├── core/
│   ├── config/                # Settings singletons (APISettings, APPSettings, syncConfig)
│   ├── events/                # Event hub layer
│   │   └── projections/       # Event→state projections (debugStateProjection)
│   ├── extensions/            # App extensions (appExtensions)
│   ├── llm/                   # LLM orchestration
│   │   ├── assemblers/        # Request payload builders per provider
│   │   ├── contracts/         # Provider capability contracts
│   │   ├── pipeline/          # Ordered prompt/request pipeline
│   │   ├── providers/         # Provider adapters (openai, claude, novelai, etc.)
│   │   ├── transport/         # HTTP transport, SSE streaming, wake lock
│   │   └── usecases/          # Use cases (chat generation, summary, memory draft)
│   ├── services/              # Business logic services
│   │   ├── adapters/          # Cloud adapters (gdriveAdapter, dropboxAdapter)
│   │   ├── catalog/           # Service catalog / dependency wiring
│   │   └── crypto/            # Sync encryption (AES-GCM)
│   ├── states/                # Reactive state modules (lorebookState, personaState, presetState, syncState, themeState)
│   └── utils/                 # Core utility functions
├── locales/                   # i18n translations
│   ├── en/                    # English
│   └── ru/                    # Russian
├── tokenizers/                # Bundled tokenizer (gp-tokenizer)
├── utils/                     # Shared utilities (db.js, macroEngine, tokenizer, textFormatter, characterIO)
├── views/                     # Page-level components
│   └── Menu/                  # Settings subviews
│       └── Settings/          # ThemeSettingsView, ApiView, SyncView
└── workers/                   # Web Workers (generationWorker — off-thread prompt building)
```

## 1. Tokenizer

### Files
- `src/utils/tokenizer.js` — Token estimation using GPTTokenizer (cl100k_base compatible)
- `src/tokenizers/gp-tokenizer-9KQssiTx.js` — Bundled tokenizer implementation
- `src/views/ChatView.vue` — UI: `openContextSheet()`, context breakdown display
- `src/workers/generationWorker.js` — Token calculation in `calculateContext()`

### Structure

**Token Estimation (`tokenizer.js`):**
- `estimateTokens(text)` — Uses GPTTokenizer with base64 media stripping
- Stripping prevents embedded images from inflating token counts

**Token Count in ChatMessage.vue:**
- `tokenCount` computed always applies `applyRegexes(..., ephemerality=2)` (prompt-only) to the message text before estimating
- This ensures the displayed per-message token count accounts for regex stripping that will happen during actual prompt building
- Previously conditioned on `combinedMessageData.regexes` which only contained ephemerality=1 (both) regexes, missing prompt-only stripping

**Context Calculation (`generationWorker.js`):**
- `calculateContext()` — Computes token breakdown by source:
  - `character` — Character card content
  - `preset` — Chat prompt/preset
  - `summary` — Summary sections (timeline, characterArcs, etc.)
  - `authorsNote` — Author's note
  - `lorebook` — Keyword lorebook entries
  - `vectorLore` — Vector search lorebook entries
  - `memory` — Memory book entries
  - `history` — Chat history (hidden + visible)

**UI Flow (`ChatView.vue`):**
1. User opens Tokenizer via MagicDrawer
2. `openContextSheet()` renders bottom sheet with context breakdown
3. Visual bar shows proportional segments by color
4. Reserve visualization: lorebooks displayed inside reserve zone

### Key State
- `contextCutoff` — Index marking where context window starts
- `lastContextUpdate` — Timestamp for cache invalidation
- `contextCache` — Cached calculation result

---

## 2. Vectorization

### Files
- `src/utils/vectorMath.js` — Vector math operations
- `src/core/services/embeddingService.js` — Embedding API calls
- `src/core/config/embeddingSettings.js` — Embedding connection config (endpoint, key, model)
- `src/core/states/lorebookState.js` — Reactive state, CRUD, activation, import/export (326 lines; re-exports search/embedding for backward compat)
- `src/core/services/lorebookSearchService.js` — Keyword scan logic (182 lines)
- `src/core/services/lorebookVectorSearch.js` — Vector search, hybrid/descriptor scoring, query sanitization (431 lines)
- `src/core/services/lorebookEmbeddingService.js` — Embedding orchestration, hash, status, error classification (352 lines)
- `src/utils/db.js` — IndexedDB storage for embeddings
- `src/workers/generationWorker.js` — Dual-channel retrieval integration
- `src/core/services/generationService.js` — Vector search execution

### Structure

**Search Type System (split across `lorebookState.js` + services):**
- `searchType` — `'keys'` | `'vector'` | `'both'` (was `vectorSearchEnabled` + `keySearchEnabled`)
- `'keys'` — Keyword-only matching (default)
- `'vector'` — Vector-only semantic search
- `'both'` — Combined keyword + vector search
- Single `scanDepth` field with dynamic label based on search type
- Vector-specific settings: `vectorThreshold`, `vectorTopK`, `embeddingTarget`

**Embedding Settings (split across two locations):**
- **API Settings** (`embeddingSettings.js`): endpoint, API key, model, useSame, maxChunkTokens, enabled
- **Lorebook Settings** (`lorebookState.globalSettings`): searchType, scanDepth, vectorThreshold, vectorTopK, embeddingTarget
- No duplication — search params are owned by lorebook, connection params by API

**Vector Math (`vectorMath.js`):**
- `cosineSimilarity(a, b)` — Standard cosine similarity
- `findTopK(queryVector, candidates, k, threshold)` — Single-vector top-K search
- `findTopKMulti(queryChunks, candidates, k, threshold)` — MaxSim algorithm for multi-chunk entries

**Embedding Service (`embeddingService.js`):**
- `getEmbedding(text)` — Single text embedding (returns array of {text, vector} chunks)
- `getEmbeddings(texts[])` — Batch embedding with auto-chunking
- `testEmbeddingConnection()` — Connection test

**Auto-chunking:**
- Texts split at sentence/paragraph boundaries
- Default `maxChunkTokens: 512`
- Each chunk embedded separately

**IndexedDB Storage (`db.js`):**
- Store: `embeddings`
- Schema v8: `{ id, sourceType, sourceId, vectors[], textHash, retrievalHints, updatedAt }`
- Legacy support: single `vector` field

**Lorebook State (`lorebookState.js` + extracted services):**
- `indexLorebookEntry(entry, lorebookId)` — Single entry indexing with hash check
- `indexLorebookEntries(lorebookId)` — Bulk indexing with progress
- `vectorSearchLorebooks(queryChunks, options)` — Dual-channel search (vector + keyword)
- `reindexMemoryEntry(entry, charId, sessionId)` — Memory entry reindexing
- Uses `embeddingTarget` from `lorebookState.globalSettings` (not from API config)

**Dual-Channel Retrieval:**
1. Worker scans entries with `scanLorebooksPure()` — keyword matching (skipped if `searchType === 'vector'`)
2. Generation service runs `vectorSearchLorebooks()` — semantic search (skipped if `searchType === 'keys'`)
3. Results merged, deduplicated by entry ID
4. Keyword matches prioritized over vector matches

**Retrieval Boosting:**
- `hybridBoost` — Based on `comment`/`keys` overlap with query
- `descriptorBoost` — Based on early `content` + `retrievalHints` overlap

---

## 3. MemoryBooks

### Files
- `src/composables/chat/useMemoryBooks.js` — Memory book CRUD, entry management, vector toggle, reindex, draft generation
- `src/composables/chat/useMemorySheetUI.js` — Memory sheet DOM, entry editor, prompt manager, generation settings
- `src/composables/chat/useMemoryAutomation.js` — Auto-creation, stable-turn triggers, bootstrap, quick model change
- `src/core/services/generationService.js` — Memory injection during generation
- `src/core/states/lorebookState.js` — Vector search for memories
- `src/utils/db.js` — Chat persistence with memory books via `patchChatData`

### Structure

**Data Model:**
```javascript
memoryBooks: {
  [sessionId]: {
    entries: [MemoryEntry],
    pendingDrafts: [DraftEntry],
    settings: MemorySettings,
    automation: AutomationState,
    updatedAt: timestamp
  }
}

MemoryEntry: {
  id: string,
  content: string,
  keys: string[],
  glazeKeys: string[],
  vectorSearch: boolean,
  messageIds: string[],
  messageRange: { start: number, end: number },
  status: 'active' | 'needs_rebuild' | 'stale',
  source: 'manual' | 'auto' | 'import_bootstrap',
  createdAt: timestamp,
  updatedAt: timestamp
}

DraftEntry: {
  id: string,
  title: string,
  messageIds: string[],
  messageRange: { start: number, end: number },
  prompt: string,
  generationStatus: 'pending' | 'generating' | 'completed' | 'failed',
  createdAt: timestamp,
  generatedAt: timestamp | null,
  error: string | null
}

MemorySettings: {
  generationSource: 'current' | 'custom',
  generationEndpoint: string,
  generationModel: string,
  generationApiKey: string,
  generationTemperature: number | null,
  autoCreateInterval: number,
  batchSize: number,
  useDelayedAutomation: boolean,
  maxInjectedEntries: number,
  injectionTarget: 'summary_block' | 'summary_macro',
  vectorSearchEnabled: boolean,
  keyMatchMode: 'plain' | 'glaze' | 'both',
  promptPreset: string,
  customPrompts: CustomPrompt[]
}
```

**Generation Flow:**
1. `generateMemoryDraftForMessages()` — Creates draft from selected messages
2. `runBatchDraftGenerationFromIds()` — Parallel batch generation for pending drafts, capped by `settings.batchSize`
3. `generateMemoryDraft()` — API call with continuity context
4. Draft parsed into MemoryEntry-compatible shape, stores both parsed `content` and full `rawContent`, user approves or regenerates

**Pending Draft Behavior:**
- `Scan Chat` creates pending draft placeholders only; generation is explicit
- `Generate` starts one draft job for a specific `draftId`
- `Generate Remaining` starts up to `settings.batchSize` pending drafts that are not already running
- In-flight draft IDs are tracked separately in UI state so batch generation does not restart the same draft twice
- Each draft has its own timer/abort controller; `Stop` cancels only that draft
- Draft completion re-reads latest chat data before save so concurrent completions do not overwrite each other

**Injection Rules:**
- `buildMemoryInjection()` now uses `cutoffOriginalIndex` from worker output
- Memory entries are injected only if all linked `messageIds` are already outside the active prompt context
- This avoids injecting memories for message ranges that are still present in the current prompt window

**Message Badges (ChatMessage.vue):**
- `MEM` — Message covered by approved memory entry
- `DRAFT` — Message covered by pending draft
- `PENDING` — Message awaiting auto-generation trigger
- `STALE` — Memory entry needs rebuild

---

## 4. Macro Engine

### Files
- `src/utils/macroEngine.js` — Macro replacement engine

### Supported Macros

**Character/User:**
- `{{char}}` — Character name
- `{{description}}` — Character description
- `{{scenario}}` — Character scenario
- `{{personality}}` — Character personality
- `{{mesExamples}}` — Message examples
- `{{user}}` — User name
- `{{persona}}` — User persona prompt

**Variables (SillyTavern-compatible):**
- `{{setvar::name::value}}` — Set session variable (per char+session, stored in localStorage `gz_vars_{charId}_{sessionId}`)
- `{{getvar::name}}` — Get session variable
- `{{setglobalvar::name::value}}` — Set global variable (cross-session, stored in localStorage `gz_global_vars`)
- `{{getglobalvar::name}}` — Get global variable

**Lucid Loom / LumiverseHelper macros:**
- `{{lumiaDef}}`, `{{lumiaOOC}}`, `{{lumiaOOCErotic}}`, `{{lumiaOOCEroticBleed}}`, `{{lumiaPersonality}}`
- `{{loomRetrofits}}`, `{{loomStyle}}`, `{{loomSummary}}`, `{{loomUtils}}`
- `{{sim_tracker}}`, `{{suggest}}`
- These read from global variables set via `setglobalvar`. Return original macro if not found.

**Utility:**
- `{{random::a::b::c}}` — Random choice
- `{{pick::a::b::c}}` — Deterministic pick (hash-based, stable per session)
- `{{roll::1d20}}` — Dice roll (e.g. `2d6`)
- `{{trim}}` — Trim whitespace
- `{{date}}` — Current date
- `{{time}}` — Current time
- `{{weekday}}` — Day of week

**Reasoning:**
- `{{reasoningPrefix}}` — Reasoning start tag (from preset or localStorage `gz_api_reasoning_start`)
- `{{reasoningSuffix}}` — Reasoning end tag (from preset or localStorage `gz_api_reasoning_end`)

**Comments:**
- `{{// comment}}` — Single-line comment (removed)
- `{{ // }}...{{ /// }}` — Multi-line scoped comment (removed)

**Escaping:**
- `\{\{` → `{{` and `\}\}` → `}}`

---

## 5. Reasoning System

### Files
- `src/core/llm/transport/responseNormalizer.js` — Reasoning extraction from API response
- `src/core/services/generationService.js` — Reasoning settings resolution
- `src/views/ApiView.vue` — User-facing reasoning toggle
- `src/views/PresetView.vue` — Preset reasoning settings (now thin shell wiring 11 composables)

### Logic

**Settings Resolution:**
1. User enables "Show Native Reasoning" in API settings → `requestReasoning = true`
2. Preset can override ONLY to enable (`reasoningEnabled: true`)
3. Preset `reasoningEnabled: false` does NOT disable user's choice
4. `reasoningEffort` — `'auto'` | `'low'` | `'medium'` | `'high'` (auto = not sent to API)

**Extraction (responseNormalizer.js):**
1. `reasoning_content` field from API response → `finalReasoning`
2. Inline tags (`reasoningStart`...`reasoningEnd`) in content → `inlineReasoning`
3. Both combined and displayed to user
4. `hasInlineTags = !!tagStart && !!tagEnd` — requires non-empty tag config
5. Native/mobile fallback: if `response.body.getReader()` is unavailable, stream requests fall back to one-shot response parsing instead of failing

---

## 6. Network / LLM Requests

### Files
- `src/components/chat/ChatInput.vue` — Starts user send flow and exposes request preview sheet entry points
- `src/components/chat/MagicDrawer.vue` — Secondary request preview entry point
- `src/components/sheets/RequestPreviewSheet.vue` — Displays the last built prompt and optional captured network trace
- `src/views/ChatView.vue` — Chat session orchestration, open/load paths, and integration of extracted generation composables
- `src/views/ApiView.vue` — API settings UI, model discovery, preset CRUD, and connection test UX
- `src/core/config/APISettings.js` — Runtime API config reads, endpoint normalization, provider blacklist checks, and `/models` discovery
- `src/core/services/generationService.js` — Prompt orchestration, late enrichment, request assembly, and direct `executeRequest()` callers
- `src/workers/generationWorker.js` — Prompt assembly, macro/regex application, keyword lore scan, and token accounting
- `src/core/llm/transport/requestOrchestrator.js` — Transport entrypoint that resolves provider, wires runtime policy, and dispatches to execution path
- `src/core/llm/transport/completionsClient.js` — Fetch-based `/chat/completions` execution
- `src/core/llm/transport/requestLifecycle.js` — Timeouts, abort guards, request headers, trace start
- `src/core/llm/transport/requestExecution.js` — Native non-stream vs fetch execution split, abortable XHR for native HTTP
- `src/core/llm/transport/streamingSse.js` — SSE stream consumption and delta dispatch
- `src/core/llm/transport/responseHandling.js` — One-shot/native response shaping
- `src/core/llm/transport/requestOutcome.js` — Abort/timeout/failure completion policy
- `src/core/llm/transport/requestRuntimePolicy.js` — Wake lock / foreground-runtime behavior
- `src/core/llm/transport/streamAccumulator.js` — Shared text/reasoning accumulation across transport paths
- `src/core/llm/transport/responseNormalizer.js` — Shared final-response extraction for OpenAI-like one-shot/native/fallback responses
- `src/core/llm/transport/sseParser.js` — SSE line parsing only
- `src/core/services/networkDebugService.js` — Publishes debug events via event hub for on-device trace inspection
- `src/composables/chat/useGenerationPreparation.js` — Placeholder/session context preparation
- `src/composables/chat/useGenerationStateSetup.js` — Generation state registration and stream UI setup
- `src/composables/chat/useGenerationStreamUpdate.js` — Background persistence throttling for streaming updates
- `src/composables/chat/useGenerationPromptReady.js` — Prompt metadata assignment on ready
- `src/composables/chat/useGenerationCompleteHandler.js` — Completion/finalization path
- `src/composables/chat/useGenerationErrorHandler.js` — Error path and user-visible failure handling
- `src/composables/chat/useGenerationStateRestore.js` — Abort/rollback restore path
- `src/composables/chat/usePromptMetadataSnapshots.js` — Prompt metadata rollback snapshots
- `src/composables/chat/useTypingStateCleanup.js` — Stale typing cleanup helpers

### Request Types
- `chat` — Main character response generation from `ChatView.vue` via `generateChatResponse()`
- `summary` — Preset/summary generation via `generateSummary()`
- `memory_draft` — MemoryBook draft generation via `generateMemoryDraft()`
- `model_discovery` — `/models` fetch from `ApiView.vue` via `fetchRemoteModels()`

### Current End-to-End Flow

**Chat Generation:**
1. `ChatInput.vue` emits send-related events and `ChatView.vue` receives them.
2. `ChatView.vue:startGeneration()` performs top-level UI/session orchestration:
   - checks basic API config availability
   - creates `AbortController`
   - creates or reuses the typing placeholder message
   - resolves session context and authors note
   - delegates placeholder/setup/restore/error/complete work to extracted chat composables
3. `generationService.js:generateChatResponse()` resolves the effective request inputs:
   - loads API config from `APISettings.js`
   - resolves active preset and reasoning tag settings
   - collects session vars, persona, regexes, and prompt options
   - sends prompt building to `generationWorker.js`
4. After the worker returns, `generationService.js` performs late enrichment:
   - vector lore retrieval
   - memory injection
   - late vector-lore budget limiting via `maxInjectedEntries`
   - context breakdown assembly
   - request-body creation and sanitization
   - `lastPrompt` snapshot for request preview UI
5. `generationService.js` calls `chatRequestAssembly.js:executeFinalChatRequest()` which calls `requestOrchestrator.js:executeRequest()` with transport config, reasoning config, request type, abort controller, and callbacks.
   `chatRequestAssembly.js` injects `controller` into `requestConfig` via `createImmutableChatRequestEnvelope()` — preserving abort ownership even through extension hooks.
   6. `requestOrchestrator.js` resolves the provider from `providerRegistry.js`, sets up `requestRuntimePolicy`, `streamAccumulator`, and `requestLifecycle`, then dispatches through `completionsClient.js` (fetch streaming), `executeAbortableJsonRequest` (XHR for native non-stream), or `requestExecution.js` (native non-stream fallback).
   7. The transport executes `/chat/completions` using either:
   - `CapacitorHttp.post()` for native non-stream local HTTP requests
   - `fetch()` for web and streaming requests
8. The transport parses either:
   - one-shot JSON response
   - SSE stream via `response.body.getReader()`
   - one-shot fallback when a stream request has no readable body on the current runtime
9. Shared normalizers extract assistant text plus reasoning from:
   - native `reasoning_content`
   - inline reasoning tags in `content`
10. Callback flow returns to `ChatView.vue` composables:
   - `onUpdate()` applies streaming text/reasoning to the placeholder message
   - `onComplete()` finalizes the message, stores metadata, and clears generation state
   - `onError()` restores UI/DB state and writes formatted error output

**Summary + Memory Draft Requests:**
1. `PresetView.vue` or `ChatView.vue` call `generateSummary()` / `generateMemoryDraft()`.
2. Each use case owns its own dependency assembly and calls `requestOrchestrator.js:executeRequest()`.
3. Both use `sharedRequestHooks.js` for extension hook integration.
4. Prompt preview and network trace are now per-generation (keyed by `debugKey`), so these requests do not overwrite each other's debug state.

**Model Discovery:**
1. `ApiView.vue` normalizes the endpoint and calls `fetchRemoteModels()`.
2. `APISettings.js` requests `/models` using `fetch()` on web or `CapacitorHttp.get()` on native.
3. Returned model IDs feed the API settings selector UI.

### Current Responsibility Split

**UI / Session Lifecycle:**
- `ChatView.vue` owns top-level chat session orchestration and UI glue. Detailed generation lifecycle, memory automation, context breakdown, message selection, message display, session management, message actions, and chat generation logic are extracted into focused composables.
- `useGenerationPreparation.js`, `useGenerationStateSetup.js`, `useGenerationStreamUpdate.js`, `useGenerationPromptReady.js`, `useGenerationCompleteHandler.js`, `useGenerationErrorHandler.js`, and `useGenerationStateRestore.js` now own the detailed generation subpaths.
- `useSessionManagement.js` owns session create/switch/delete, session name editing, and session data persistence.
- `useMessageActions.js` owns message delete/hide, edit save/cancel, branch creation, image regeneration, and guidance text patching.
- `useChatGeneration.js` owns `sendMessage`, `startGeneration`, `handleImageRegenerate`, generation preflight checks, and image-gen lifecycle.
- `RequestPreviewSheet.vue` owns display of the last built prompt and the last stored network trace.
- `ApiView.vue` owns API settings editing, preset CRUD, and `/models` connectivity UX.

**Prompt Pipeline:**
- `generationWorker.js` builds prompt blocks, applies macros and regexes, scans keyword lore, and returns prompt/context metadata.
- `generationService.js` enriches worker output with vector lore and MemoryBook injection, computes final request payloads, and exposes generation entry points.

**Transport / Runtime:**
- `requestOrchestrator.js` is the transport entrypoint — resolves provider, wires runtime policy, and dispatches.
- `requestLifecycle.js`, `requestExecution.js`, `completionsClient.js`, `streamingSse.js`, `responseHandling.js`, and `requestOutcome.js` own the concrete transport flow.
- `requestRuntimePolicy.js` owns wake-lock / foreground-runtime behavior.
- `networkDebugService.js` publishes debug events via event hub; actual trace storage is in `requestTraceState.js`.

**Config / Storage:**
- `APISettings.js` reads runtime API values from `localStorage` and API presets from IndexedDB.
- `ApiView.vue` writes many of those values directly back to `localStorage`, and also mutates the active API preset record.
- `ChatView.vue` still performs some direct localStorage reads for preflight config checks.

### Abort Signal Propagation (PR #72)

Before PR #72, `AbortController` was created and stored in generation state, but the signal never reached `fetch()`. Pressing stop only cleared UI state; the TCP connection stayed open until the server finished.

**Current signal chain:**
1. `ChatView.vue` creates `AbortController` and passes `controller` into `useChatGeneration.startGeneration()`
2. `generationService.js:generateChatResponse()` injects `controller` into `requestConfig` (the critical fix — was `undefined` before)
3. `chatRequestAssembly.js:createImmutableChatRequestEnvelope()` preserves the original controller, warns if extension hooks try to replace it
4. `requestOrchestrator.js:executeRequest()` passes `controller?.signal` as `abortSignal` to `completionsClient.js`
5. `completionsClient.js` passes `abortSignal` to `streamingSse.js:consumeStreamingSseResponse()`
6. `streamingSse.js:readChunk()` listens on `abortSignal`, calls `reader.cancel()` and rejects with `AbortError`
7. `requestOutcome.js:handleAbortOutcome()` receives `userAborted` flag and routes accordingly

**User abort flow:**
1. User presses stop → `useGenerationAbort.js` sets `state.userAborted = true`, `state.controller.userAborted = true`, calls `controller.abort()`
2. Abort signal propagates through the chain above → `reader.cancel()` closes the TCP connection immediately
3. `handleAbortOutcome()` sees `userAborted = true` → tags `abortError.userAborted = true` → calls `onError(abortError)`
4. `useGenerationErrorHandler.js` fast-paths `AbortError` with `userAborted` → skips error toast, restores state, finalizes generation

**Stale generation guards:**
- `useGenerationFinalization.js` — `expectedGenId` check prevents finalizing a wrong generation
- `useGenerationStateRestore.js` — `expectedGenId` check, early-return if no state
- `useGenerationCompleteHandler.js` — stale completion skips typing cleanup for active newer generation
- `useGenerationStateSetup.js` — `flushPendingUIUpdate` and `initialUIUpdate` check `genId`/`sessionId`/`msgId` match; timer reschedule checks abort

### Crash Recovery Buffer (PR #72)

`useSessionPersistence.js` now maintains a crash recovery buffer in `localStorage`:
- `writeCrashBuffer()` writes on `visibilitychange` (hidden), `pagehide`, and `beforeunload`
- Buffer contains: `messages`, `draft`, `authorsNote`, `summary`, `lastScrollAnchor`, `savedAt`
- `clearCrashBuffer()` called after successful `asyncSaveCurrentSessionState()`
- On `openChat()`, if crash buffer has more messages than stored session, buffer is restored and persisted to IndexedDB
- Key format: `gz_chat_recovery_{charId}_{sessionId}`

### Transport Behavior Today
- Request endpoint is always `${apiUrl}/chat/completions` for generation and `${apiUrl}/models` for model discovery.
- `CONNECT_TIMEOUT` and `STREAM_TIMEOUT` are read from `localStorage` through `requestLifecycle.js`.
- Streaming requests use SSE parsing with `data: ...` lines and `[DONE]` termination.
- If a streaming response body is unavailable on the current runtime, the transport falls back to one-shot JSON parsing instead of hard-failing.
- **Abort signal propagation**: `AbortController.signal` now reaches `fetch()` through the full chain. Stream reader listens on signal and cancels immediately on abort.
- **Native non-streaming abort**: XHR-based `executeAbortableJsonRequest()` used for native HTTP non-streaming chat requests, allowing abort to close the TCP connection (CapacitorHttp does not support abort).
- **User abort vs timeout**: `userAborted` flag distinguishes intentional stop from timeout/failure. User abort skips error toast and partial-content recovery.
- Abort handling is dual-purpose:
  - user abort may still preserve partial text
  - timeout-triggered abort is treated as an error and may preserve partial text with `partialError`
- The transport contract is callback-based rather than event-object-based:
  - `onUpdate(chunk, reasoningChunk, effectiveText, effectiveReasoning, textDelta)`
  - `onComplete(text, reasoning, meta?)`
  - `onError(error)`

### Temporary Network Trace Debugging

**Files:**
- `src/core/services/networkDebugService.js` — Publishes debug events via event hub during chat + memory draft requests
- `src/core/llm/transport/requestOrchestrator.js` — Starts/updates/completes trace capture during transport
- `src/core/services/generationService.js` — Tags captures by request type and exposes the last request body for preview
- `src/components/sheets/RequestPreviewSheet.vue` — On-device viewer/toggle for the last captured trace

**Purpose:**
- Debug mobile/provider-specific failures without a dev console
- Confirm whether providers return native `reasoning_content`, inline reasoning tags, or neither
- Inspect exact memory draft request payloads and raw responses when summaries appear truncated

**Stored Trace Shape:**
- Request metadata: `requestType`, `apiUrl`, `stream`, timestamps, duration
- Request payload: masked request headers + JSON body
- Response metadata: HTTP status + response headers
- Parsed output: final `text`, `reasoning`, and `error`
- Stream-only diagnostics: bounded buffer of raw SSE `data:` lines

**Operational Notes:**
- Capture is gated by localStorage toggle `gz_debug_network_capture`
- Last trace persists in localStorage key `gz_last_network_trace`
- Trace persistence is debounced so streaming diagnostics do not write `localStorage` on every SSE chunk
- Request preview stays usable even when trace capture is disabled; the trace section is optional diagnostics only

### Current Mobile Power / Renderer Guardrails

These are compatibility-first runtime optimizations added after the network refactor to reduce battery/renderer churn when the shared battery-saver UI mode is enabled.

- Battery-saver UI mode is controlled only by the shared `Battery Saver UI` toggle. `Force Mobile Layout` changes layout only and does not imply lighter renderer behavior.
- Generation UI updates are batched instead of repainting every single stream delta immediately.
- `genTime` display updates once per second during generation instead of every 100ms.
- Battery-saver chat messages use a static typing suffix, plain `genTime` text, and a no-op transition path for swipe/token micro-animations instead of the more animated desktop-oriented presentation. This keeps Vue's transition lifecycle intact while removing the renderer cost of those animations.
- `smartScroll()` during active generation is throttled instead of firing on every stream update.
- Background persistence for in-flight stream text is slower on native and moderately slower in desktop battery-saver mode (`useGenerationStreamUpdate.js`) to reduce IndexedDB churn.
- `requestRuntimePolicy.js` delays foreground/background runtime activation for short requests and enables it immediately when the app is backgrounded mid-generation.
- Native auto-sync is skipped while generation is active or the app is backgrounded, and it now has a cooldown between runs.
- `useVirtualScroll.js` skips its extra per-scroll visibility health check and schedules heavy scroll work through `requestAnimationFrame` while battery-saver UI mode is active.

Battery-saver UI scope:
- The shared toggle enables the lighter UI/rendering guardrails: reduced animation, batched stream painting, slower stream persistence, and lighter virtual-scroll behavior, regardless of whether the user is in desktop or forced-mobile layout.

Native-only scope retained:
- `requestRuntimePolicy.js`, wake-lock/background-mode activation, notification-backed foreground runtime behavior, and generation auto-sync cooldown/background guards remain native-only runtime behavior and are not controlled by the battery-saver UI toggle.

**Current Limitation:**
- Trace storage is per-generation (keyed by `debugKey`, up to 10 concurrent traces). This was previously a singleton but has been resolved.

**Safe Removal Path:**
- Remove `networkDebugService.js`
- Remove trace UI/toggle from `RequestPreviewSheet.vue`
- Keep `generationService.js:getLastPrompt()` and prompt preview JSON unless request preview itself is being removed
- Keep trace capture non-blocking; generation success must never depend on diagnostics state

### Current Design Problems
- `ChatView.vue` is a large composable-wiring surface (~1390 script lines). It is a known exception to the 400-line guard rail because further extraction would cause prop-drilling (see Guard Rails). `openChat()` (~400 lines) remains due to high dependency count.
- Runtime config has multiple owners: `localStorage`, IndexedDB API presets, reactive `ApiView.vue` state, onboarding writes, and direct reads in feature views.
- Worker/service boundaries are not documented clearly: keyword lore lives in the worker, vector retrieval and memory injection happen later in the service layer.

### Resolved Problems
- **AbortController signal propagation (PR #72):** Signal now reaches `fetch()` through `requestConfig` → `completionsClient` → `streamingSse:readChunk()`. Stop button closes the TCP connection immediately.
- **Stale completions (PR #72):** Guarded by `expectedGenId` checks in finalize/restore/complete/setup paths.
- **Crash recovery (PR #72):** `useSessionPersistence` writes crash buffer on `pagehide`/`beforeunload`/`visibilitychange`.
- **Read-mutate-write races:** All 40+ `getChatData+saveChat` patterns migrated to `patchChatData`. See `docs/rules/database.md`.

### Actual Architecture (Landed)

**Provider / Contracts Layer:**
- `src/core/llm/contracts/providerContracts.js` — provider IDs, request kinds, baseline capability flags
- `src/core/llm/providers/providerRegistry.js` — registry boundary for provider adapters
- `src/core/llm/providers/openaiCompatibleProvider.js` — OpenAI-like endpoint normalization, auth, `/models` discovery, chat completion URL building

**Config Layer (actual locations):**
- `src/core/config/APISettings.js` — runtime API config reads/writes, endpoint normalization, provider blacklist, `/models` discovery, shared runtime-config boundary
- `src/core/config/APPSettings.js` — app-wide settings (currentLang, imageViewerMode, etc.)
- `src/core/config/embeddingSettings.js` — embedding connection config
- `src/core/config/ProviderProfiles.js` — provider profile CRUD, migration, sync key settings
- `src/core/config/syncConfig.js` — build-time sync provider availability

**Transport Layer (all in `src/core/llm/transport/`):**
- `requestOrchestrator.js` — Transport entrypoint: resolves provider, wires runtime policy, dispatches
- `completionsClient.js` — Fetch-based `/chat/completions` execution
- `requestLifecycle.js` — Timeout setup, abort guards, request headers
- `requestExecution.js` — Native non-stream vs fetch execution branching, abortable XHR for native HTTP (`executeAbortableJsonRequest`)
- `streamingSse.js` — SSE stream consumption and delta dispatch, abort-signal–aware chunk reader
- `sseParser.js` — SSE line parsing
- `responseHandling.js` — One-shot/native completion shaping
- `requestOutcome.js` — Abort/timeout/failure completion policy
- `requestRuntimePolicy.js` — Wake lock, background mode, native/web branching rules
- `streamAccumulator.js` — Shared text/reasoning accumulation
- `responseNormalizer.js` — Unified final-response extraction for one-shot/native/fallback

**Assembler Layer (all in `src/core/llm/assemblers/`):**
- `requestIntents.js` — app-level request intents for `chat`, `summary`, and `memory_draft`
- `payloadBuilderRegistry.js` — boundary for provider-specific payload builders
- `requestAssemblers.js` — bridges use cases to provider payload builders

**Pipeline Layer (all in `src/core/llm/pipeline/`):**
- `pipelineContext.js` — shared pipeline context construction
- `steps.js` — pipeline step definitions (context limit guard, etc.)
- `postPromptOrchestrator.js` — post-prompt orchestration (late enrichment, request assembly)

**Prompt/Config helpers (in `src/core/llm/usecases/`):**
- `promptConfigReaders.js` — config reading for prompt building
- `promptPayloadBuilder.js` — prompt payload construction
- `promptWorkerLifecycle.js` — worker orchestration

**Use Cases (all in `src/core/llm/usecases/`):**
- `generateChat.js` — chat generation entrypoint
- `generateSummary.js` — summary generation entrypoint
- `generateMemoryDraft.js` — memory draft generation entrypoint
- `calculateContext.js` — context token calculation
- `contextCalculation.js` — context calculation logic
- `chatPreparation.js` — chat prompt preparation
- `chatPreparedPromptExecution.js` — validates API config, runs prompt worker, extracts request config
- `chatRequestAssembly.js` — assembles and dispatches final chat request
- `impersonationRequest.js` — impersonation generation use case
- `summaryRequest.js` — summary request execution
- `memoryDraftRequest.js` — memory draft request execution
- `sharedRequestHooks.js` — shared extension hooks for non-chat requests
- `reasoningHeaders.js` — reasoning header configuration
- `chatGenerationAppAdapters.js` — notification adapters for generation lifecycle
- `chatGenerationServiceFactory.js` — factory wiring all service deps for `executeChatGenerationUseCase`

**Extension System (all in `src/core/extensions/`):**
- `extensionRegistry.js` (188 lines) — 6 generation hook points with readonly/mutating modes, priority ordering, `runGenerationHook()`
  - Hooks: `beforePromptBuild`, `afterPromptBuild`, `beforeRequestAssembly`, `beforeRequestSend`, `afterResponseNormalize`, `afterGenerationCommit`
  - Readonly hooks receive a deep-frozen snapshot; mutating hooks can transform payload and pass it to the next handler
- `appExtensions.js` (45 lines) — extension installer lifecycle (`registerAppExtensionInstaller`, `initAppExtensions`)

**Debug / Observability (actual locations):**
- `src/core/states/requestTraceState.js` — raw request/response traces keyed by `debugKey` (up to 10 concurrent)
- `src/core/states/promptPreviewState.js` — prompt previews keyed by `debugKey` (up to 10 concurrent)
- `src/core/states/requestPreviewState.js` — joins prompt preview + request trace for UI
- `src/core/events/projections/debugStateProjection.js` — event→state projection: subscribes to debug events, routes to trace/preview state modules

Composable directory listing and per-phase decomposition details: `docs/refactoring/completed-phases.md`

**UI Composables:**
- `src/composables/ui/useSidebarResizer.js` — desktop sidebar resize logic
- `src/composables/ui/useSheetGestures.js` — sheet gesture handling
- `src/composables/chat/useSelectionAutoScroll.js` — mobile text selection auto-scroll near viewport edges, uses `isProgrammaticScrolling` guard to avoid `pointer-events: none` on messages during scroll

---

## 7. Cloud Sync

### Files
- `src/components/sheets/SyncSheet.vue` — UI for provider auth, encryption setup, push/pull, and conflict entry points
- `src/core/services/syncService.js` — high-level sync orchestration and readiness checks
- `src/core/services/syncEngine.js` — manifest diffing, entity serialization, encryption-aware upload/download
- `src/core/services/adapters/dropboxAdapter.js` — Dropbox OAuth + file operations
- `src/core/services/adapters/gdriveAdapter.js` — Google Drive OAuth + file operations
- `src/core/services/crypto/syncCrypto.js` — AES-GCM payload encryption
- `src/core/services/crypto/keyManager.js` — recovery phrase generation/restoration and key persistence
- `src/core/states/syncState.js` — provider, tokens, progress, auto-sync, conflict state
- `src/core/config/syncConfig.js` — build-time provider availability based on env keys
- `public/oauth/dropbox/redirect.html` — web popup callback bridge for Dropbox OAuth
- `public/oauth/gdrive/redirect.html` — web popup callback bridge for Google Drive OAuth

### Structure

**Ownership Model:**
- Maintainer configures OAuth app credentials in `.env`
- End users authenticate into their own Dropbox / Google Drive accounts
- Synced files are stored inside the authenticated user's own cloud under `/Glaze`
- The app never routes all users into one shared maintainer-owned storage account

**Provider Availability:**
- `syncConfig.js` exposes whether Dropbox or Google Drive auth can be started in the current build
- SyncSheet only shows provider buttons that have the required env key configured
- Existing sync state remains local; provider availability only controls whether a new OAuth sign-in can be initiated

**OAuth Flow:**
1. User taps Dropbox or Google Drive in `SyncSheet.vue`
2. Adapter builds provider-specific OAuth URL with PKCE + `state`
3. Browser/popup returns `code` to redirect HTML, Electron loopback callback, or native deep link
4. Adapter exchanges `code` for tokens and stores them in IndexedDB via `SYNC_TOKENS_KEY`
5. Future API calls reuse the stored access token and refresh when supported by the provider

**Platform Callback Paths:**
- Web: provider redirects to `public/oauth/*/redirect.html`, which posts the auth code back to the opener window
- Electron (Windows/Linux desktop): provider redirects to `http://127.0.0.1:PORT/oauth/callback`; `electron-main.cjs` captures the code through a temporary local server
- Android: provider redirects to `com.hydall.glaze://...`; `AndroidManifest.xml` declares a `VIEW` / `BROWSABLE` intent-filter so Capacitor `appUrlOpen` can receive it
- iPhone: provider redirects to `com.hydall.glaze://...`; `Info.plist` registers the URL scheme and `AppDelegate.swift` forwards it to Capacitor

**Data Flow:**
1. `syncService.js` picks adapter from `syncProvider`
2. `detectEncryptionState()` checks whether a local sync key exists
3. `pushEntities()` / `pullEntities()` compare local vs cloud manifest
4. Entity payloads are serialized per type, optionally encrypted, then uploaded to cloud paths under `/Glaze`
5. Pull emits conflicts when both local and remote changed since the previous sync baseline

**Encryption Model:**
- Encryption is optional and local-first
- Recovery phrase derives the AES-GCM key through `keyManager.js`
- Cloud never stores the recovery phrase or decrypted key material
- Without encryption, cloud payloads are plain JSON for easier debugging and portability

**Storage Boundaries:**
- OAuth tokens: IndexedDB `keyvalue` store via `SYNC_TOKENS_KEY`
- Sync settings and selected provider: `localStorage` (`gz_sync_settings`)
- Encryption key material: IndexedDB via `keyManager.js`
- Device identity and sync metadata: local storage + IndexedDB manifest state

**Synced Singleton Coverage:**
- Characters, personas, chats: full IndexedDB stores
- Lorebooks: single IndexedDB blob (`gz_lorebooks`)
- API connection presets: single IndexedDB blob (`gz_api_connection_presets`)
- Theme presets: single IndexedDB blob (`gz_theme_presets`)
- Theme active preset: single IndexedDB blob (`gz_theme_active_preset`) via `theme_state` entity
- App / API runtime settings: selected `localStorage` keys bundled under the `local_storage` entity
  - Includes: prompt presets, active preset IDs, persona connections, regex scripts, language, theme/layout toggles, battery saver, API provider/endpoint/model, temperature, stream, reasoning settings, timeouts
  - Also includes API key and model key (users should be aware credentials travel with this bundle)
- Not synced: active generation state, temporary UI state, push-notification tokens, debug network traces, embedding vectors

**Wipe Semantics:**
- `wipeCloudData()` deletes every file found under `/Glaze` via the provider adapter (`listAllFiles` + `deleteFile`).
- `resetSyncIdentityAfterWipe()` clears the local sync encryption key, manifest, deleted-entries registry, and device ID.
- After a wipe the cloud is effectively empty; the next `push` creates a fresh manifest and repopulates `/Glaze`.

---

## Key Integration Points

### Tokenizer ↔ Vectorization
- `generationWorker.js:sourceKeys` includes `vectorLore`
- `generationService.js` runs vector search for tokenizer display
- Tokenizer shows vector lorebook tokens inside reserve zone

### Vectorization ↔ MemoryBooks
- Memory entries use same `sourceType: 'memory_entry'` in embeddings
- `lorebookState.js` reactive state owns lorebook data, settings, activations; `lorebookSearchService.js` owns keyword scan; `lorebookVectorSearch.js` owns vector search; `lorebookEmbeddingService.js` owns embedding orchestration
- Reindex shared via `reindexMemoryEntry()`

### MemoryBooks ↔ Generation
- `generationService.js` calls `retrieveMemoryEntries()`
- Memory injected as separate context block
- Triggered memories tracked in `msg.triggeredMemories[]`

### Hidden Messages ↔ Context
- `ChatView.vue` supports bulk restore via `unhideAllMessages()`
- Hidden/unhidden messages trigger `updateContextCutoff()` so tokenizer and prompt window stay in sync

### Cloud Sync ↔ Local Data
- `syncEngine.js` serializes characters, personas, chats, presets, and selected local storage state
- Pull publishes `APP_EVENTS.domain.sync.dataRefreshed` via event hub

### Cloud Sync ↔ Encryption
- `syncService.js` decides whether to request a sync key based on `detectEncryptionState()`
- `syncEngine.js` switches file extension and payload format between `.json` and `.enc`

### Cloud Sync ↔ Build Config
- `syncConfig.js` turns env keys into feature availability for provider sign-in
- Maintainer setup affects which provider buttons are visible, not which user cloud account is used after login

### Cloud Sync ↔ Platform Shells
- `electron-main.cjs` handles desktop OAuth loopback callback transport
- `AndroidManifest.xml` and iOS `Info.plist` define the app-owned deep link scheme expected by the native adapters

### Macros ↔ Generation
- `generationService.js` calls `replaceMacros()` on all prompt parts
- Session vars loaded from `localStorage` and saved back if changed
- Global vars persist across all chats

### API Settings ↔ Network Requests
- `ApiView.vue` edits runtime request settings and connection presets
- `APISettings.js` normalizes endpoints and serves as the current read boundary for generation requests
- `ChatView.vue`, `generationService.js`, and the transport layer still depend on those settings directly or indirectly during request setup

### Prompt Preview ↔ Network Trace
- `generationService.js:getLastPrompt()` stores the last built request body before transport sanitization is sent
- `networkDebugService.js` publishes debug events via event hub during transport execution
- `debugStateProjection.js` subscribes to those events and routes them to `requestTraceState.js` and `promptPreviewState.js` (both keyed by `debugKey`)
- `requestPreviewState.js` joins prompt preview + request trace for UI consumption
- `RequestPreviewSheet.vue` combines both views, now per-generation instead of global singleton

---

## Database Layer

### Files
- `src/utils/db.js` — IndexedDB wrapper with write queue and patchChatData

### Write Queue (`queueDbWrite`)

All IDB writes are serialized through a global promise chain (`_dbWriteQueue`). Each write waits for the previous one to complete before starting. This prevents concurrent writes from interleaving.

### `patchChatData` (read-mutate-write)

Atomically reads chat data, applies mutations, normalizes, and writes back — all inside one queued operation:

```js
await db.patchChatData(charId, (data) => {
    data.sessions[sessionId] = newMessages;
});
```

- Reads fresh data from IDB (no stale snapshots)
- Mutations are synchronous (no async work inside callback)
- `normalizeChatData` + `toPlain` applied before write
- localStorage fallback on write failure
- **Never** do `getChatData` + mutate + `saveChat` — this is a race condition

### `patchChatDataBatch` (planned)

Extends `patchChatData` to accept multiple mutation functions in a single read-mutate-write cycle. Eliminates redundant reads and gaps between sequential patches.

### `saveChat` (full replacement)

Used only for:
- Creating new chat data from scratch
- Resetting chat to empty state
- Cloud sync (data from server)
- Chat importer (new data)
- DB internals (recursive calls inside `patchChatData`/`saveChat`)

### Crash Recovery Buffer

`useSessionPersistence.js` writes a crash buffer to `localStorage` on `visibilitychange`, `pagehide`, and `beforeunload`. Covers: messages, draft, authorsNote, summary, scrollAnchor. Does NOT cover: memory books, session management, character metadata.

---

## Settings Ownership

| Setting | Owner | Location |
|---------|-------|----------|
| Embedding endpoint/key/model | API | `embeddingSettings.js` → localStorage |
| Embedding enabled toggle | API | `embeddingSettings.js` → localStorage |
| Max chunk tokens | API | `embeddingSettings.js` → localStorage |
| Search type (keys/vector/both) | Lorebook | `lorebookState.globalSettings` |
| Scan depth | Lorebook | `lorebookState.globalSettings` |
| Vector threshold | Lorebook | `lorebookState.globalSettings` |
| Vector top K | Lorebook | `lorebookState.globalSettings` |
| Embedding target (content/keys) | Lorebook | `lorebookState.globalSettings` |
| Memory search type | MemoryBook session | `memoryBook.settings.vectorSearchEnabled` + `keyMatchMode` |
| Dropbox OAuth app key | Build config | `.env` → `syncConfig.js` |
| Google Drive OAuth client ID | Build config | `.env` → `syncConfig.js` |
| Connected sync provider | Sync state | `syncState.js` → localStorage |
| Sync OAuth tokens | Sync state | IndexedDB via `SYNC_TOKENS_KEY` |
| Recovery phrase-derived key | Crypto | IndexedDB via `keyManager.js` |
| API endpoint/key/model | API runtime config | `APISettings.js` ↔ localStorage |
| API stream/temp/topP/max tokens/context | API runtime config | `APISettings.js` ↔ localStorage |
| Reasoning toggle/tags/effort | API runtime + preset override | `APISettings.js`, `PresetView.vue`, localStorage |
| API connection presets | API presets | IndexedDB `gz_api_connection_presets` |
| Last built prompt preview | Generation debug state | `generationService.js` singleton memory |
| Last network trace | Network debug state | `networkDebugService.js` ↔ localStorage |

---

Guard rails and deferred items have been moved to `docs/rules/vue-components.md` and `docs/rules/known-gaps.md`.

---

## Testing Checklist

### Tokenizer
- [ ] Context breakdown shows correct proportions
- [ ] Reserve zone contains lorebook entries
- [ ] Token count updates on message hide/delete

### Vectorization
- [ ] Entries index successfully with progress display
- [ ] Vector search returns relevant results
- [ ] Dual-channel: keyword + vector results merged (searchType='both')
- [ ] Vector-only mode works (searchType='vector')
- [ ] Keys-only mode works without vector overhead (searchType='keys')
- [ ] Force reindex rebuilds legacy single-vector entries

### MemoryBooks
- [ ] Scan Chat creates planned segments
- [ ] Batch Generate creates drafts sequentially
- [ ] Approved memories show MEM badge
- [ ] Auto-creation respects delayed mode
- [ ] Delete/branch marks entries stale
- [ ] Memory injection skips entries whose message range is still inside current prompt context
- [ ] Memory search type dropdown updates retrieval mode correctly

### Macros
- [ ] SillyTavern variables (setvar/getvar) persist per session
- [ ] Global variables (setglobalvar/getglobalvar) persist across sessions
- [ ] Lucid Loom macros resolve from global vars
- [ ] Datetime macros return current values
- [ ] Comments are stripped from output

### Reasoning
- [ ] User reasoning toggle works regardless of preset
- [ ] Inline reasoning tags extracted from content
- [ ] Native reasoning_content field displayed
- [ ] Both sources combined without duplication
- [ ] Mobile/native stream fallback returns a full response instead of hard-failing when streaming body is unavailable

### Network / LLM Requests
- [ ] Chat requests succeed in both streaming and non-streaming modes
- [ ] Native non-stream requests still work through `CapacitorHttp`
- [ ] Missing stream reader fallback still produces a complete response
- [ ] User abort closes the TCP connection immediately (signal reaches `fetch()`)
- [ ] Abort during streaming stops chunk reading immediately (readChunk abort listener)
- [ ] Native HTTP non-stream abort works through XHR (`executeAbortableJsonRequest`)
- [ ] User abort skips error toast and partial-content recovery
- [ ] Timeout abort still shows error toast
- [ ] Stale completions from previous generations do not mutate newer generation's typing state
- [ ] Summary and memory-draft requests do not regress while chat transport is refactored
- [ ] Request preview still shows the final built payload after prompt assembly
- [ ] Network trace capture remains optional and does not affect generation success
- [ ] Native/mobile generation remains responsive on lower-end devices during long streaming responses
- [ ] Native auto-sync does not start while active generation is still running
- [ ] Prompt metadata rollback still works after abort/error paths
- [ ] Late vector lore still respects `maxInjectedEntries` after transport/refactor changes
- [ ] Crash buffer recovery: messages survive browser crash/force-close during generation

### Cloud Sync
- [ ] Provider buttons only appear when their env keys are configured
- [ ] Dropbox auth signs user into that user's own Dropbox account
- [ ] Google Drive auth signs user into that user's own Google Drive account
- [ ] Push works with encryption disabled (`.json` payloads)
- [ ] Push/Pull works with encryption enabled (`.enc` payloads)
- [ ] Conflicts surface in `SyncSheet.vue` and can be resolved without data loss
