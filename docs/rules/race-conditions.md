# Race Condition Prevention Rules

Every feature or fix that touches async boundaries, generation state, or the DB must satisfy these rules before commit.

---

## Rule 1: Every `await` is a checkpoint

After any `await`, verify you still own the state:

```dart
final result = await someAsyncWork();

// Check 1: not aborted
if (cancelToken.isCancelled) return;

// Check 2: same generation (if inside generation callback)
if (currentGenId != expectedGenId) return;

// Check 3: same session (if session-scoped)
if (currentSessionId != expectedSessionId) return;
```

Missing any of these checks means a stale completion from an aborted generation can
silently corrupt state.

---

## Rule 2: No state mutation without ownership

- SSE callbacks (`onDelta`, `onComplete`, `onError`) **must** check `_activeGenId` before
  mutating `ChatState` or persisting to DB.
- Image generation callbacks (`retryImageGeneration`, `retryImageGenerationForMessage`)
  currently do NOT have a `genId` guard — potential stale state write.
- New services that receive async results and write to state must include a
  staleness/ownership check. Without it, late completions **will** corrupt state.

---

## Rule 3: Atomic read-mutate-write for DB

Never:
```dart
final session = await chatRepo.getById(charId);
session.messages.add(msg);
await chatRepo.put(session); // RACE: another write may have happened
```

Always use a Drift `transaction()` or a dedicated repo method that wraps the
read-mutate-write atomically. See `docs/rules/database.md`.

---

## Rule 4: New async boundaries need stale guards

When adding a composable, service, or callback that:
- Receives results from an HTTP request or isolate
- Mutates Riverpod state
- Writes to the DB

…it **must** include a staleness check before the mutation.
Rule of thumb: if there's an `await` before the mutation, there's a potential race.

---

## Rule 5: Mutual exclusion for concurrent operations

- Chat generation and memory draft generation **are** mutually exclusive for the same session/character:
  - `MemoryBookController.generateDraft()` rejects when `chatProvider(charId).isGenerating`.
  - `sendMessage` / `regenerateLastAssistant` / `continueMessage` reject when
    `memoryActiveDraftsProvider` contains the session id.
  - `glaze.triggerGeneration` reuses `GenerationDispatcher`, which enforces the same
    mutex (INV-JS3). The dispatcher returns `TriggerBusy` instead of auto-aborting.
- Image generation runs only after text generation completes (enforced by call order).
- Background operations (auto-sync, embedding indexing) should check `isGenerating`
  for the relevant `charId` before starting.
- The periodic JS scheduler runs only when the app is `resumed`
  (`PeriodicTriggerScheduler` is a `WidgetsBindingObserver`); it does NOT
  contend with chat generation but the `jsRunner` ticks share
  `SseClient` with chat — keep heavy ticks ≤ 1 per preset at a time.

If adding a new request type alongside chat generation, add mutual exclusion guards
in **both** directions.

---

## Rule 6: CancelToken must reach the HTTP layer

When the user taps Stop, `abortGeneration()` calls `_cancelToken?.cancel()` and
`_imgGenCancelToken?.cancel()`, both of which must propagate to Dio.
Cancelling only UI state (`isGenerating = false`) while the TCP connection stays open
is a bug — the stream continues running in the background and may write stale results.

Verify: after pressing Stop, the network tab shows the request was actually terminated.

---

## Known race classes

