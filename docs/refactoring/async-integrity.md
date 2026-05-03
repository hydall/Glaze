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

**Status:** not started
**Priority:** high
**Scope:** new file `src/core/utils/asyncOperationScope.js`

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

**Status:** not started
**Priority:** high
**Depends on:** Task 1
**Scope:**
- `src/core/states/generationState.js` — replace manual controller orchestration
- `src/core/states/imageGenState.js` — same
- `src/views/ChatView.vue` — `onUnmounted` uses `scope.unsubscribe()`
- `src/composables/chat/useGenerationAbort.js` — `abortGeneration` uses `scope.abort()`

### What

Replace ad-hoc `AbortController` + `generationStates` Map with `AsyncOperationScope`.

Current `onUnmounted`:
```js
const state = getGenerationState(char.id);
if (state?.controller) state.controller.abort();
clearGenerationState(char.id);
```

After:
```js
scope.unsubscribe(char.id);
```

Stop button explicitly calls `scope.abort(char.id)`.

### Why

Current code conflates "the UI is no longer interested" and "the operation should stop." They are different. The operation should only stop when the user explicitly asks, or when it naturally completes/errors.

### Risk

Medium — touches the hot path. Must verify: generation during character switch, background completion, explicit abort, image gen race.

---

## Task 3: `patchChatDataBatch` — multiple mutations in one read-mutate-write cycle

**Status:** not started
**Priority:** high
**Depends on:** none
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

**Status:** not started
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

**Status:** not started
**Priority:** medium
**Depends on:** none
**Scope:** new file `eslint-rules/glaze/no-getchatdata-savechat.js`

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

**Status:** not started
**Priority:** high
**Depends on:** none
**Scope:** `src/composables/chat/useMemorySheetUI.js` (872 lines)

### What

Rewrite the memory sheet UI from imperative DOM (`document.createElement` + `addEventListener`) to a proper Vue SFC component. The current composable is ~600 lines of DOM construction that cannot be tested, reused, or read.

Split into:
- `MemoryBooksSheet.vue` — main sheet (entry list, search, action buttons)
- `MemoryGenerationSettings.vue` — generation settings form
- `MemoryPromptManager.vue` — custom prompt CRUD
- `MemoryEntryEditor.vue` — entry key/content/weight editor
- `useMemoryState.js` (~150 lines) — reactive state only (currentMemoryBookData, pendingIds, draft progress)

### Why

Imperative DOM is the single biggest source of code volume in the memory composables. A Vue SFC with proper template, computed, and v-model bindings would be ~40% fewer lines, testable, and readable. The current pattern (createElement → querySelector → addEventListener → closeBottomSheet → setTimeout → reopen) is fragile and creates the open/close/reopen chains that make bugs hard to trace.

### Size estimate

| Current | After | Reduction |
|---------|-------|-----------|
| useMemorySheetUI.js: 872 | 4 Vue SFCs (~120-180 each) + useMemoryState.js (~150) | ~200 lines saved, but main gain is testability |

---

## Task 8: `useMemoryBooks` split — state vs. handlers

**Status:** not started
**Priority:** medium
**Depends on:** Task 7
**Scope:** `src/composables/chat/useMemoryBooks.js` (806 lines)

### What

Split into focused composables by responsibility:

| New composable | Lines | Responsibility |
|---------------|-------|---------------|
| `useMemoryState.js` | ~150 | Reactive state (currentMemoryBookData, pendingIds, draft progress) — shared by all memory composables |
| `useMemoryCRUD.js` | ~200 | Entry create, edit, delete, reorder, scan/approve/reject drafts |
| `useMemoryVectorOps.js` | ~150 | Vector toggle, reindex, search type switch |
| `useMemorySheetOrchestrator.js` | ~250 | Sheet open/close, load/reload, UI coordination |

