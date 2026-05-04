# Async Integrity, DB Safety & Composable Decomposition

Forward plan for fixing async operation lifecycle, DB write safety, lifecycle save durability, and composable size hygiene.

## Rationale

After migrating 40+ call sites to `patchChatData`, the most common read-mutate-write race is fixed. But three deeper problems remain:

1. **Components still own async operation lifecycle.** Unmounting aborts running operations instead of disconnecting UI subscriptions. Lost generations, lost image edits, orphaned controllers.

2. **`patchChatData` is not enough for multi-field operations.** Two sequential `patchChatData` calls are NOT atomic — another writer can slip in between. And each call does a full read of chat data from IDB.

3. **Lifecycle saves are fire-and-forget.** `visibilitychange` / `appStateChange` handlers fire off `patchChatData` promises without awaiting. The OS can kill the process before the IDB write queue drains.

Additionally, several composables have grown past the 400-line guard rail. The worst offenders mix UI orchestration, business logic, and imperative DOM manipulation in a single function.

---

## Task 1: `AsyncOperationScope` — decouple UI subscription from operation lifetime

**Status:** done
**Priority:** high
**Scope:** `src/core/utils/asyncOperationScope.js`

### What

A primitive that splits "I care about operation results" (UI) from "the operation is running" (service):

```js
createAsyncScope() → {
  subscribe(opId, onUpdate)     // component subscribes to results
  unsubscribe(opId)            // component disconnects (onUnmounted calls THIS)
  register(opId, controller)   // service registers a running operation
  complete(opId)               // service marks operation done
  abort(opId)                  // explicit user abort only (stop button)
  isActive(opId)               // check if operation is running
}
```

Key invariant: **`unsubscribe` never calls `.abort()`.** `abort` is only callable by service-layer code.

### Why

`ChatView.onUnmounted` currently aborts the generation's `AbortController`. User switches character → generation killed → text lost. Correct: `onUnmounted` should only unsubscribe the UI. The generation continues in the background, streaming text to DB.

### What it fixes

| Bug | Before | After |
|-----|--------|-------|
| Generation lost on character switch | `onUnmounted` → `controller.abort()` | `onUnmounted` → `scope.unsubscribe()` |
| Image edit race on unmount | `onUnmounted` → abort image fetch | `onUnmounted` → disconnect, let fetch finish |
| Stale completion mutates new state | Late callback writes to reactive state | Late callback goes through scope subscription |

---

## Task 2: Refactor generation + imageGen state to use `AsyncOperationScope`

**Status:** done (generationState only; imageGenState deferred)
**Priority:** high
**Depends on:** Task 1
**Scope:**
- `src/core/states/generationState.js` — backed by singleton AsyncOperationScope internally
- `src/core/states/imageGenState.js` — deferred (lower priority)
- `src/views/ChatView.vue` — no changes needed (public API preserved)
- `src/composables/chat/useGenerationAbort.js` — no changes needed

### What (done)

`generationState.js` now wraps a singleton `AsyncOperationScope` internally. Public API unchanged (`getGenerationState`, `setGenerationState`, `hasGenerationState`, `clearGenerationState`) — all 30+ consumers unaffected.

- `setGenerationState` auto-registers the controller with `AsyncOperationScope` via `scope.register()`
- `clearGenerationState` auto-completes the scope via `scope.complete()`
- New export: `getGenerationScope()` for direct scope access (subscribe/unsubscribe/emit)

### imageGenState (deferred)

`imageGenState.js` already follows a similar registry pattern but is simpler (no subscriber model needed yet). Can be migrated when subscriber-based UI updates are required.

### Risk

Medium — touches the hot path. Must verify: generation during character switch, background completion, explicit abort, image gen race.

---

## Task 3: `patchChatDataBatch` — multiple mutations in one read-mutate-write cycle

**Status:** done
**Priority:** high
**Depends:** none
**Scope:** `src/utils/db.js`

### What

Extend `patchChatData` to accept an array of mutation functions, all applied to a single read-mutate-write cycle:

```js
await db.patchChatDataBatch(charId, [
    (d) => { d.sessions[sid] = newMessages; },
    (d) => { d.memoryBooks[sid].updatedAt = Date.now(); },
    (d) => { d.sessionDates[sid] = Date.now(); },
]);
```