| Race | Cause | Fix / Status |
|------|-------|-------------|
| Stale completion writes to new generation's state | Callback didn't check `_activeGenId` | Guard exists in `ChatGenerationService` callbacks via `isAborted()` |
| Stop button doesn't close TCP connection | `CancelToken` not passed to `Dio` | Ensure `CancelToken` reaches `SseClient` |
| Read-mutate-write in DB | `getById` + `put` without transaction | Wrap in `db.transaction()`; JS `chat` / `character` / `global` variable writes go through dedicated repo methods (see `docs/rules/database.md`) |
| Two memory drafts start for same draft ID | No in-flight ID tracking in generator | Tracked in widget: `memory_books_sheet.dart._generatingDrafts` map |
| `apiListProvider` null on cold start | Sync provider read before async load | `await ref.read(apiListProvider.future)` first; also used by `MemoryDraftGenerator` |
| Image retry state corruption | `retryImageGeneration` callbacks have no `genId` guard | ⚠️ Unfixed — potential stale write to `ChatState` |
| Chat ↔ memory draft mutual exclusion | Neither side checks the other | ✅ **Fixed** — `memory_active_drafts_provider` enforces mutex in both directions; `glaze.triggerGeneration` reuses the same mutex via `GenerationDispatcher` (INV-M3, INV-M4, INV-JS3) |
| Character deletion orphan rows | `CharactersNotifier.remove()` previously called `chatRepo.deleteByCharacterId` (only deleted `ChatSessions`) before `CharacterRepo.delete`, missing per-session tables | ✅ **Fixed** — `deleteByCharacterId` now deletes `MemoryBookRows` + `ChatSummaries` + `ChatSessions` in correct order. See `docs/rules/database.md`. |
| `glaze.triggerGeneration` racing chat generation | JS call while chat is generating | ✅ **Fixed** — `GenerationDispatcher.dispatch` returns `TriggerBusy` when `isGenerating` or `memoryActiveDrafts` is set (INV-JS3). |
| Stale periodic ticks after app background | `Timer.periodic` keeps firing while app is paused | ✅ **Fixed** — `PeriodicTriggerScheduler` pauses on `paused`/`inactive`/`hidden`/`detached` (INV-JS6). No catch-up tick on resume. |
| Rapid session switch — stale switch overwrites newer one | `ChatSessionController.switchSession` has no epoch/switchId guard; two concurrent calls race, last `_setState` wins | ✅ **Fixed** — `_switchEpoch` counter in `ChatSessionController`; after each `await`, stale-epoch operations bail out without calling `_setState`. Covers `switchSession`, `createNewSession`, `branchSession`. Tests in `test/characterization/session_switch_race_test.dart` |
| `_applySessionPreference` — no cancellation of in-flight switch | `didUpdateWidget` resets `_sessionApplied` and starts a new `_applySessionPreference` without cancelling the old one; shared `_sessionSwitchPending` flag cleared prematurely | ✅ **Fixed** — `_applyEpoch` counter in `_ChatScreenState`; only the latest apply clears `_sessionSwitchPending` in its `finally` block |
| `saveCurrentSessionIndex` fire-and-forget loses race with `findExistingSession` | `saveCurrentSessionIndex` is `void` (not `Future<void>`) — `() async { ... }()` is unawaited; `findExistingSession` reads stale `currentSessionIndex` from DB before the write completes | ✅ **Fixed** — `saveCurrentSessionIndex` now returns `Future<void>`; `switchToSession`, `createNewSession`, and `branchSession` all `await` it before returning |
| `ChatSessionService` static cache divergence | `switchToSession` reads from cache, `findExistingSession` reads from DB; `chatRepo.put` without `ChatSessionService.updateCache` leaves stale cache entries | ✅ **Fixed** — all 8 internal `chatRepo.put` call sites now call `ChatSessionService.updateCache`. External paths (sync pull, import) must also call `clearCache` or `updateCache` |
| Catalog provider switch during a load shows the previous provider | `CatalogNotifier.search` bailed out on `state.loading`, so the reset-search from `setProvider` was dropped and the in-flight provider's page landed under the new provider's label | ✅ **Fixed** — `_searchEpoch` in `CatalogNotifier`: a reset-search always supersedes an in-flight fetch, and a stale completion (result *or* error) is discarded after the `await`. `setProvider` also compares against `_requestedProvider` so the last of two rapid picks wins. Tests in `test/catalog_provider_switch_race_test.dart` |
| Read message shows an unread dot in the chat list | Three gaps: (1) `UnreadSessionsNotifier._load` merged the persisted set over sessions already marked read during hydration; (2) `SyncNotificationStage` / `continueMessage` checked `isActiveSession` *after* awaiting `onGenerationCompleted`, so leaving the chat during that await flagged a reply the user had just watched land; (3) `isActiveSession` is false while the app is backgrounded, and returning to the still-open chat never cleared the dot | ✅ **Fixed** — `_readBeforeHydration` set filters (and re-persists) the loaded ids; both writers snapshot `isActiveSession` before the await and require both checks to agree; `SessionLifecycleTracker` re-syncs on `AppLifecycleState.resumed`. Tests in `test/unread_sessions_hydration_test.dart` |
| `ref.invalidate(chatProvider)` mid-switch | Invalidating `chatProvider(charId)` during a switch re-runs `build()` → `findExistingSession`, which reads stale `currentSessionIndex`; the in-flight `switchSession._setState` may be overwritten by the rebuild | ✅ **Mitigated** — `saveCurrentSessionIndex` is now awaited, so `findExistingSession` reads the correct index. The in-flight `switchSession` is also guarded by `_ref.mounted`. The `_buildComplete` flag in `build()` remains fragile but the primary race path is closed |