The reactive state composable is extracted first (it's already loosely defined by the ref declarations at the top of useMemoryBooks). The other three split by operation domain.

### Why

`useMemoryBooks` currently mixes reactive state management, CRUD operations, vector operations, and sheet orchestration in one function. A change to vector toggle logic requires understanding 800 lines. After split, each composable is <250 lines and has a clear single responsibility.

### Risk

Low — purely structural. No behavior changes. The main risk is prop-drilling between the split composables, which is mitigated by the shared `useMemoryState` composable.

---

## Task 9: `useMemoryAutomation` — extract orchestration from business logic

**Status:** not started
**Priority:** medium
**Depends on:** Task 8
**Scope:** `src/composables/chat/useMemoryAutomation.js` (703 lines)

### What

Split into:

| New composable | Lines | Responsibility |
|---------------|-------|---------------|
| `useMemoryDraftGeneration.js` | ~250 | Generate draft text, batch generation, single draft, cancel |
| `useMemoryAutoCreate.js` | ~200 | Stable-turn detection, trigger resolution, bootstrap, interval logic |
| `useMemoryQuickActions.js` | ~150 | Quick model change, prompt preset shortcuts |

The automation orchestration (when to trigger, what to do) stays in `useMemoryAutomation` but becomes a thin coordinator (~150 lines) that delegates to the three new composables.

### Why

Currently, draft generation, auto-create triggers, and quick model changes are all interleaved. The `runMemoryAutomationAfterStableTurn` function alone is ~180 lines with deeply nested conditionals. Splitting makes each concern independently testable and editable.

---

## Task 10: `useVirtualScroll` encapsulation audit

**Status:** not started
**Priority:** low
**Depends on:** none
**Scope:** `src/composables/chat/useVirtualScroll.js` (716 lines)

### What

`useVirtualScroll` is 716 lines but is self-contained — it manages DOM recycling, scroll anchoring, and item measurement. It doesn't leak concerns into other composables.

Audit for:
1. Any business logic that should be in a service (currently none found)
2. Dead code from scroll strategies that were tried and abandoned
3. Opportunities to extract a generic `useVirtualScroll` utility (currently chat-specific)

If the audit finds no issues, leave as-is. 716 lines of isolated, well-scoped code is acceptable. The guard rail exists to prevent god-objects, not to enforce arbitrary line counts.

---

## Current composable size audit (May 2026)

| Composable | Lines | Status |
|-----------|-------|--------|
| useMemorySheetUI | 872 | **Over limit** — Task 7 |
| useMemoryBooks | 806 | **Over limit** — Task 8 |
| useVirtualScroll | 716 | Self-contained — Task 10 audit |
| useMemoryAutomation | 703 | **Over limit** — Task 9 |
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
Task 1 (AsyncOperationScope)
  └── Task 2 (Refactor generation/imageGen state)

Task 3 (patchChatDataBatch) — independent

Task 4 (Lifecycle save durability) — depends on Task 3

Task 5 (ESLint rule) — independent

Task 6 (Cloud sync refactor) — independent, lowest priority

Task 7 (Memory Sheet → Vue SFC) — independent
  └── Task 8 (useMemoryBooks split) — depends on Task 7
       └── Task 9 (useMemoryAutomation split) — depends on Task 8

Task 10 (useVirtualScroll audit) — independent
```

Recommended order:
1. Task 5 — quick win, prevents regression
2. Task 3 — `patchChatDataBatch`, unblocks Task 4
3. Task 7 — Memory Sheet Vue SFC, highest ROI composable fix
4. Task 1 — `AsyncOperationScope`, unblocks Task 2
5. Task 8 — `useMemoryBooks` split, needs Task 7 first
6. Task 4 — Lifecycle save durability, needs Task 3
7. Task 2 — Refactor generation state, needs Task 1
8. Task 9 — `useMemoryAutomation` split, needs Task 8
9. Task 10 — `useVirtualScroll` audit, whenever convenient
10. Task 6 — Cloud sync, whenever convenient
