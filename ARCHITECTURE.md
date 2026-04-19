# Architecture Audit — Tokenizer, Vectorization, MemoryBooks, Macros, Cloud Sync

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
- `src/core/states/lorebookState.js` — Vector indexing, search, and search settings
- `src/utils/db.js` — IndexedDB storage for embeddings
- `src/workers/generationWorker.js` — Dual-channel retrieval integration
- `src/core/services/generationService.js` — Vector search execution

### Structure

**Search Type System (`lorebookState.js`):**
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

**Lorebook State (`lorebookState.js`):**
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
- `src/views/ChatView.vue` — Primary implementation
- `src/core/services/generationService.js` — Memory injection during generation
- `src/core/states/lorebookState.js` — Vector search for memories
- `src/utils/db.js` — Chat persistence with memory books

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
- `src/core/services/llmApi.js` — Reasoning extraction from API response
- `src/core/services/generationService.js` — Reasoning settings resolution
- `src/views/ApiView.vue` — User-facing reasoning toggle
- `src/views/PresetView.vue` — Preset reasoning settings

### Logic

**Settings Resolution:**
1. User enables "Show Native Reasoning" in API settings → `requestReasoning = true`
2. Preset can override ONLY to enable (`reasoningEnabled: true`)
3. Preset `reasoningEnabled: false` does NOT disable user's choice
4. `reasoningEffort` — `'auto'` | `'low'` | `'medium'` | `'high'` (auto = not sent to API)

**Extraction (llmApi.js):**
1. `reasoning_content` field from API response → `finalReasoning`
2. Inline tags (`reasoningStart`...`reasoningEnd`) in content → `inlineReasoning`
3. Both combined and displayed to user
4. `hasInlineTags = !!tagStart && !!tagEnd` — requires non-empty tag config
5. Native/mobile fallback: if `response.body.getReader()` is unavailable, stream requests fall back to one-shot response parsing instead of failing

---

## 6. Cloud Sync

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

---

## Key Integration Points

### Tokenizer ↔ Vectorization
- `generationWorker.js:sourceKeys` includes `vectorLore`
- `generationService.js` runs vector search for tokenizer display
- Tokenizer shows vector lorebook tokens inside reserve zone

### Vectorization ↔ MemoryBooks
- Memory entries use same `sourceType: 'memory_entry'` in embeddings
- `lorebookState.js` handles both lorebook and memory vector operations
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
- Pull dispatches `sync-data-refreshed` so live UI can reload synced entities

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

### Cloud Sync
- [ ] Provider buttons only appear when their env keys are configured
- [ ] Dropbox auth signs user into that user's own Dropbox account
- [ ] Google Drive auth signs user into that user's own Google Drive account
- [ ] Push works with encryption disabled (`.json` payloads)
- [ ] Push/Pull works with encryption enabled (`.enc` payloads)
- [ ] Conflicts surface in `SyncSheet.vue` and can be resolved without data loss