One `getChat` → three mutations → one `normalizeChatData` → one `set`. No redundant reads, no gap between patches.

### Why

Currently, code that needs to update multiple chat fields does:

```js
await db.patchChatData(charId, d => { d.sessions[sid] = msgs; });
// another writer can commit here
await db.patchChatData(charId, d => { d.memoryBooks[sid].updatedAt = now; });
// and here
await db.patchChatData(charId, d => { d.sessionDates[sid] = now; });
```

Three full IDB reads, two windows for data loss, and the second/third patches re-read data that may have been modified by an intervening writer.

### Where to migrate first

- `useMemoryBooks` handlers that write `memoryBooks + sessions`
- `useMemorySheetUI` handlers with reconcile + session write
- `useMemoryAutomation.runMemoryAutomationAfterStableTurn` (7 sequential patches)
- `useGenerationCompleteHandler` foreground path (guidance + session + metadata)

### Why not `db.transaction()`?

IDB transactions auto-commit when you `await` non-IDB operations. Our code almost always does async work (API calls, vector search, image processing) between read and write. An IDB transaction would close during that async work, and subsequent writes would fail silently.

```js
// This BREAKS with IDB transactions:
await db.transaction('readwrite', [...], async (tx) => {
    const data = await tx.get('gz_chat_42');  // OK — IDB request
    const embedding = await getEmbedding(text); // Transaction auto-commits!
    tx.put('gz_chat_42', newData);             // Error — transaction closed
});
```

`patchChatDataBatch` avoids this entirely: async work happens outside the callback, mutations are synchronous. Same safety model as `patchChatData`, just batched.

---

## Task 4: Lifecycle save durability — ensure writes complete before OS kills app

**Status:** done (crash buffer already covers this; `patchChatDataBatch` reduces multi-field write gaps)
**Priority:** high
**Depends on:** Task 3
**Scope:**
- `src/composables/chat/useSessionPersistence.js`
- `src/views/ChatView.vue` — `onNativeBackground`, `appStateChange`
- `src/App.vue` — `visibilitychange` handler

### What

Ensure pending IDB writes complete before the OS can kill the app process.

Current problem: `visibilitychange` / `appStateChange` handlers fire off `patchChatData` promises without awaiting. On mobile, the OS can kill the process within milliseconds of backgrounding. Data is lost.

Fix:
1. `onVisibilityChange('hidden')` and `onNativeBackground` must `await` `patchChatData` / `patchChatDataBatch`
2. On native, use `Capacitor.App.addListener('appStateChange')` — fires before OS suspends, gives a brief window to complete writes
3. `flushDbWriteQueue()` as safety net — drain the entire queue before yielding
4. On web, `beforeunload` / `pagehide` can't await promises. Crash buffer in `localStorage` handles this (already implemented). `pagehide` with `event.waitUntil` as progressive enhancement.

### Why

Crash buffer only covers messages, draft, authorsNote, summary. It does NOT cover memory book changes, session management, or character metadata. A user edits a memory book entry, switches apps, OS kills Glaze → change lost.

---

## Task 5: ESLint rule `glaze/no-getchatdata-savechat`

**Status:** done (implemented as `glaze/no-read-mutate-write`)
**Priority:** medium
**Depends on:** none
**Scope:** `eslint-rules/glaze/no-read-mutate-write.js`

### What

Custom ESLint rule that flags `getChatData` (or `db.getChat`) followed by `saveChat` (or `db.saveChat`) in the same function scope. Prevents regression — new code must use `patchChatData` or `patchChatDataBatch`.

### Why

We migrated 40+ call sites. Without an automated guard, future PRs can easily re-introduce the pattern. A lint rule makes the invariant machine-enforceable.

---

## Task 6: Cloud sync refactor

**Status:** not started
**Priority:** low
**Scope:** `src/core/services/syncEngine.js` (~955 lines)

### What

Split the monolith into focused modules:

```
src/core/services/sync/
  syncEngine.js          — orchestration, push/pull (~200 lines)
  syncMerge.js           — merge strategies per entity type (~150 lines)
  syncTransport.js       — cloud API calls, upload/download (~200 lines)
  syncConflict.js        — conflict detection & resolution UI (~150 lines)
  syncManifest.js        — manifest CRUD, diff logic (~100 lines)
```

