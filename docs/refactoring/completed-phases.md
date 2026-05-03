# Completed Refactor Phases

Phases 0–14 are done. This file records what was done, not what to do next.

## Phase 0 — Freeze invariants and safety rails

Defined generation invariants for chat, summary, and memory-draft flows. Defined request ownership, abort/regenerate, stream/non-stream parity, and prompt semantics invariants. Created `INVARIANTS.md` and `SMOKE_CHECKLIST.md`.

## Phase 1 — Event Layer Skeleton

Added `eventNames.js`, `eventHub.js`, `contracts.js`. 56 canonical events across 4 namespaces. All internal emitters use `publishAppEvent()`. Migrated ~40 dispatch + ~30 listener call sites off `window.dispatchEvent`.

## Phase 2 — Request Ownership Safety Slice

Generation state carries `ownerKey`, `requestToken`, `sessionId`, `type`. Stream/completion/error/abort validate ownership before mutating. Fixed `onUnmounted` leak (now calls `clearGenerationState`). Fixed stale completion path (uses `finalizeGenerationState`).

## Phase 3 — Use-Case Layer Extraction

Extracted generation orchestration from `ChatView.vue` into composables: `useChatGeneration`, `useMessageActions`, `useSessionManagement`, `useMemoryAutomation`, `useMessageSelection`, `useSwipeNavigation`, `useChatSearch`, `useContextBreakdown`, `useMemorySheetUI`, `useAutoSync`, `useChatMessageDisplay`. ChatView: ~5700 → 2995 lines.

## Phase 4 — Deterministic Pipeline Extraction

`PipelineContext` with step logging and abort checks. Named ordered steps in `chatPipelineSteps.js`. Extracted `executeImpersonationUseCase`, `useGenerationAbort`. Migrated app signaling to `publishAppEvent`/`subscribeAppEvent`.

## Phase 5 — Side Effects to Events and Projections

Prompt preview → keyed `promptPreviewState.js`. Request trace → keyed `requestTraceState.js`. Debug state flows through `debugStateProjection.js` instead of direct writes from orchestration. Compatibility facades removed.

## Phase 6 — Plugin/Extension API

`extensionRegistry.js` with 6 generation hooks, priority ordering, disposable registrations. Read-only vs mutating hooks formalized. Connected to real pipeline boundaries. `appExtensions.js` for app-start registration.

## Phase 7 — Compatibility Shim Removal

Removed legacy-compatible subscriptions from App.vue, DialogList.vue, CharacterList.vue, LorebookSheet.vue. Replaced sync refresh source with event hub. Deleted `getLastPrompt()`, `getLastNetworkTrace()`, `clearLastNetworkTrace()`, `legacyCompatibleSubscription.js`.

## Phase 8 — ChatView Decomposition

Extracted `useSessionManagement` (203), `useMessageActions` (194), `useChatGeneration` (152). ChatView: 3767 → 2995 lines. `openChat()` (~400 lines) deferred — too many dependencies for marginal ROI.

## Phase 9 — State Ownership Boundaries

Audited 14 state modules + 10 composables. Fixed violations: `bottomSheetState.isOpen` removed from pipeline code, `promptMetaSnapshots` eviction added, `generationStates` extracted to `generationState.js`, `autoSyncRunning`/`autoSyncCooldownUntil` extracted to `syncState.js`.

## Phase 10 — Compatibility Layer Reduction

Migrated all ~42 `window.dispatchEvent` calls to `publishAppEvent`. Migrated all ~30 `window.addEventListener` to `subscribeAppEvent`. Cancelable `app-back-navigation` migrated to `publishCancelableAppEvent`. `windowEventBridge` removed.

## Phase 11 — Use-Case Layer Re-architecture

Pipeline files moved to `src/core/llm/pipeline/`. Scope-creep files split (`chatLateEnrichment` → `vectorLoreInjection` + `memoryMessageInjection`, etc.). Naming fixes (`chatContextCalculation` → `contextCalculation`, etc.). Hollow entrypoints eliminated for `calculateContext`, `generateSummary`, `generateMemoryDraft`. `generationService.js`: 267 → 158 lines.

## Phase 12 — Transport Split

`llmApi.js` → `requestOrchestrator.js`. i18n extracted from transport. Dead `requestReasoning` param removed. Transport fully self-contained in `src/core/llm/transport/`.

## Phase 13 — Shell and Large Component Decomposition

| Component | Before | After | Extracted |
|-----------|--------|-------|-----------|
| App.vue | 1229 | 622 | 5 composables (navigation, editor, events, glossary, init) |
| PresetView.vue | 2080 | 279 | 11 composables (navigation, loader, CRUD, selectors, blocks, etc.) |
| lorebookState.js | 1319 | 326 | 3 services (search, vector, embedding) |
| ChatMessage.vue | 1985 | 1621 | 2 composables (swipe, imageGen) |
| ChatInput.vue | 1155 | 905 | 2 composables (contentEditable, inputActions) |
| LorebookSheet.vue | 725 | 290 | 2 composables (entries, indexing) |
| ApiView.vue | 645 | 140 | 2 composables (settings, providers) |
| CharacterList.vue | 585 | 175 | 2 composables (actions, sessions) |
| ThemeSettingsView.vue | 495 | 236 | 1 composable (presets) |

## Phase 14 — Final Legacy Cleanup

Deleted 7 dead re-export shims + dead `useViewer`. Removed `getLegacyApiConfig`/`getLegacyEmbeddingConfig`. Migrated `app-back-navigation` to `publishCancelableAppEvent`. Removed `windowEventBridge`.

## patchChatData Migration (2026-05-04)

Migrated all 40+ read-mutate-write patterns from `getChatData+saveChat` to `patchChatData` across 16 files. Remaining `saveChat` calls are legitimate full-replacement writes.