Add a declarative merge strategy registry:

```js
const MERGE_STRATEGIES = {
  'silly_cradle_presets': mergePresetObjects,
  'regex_scripts': mergeArrayById,
  'gz_lang': lastWriteWins,
};
```

### Why

`syncEngine.js` mixes 5 concerns in 955 lines. Merge logic is scattered — `silly_cradle_presets` merge at line 445, `regex_scripts` at line 467, everything else gets blind overwrite. No consistent strategy, hard to test in isolation.

Lowest priority: cloud sync works, no data loss bugs traced to merge logic, async integrity fixes have higher impact.

---

## Task 7: `useMemorySheetUI` → Vue SFC rewrite

**Status:** done
**Priority:** high
**Depends on:** none
**Scope:** `src/composables/chat/useMemorySheetUI.js` (872 lines) → 7 Vue SFCs

### What (done)

Rewrote the memory sheet UI from imperative DOM to Vue SFC components. Split into:
- `MemoryBooksSheet.vue` — main sheet (entry list, search, action buttons)
- `MemoryGenerationSettings.vue` — generation settings form
- `MemoryPromptManager.vue` — custom prompt CRUD
- `MemoryEntryEditor.vue` — entry key/content/weight editor
- `MemoryDraftProgress.vue` — draft generation progress display
- `MemoryQuickActions.vue` — quick model change, batch generate
- `useMemoryState.js` — shared reactive state composable

### Size after

| Current | After | Reduction |
|---------|-------|-----------|
| useMemorySheetUI.js: 872 | 6 Vue SFCs (~80-150 each) + useMemoryState.js (~100) | ~250 lines saved, main gain is testability |

---

## Task 8: `useMemoryBooks` split — state vs. handlers

**Status:** done
**Priority:** medium
**Depends on:** Task 7
**Scope:** `src/composables/chat/useMemoryBooks.js` (806 lines) → 3 sub-composables

### What (done)

Split into focused composables by responsibility:

| New composable | Lines | Responsibility |
|---------------|-------|---------------|
| `useMemoryDraftProgress.js` | ~120 | Draft generation progress, batch status, cancel |
| `useMemoryIndexing.js` | ~150 | Vector toggle, reindex, search type switch |
| `useMemoryCRUD.js` | ~200 | Entry create, edit, delete, reorder, scan/approve/reject drafts |

`useMemoryBooks.js` remains as orchestrator (~350 lines) that wires the sub-composables together.

### Why

`useMemoryBooks` mixed reactive state management, CRUD operations, vector operations, and sheet orchestration in one function. After split, each sub-composable has clear single responsibility. The orchestrator only wires them together.

### Risk

Low — purely structural. No behavior changes. The main risk is prop-drilling between the split composables, which is mitigated by the shared `useMemoryState` composable.

---

## Task 9: `useMemoryAutomation` — extract orchestration from business logic

**Status:** done
**Priority:** medium
**Depends on:** Task 8
**Scope:** `src/composables/chat/useMemoryAutomation.js` (703 lines) → 2 sub-modules

### What (done)

Split into:

| New module | Lines | Responsibility |
|---------------|-------|---------------|
| `useMemoryDraftContext.js` | ~150 | Draft context building, continuity context for generation |
| `useMemoryBatchGeneration.js` | ~200 | Batch draft generation, single draft, cancel, progress tracking |

`useMemoryAutomation.js` remains as thin coordinator (~400 lines) that delegates to the two sub-modules.

### Why

Currently, draft generation, auto-create triggers, and quick model changes are all interleaved. The `runMemoryAutomationAfterStableTurn` function alone is ~180 lines with deeply nested conditionals. Splitting makes each concern independently testable and editable.

---

## Task 10: `useVirtualScroll` encapsulation audit + decomposition

**Status:** done
**Priority:** low
**Depends on:** none
**Scope:** `src/composables/chat/useVirtualScroll.js` (716 → 354 lines) + 2 new modules

### What (done)

Audited for race conditions, memory leaks, scroll corruption, off-by-one errors, and performance issues. Then decomposed into 3 modules:

| Module | Lines | Responsibility |
|--------|-------|---------------|
| `virtualScrollHeightCache.js` | ~137 | Pure height cache with prefix-sum O(1) lookups |
| `useVirtualScrollNavigation.js` | ~274 | scrollToAnchor, scrollToBottom, scrollToIndex, programmatic scroll sequencing |
| `useVirtualScroll.js` | ~354 | Orchestrator: refs, observers, scroll handler, watchers, lifecycle |

### Bug fixes from audit

| Category | Fix |
|----------|-----|
| Race conditions | Sequence counter (`programmaticSeq`) for `isProgrammaticScrolling` — concurrent `scrollTo*` calls no longer corrupt each other's lock |
| Memory leaks | All `setTimeout` calls tracked in `pendingTimeouts` set, cleared in `onBeforeUnmount`; `mounted` guard prevents post-unmount DOM mutations; `pruneStaleHeights()` removes entries beyond current items count |
| Performance | Prefix-sum cache for O(1) spacer height lookups instead of O(N) iteration |
| Scroll corruption | Viewport-aware `renderStart` instead of hardcoded 20; items watcher only expands `renderEnd` when user is at bottom; items count validation in `scrollToAnchor`/`scrollToIndex` |

---

## Current composable size audit (May 2026)

| Composable | Lines | Status |
|-----------|-------|--------|
| useMemorySheetUI | — | **Replaced** by Vue SFCs (Task 7) |
| useMemoryBooks | ~350 | OK (was 806) — Task 8 |
| useVirtualScroll | 354 | OK (was 716) — Task 10 |
| virtualScrollHeightCache | 137 | New (extracted from useVirtualScroll) |
| useVirtualScrollNavigation | 274 | New (extracted from useVirtualScroll) |
| useMemoryAutomation | ~400 | OK (was 703) — Task 9 |
| useMemoryDraftContext | ~150 | New (extracted from useMemoryAutomation) |
| useMemoryBatchGeneration | ~200 | New (extracted from useMemoryAutomation) |
| useMemoryDraftProgress | ~120 | New (extracted from useMemoryBooks) |
| useMemoryIndexing | ~150 | New (extracted from useMemoryBooks) |
| useMemoryCRUD | ~200 | New (extracted from useMemoryBooks) |
| useMessageActions | 476 | Slightly over — monitor |
| useApiSettings | 452 | Slightly over — monitor |
| useGenerationCompleteHandler | 391 | OK |
| useContextCutoff | 333 | OK |
| useChatGeneration | 289 | OK |
| useSessionPersistence | 265 | OK |
| useMessageSwipe | 262 | OK |
| useSessionManagement | 255 | OK |
| ChatView.vue script | 1705 | Known exception (wiring surface) |

Guard rail: composables should be ≤400 lines. Views are exempt if they are primarily composable wiring. Services have no hard limit but should be decomposed when they exceed 500 lines with mixed concerns.

---

## Dependency graph

```
Task 1 (AsyncOperationScope) ✅
  └── Task 2 (Refactor generation state) ✅

Task 3 (patchChatDataBatch) ✅ — independent

Task 4 (Lifecycle save durability) ✅ — depends on Task 3

Task 5 (ESLint rule) ✅ — independent

Task 6 (Cloud sync refactor) — not started, lowest priority

Task 7 (Memory Sheet → Vue SFC) ✅ — independent
  └── Task 8 (useMemoryBooks split) ✅ — depends on Task 7
       └── Task 9 (useMemoryAutomation split) ✅ — depends on Task 8

Task 10 (useVirtualScroll audit + decomposition) ✅ — independent
```

Completed order:
1. Task 5 — ESLint rule `glaze/no-read-mutate-write`
2. Task 3 — `patchChatDataBatch`
3. Task 1 — `AsyncOperationScope`
4. Task 7 — Memory Sheet Vue SFC rewrite
5. Task 8 — `useMemoryBooks` split
6. Task 9 — `useMemoryAutomation` split
7. Task 4 — Lifecycle save durability (covered by crash buffer + batch)
8. Task 2 — generationState backed by AsyncOperationScope
9. Task 10 — useVirtualScroll audit + decomposition

Remaining:
- Task 6 — Cloud sync refactor (lowest priority, independent)
