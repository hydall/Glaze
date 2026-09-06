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
- Image generation/recovery callbacks use an operation generation ID and
  targeted `ChatRepo.mutateMessage`; stale operations cannot publish or replace
  a newer message/session snapshot.
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

Always use a dedicated repository mutation method that reads the latest row
inside its Drift transaction. Do not move `get -> copyWith -> put` into a
service-owned transaction. See `docs/rules/database.md`.

---

## Rule 4: New async boundaries need stale guards

When adding a composable, service, or callback that:
- Receives results from an HTTP request or isolate
- Mutates Riverpod state
- Writes to the DB

…it **must** include a staleness check before the mutation.
Rule of thumb: if there's an `await` before the mutation, there's a potential race.

---

## Rule 5: Isolate concurrent operation ownership

- Chat generation and memory draft generation may overlap for the same session.
- Each operation must retain independent transport callbacks, response state,
  cancellation ownership, staleness checks, and targeted persistence.
- `memoryActiveDraftsProvider` prevents conflicting memory workflows; it is not
  a chat mutex. Duplicate generation of one draft remains prohibited.
- Image generation runs only after text generation completes (enforced by call order).
- Background operations (auto-sync, embedding indexing) should check `isGenerating`
  for the relevant `charId` before starting.
- The periodic JS scheduler runs only when the app is `resumed`
  (`PeriodicTriggerScheduler` is a `WidgetsBindingObserver`); it does NOT
  contend with chat generation but the `jsRunner` ticks share
  `SseClient` with chat — keep heavy ticks ≤ 1 per preset at a time.

If adding a new request type alongside chat generation, serialize only a
concrete shared mutable owner or resource. Otherwise test concurrent completion
and cancellation in both orders.

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
| Read-mutate-write in DB | A previously read full row is written after another mutation | Use the narrowest repository mutation API; publish only its durable return (see `docs/rules/database.md`) |
| Two memory drafts start for same draft ID | No in-flight ID tracking in generator | Tracked in widget: `memory_books_tab.dart._generatingDrafts` map |
| `apiListProvider` null on cold start | Sync provider read before async load | `await ref.read(apiListProvider.future)` first; also used by `MemoryDraftGenerator` |
| Image retry state corruption | A late retry could overwrite newer chat state | ✅ **Fixed** — operation generation IDs plus targeted `mutateMessage` and durable-state publication |
| Chat ↔ memory draft output isolation | Concurrent requests could be routed or persisted into the wrong owner | ✅ **Covered** — independent ownership and targeted persistence; production concurrency markers in `memory_chat_concurrency_test.dart` (INV-M3, INV-M4) |
| Character deletion orphan rows | Independent provider-level deletion lists missed newer session tables | ✅ **Fixed** — `SessionDeletionQueries` is the shared complete session cascade; `CharacterDeletionRepo` composes it atomically with character lorebooks, folders, rows, and variation promotion. |
| `glaze.triggerGeneration` racing chat generation | JS call while chat is generating | ✅ **Fixed** — `GenerationDispatcher.dispatch` returns `TriggerBusy` for active chat generation; memory generation may overlap (INV-JS3). |
| Stale periodic ticks after app background | `Timer.periodic` keeps firing while app is paused | ✅ **Fixed** — `PeriodicTriggerScheduler` pauses on `paused`/`inactive`/`hidden`/`detached` (INV-JS6). No catch-up tick on resume. |
| Rapid session switch — stale switch overwrites newer one | `ChatSessionController.switchSession` has no epoch/switchId guard; two concurrent calls race, last `_setState` wins | ✅ **Fixed** — `_switchEpoch` counter in `ChatSessionController`; after each `await`, stale-epoch operations bail out without calling `_setState`. Covers `switchSession`, `createNewSession`, `branchSession`. Tests in `test/characterization/session_switch_race_test.dart` |
| `_applySessionPreference` — no cancellation of in-flight switch | `didUpdateWidget` resets `_sessionApplied` and starts a new `_applySessionPreference` without cancelling the old one; shared `_sessionSwitchPending` flag cleared prematurely | ✅ **Fixed** — `_applyEpoch` counter in `_ChatScreenState`; only the latest apply clears `_sessionSwitchPending` in its `finally` block |
| `saveCurrentSessionIndex` fire-and-forget loses race with `findExistingSession` | `saveCurrentSessionIndex` is `void` (not `Future<void>`) — `() async { ... }()` is unawaited; `findExistingSession` reads stale `currentSessionIndex` from DB before the write completes | ✅ **Fixed** — `saveCurrentSessionIndex` now returns `Future<void>`; `switchToSession`, `createNewSession`, and `branchSession` all `await` it before returning |
| `ChatSessionService` static cache divergence | Cache was updated from optimistic or stale pre-write snapshots | ✅ **Fixed rule** — cache publication is post-commit: publish only a repository's durable returned/reloaded session; clear affected cache only after durable deletion. Sync/import full replacements must explicitly refresh or clear cache. |
| Catalog provider switch during a load shows the previous provider | `CatalogNotifier.search` bailed out on `state.loading`, so the reset-search from `setProvider` was dropped and the in-flight provider's page landed under the new provider's label | ✅ **Fixed** — `_searchEpoch` in `CatalogNotifier`: a reset-search always supersedes an in-flight fetch, and a stale completion (result *or* error) is discarded after the `await`. `setProvider` also compares against `_requestedProvider` so the last of two rapid picks wins. Tests in `test/catalog_provider_switch_race_test.dart` |
| Read message shows an unread dot in the chat list | Three gaps: (1) `UnreadSessionsNotifier._load` merged the persisted set over sessions already marked read during hydration; (2) `SyncNotificationStage` / `continueMessage` checked `isActiveSession` *after* awaiting `onGenerationCompleted`, so leaving the chat during that await flagged a reply the user had just watched land; (3) `isActiveSession` is false while the app is backgrounded, and returning to the still-open chat never cleared the dot | ✅ **Fixed** — `_readBeforeHydration` set filters (and re-persists) the loaded ids; both writers snapshot `isActiveSession` before the await and require both checks to agree; `SessionLifecycleTracker` re-syncs on `AppLifecycleState.resumed`. Tests in `test/unread_sessions_hydration_test.dart` |
| `ref.invalidate(chatProvider)` mid-switch | Invalidating `chatProvider(charId)` during a switch re-runs `build()` → `findExistingSession`, which reads stale `currentSessionIndex`; the in-flight `switchSession._setState` may be overwritten by the rebuild | ✅ **Mitigated** — `saveCurrentSessionIndex` is now awaited, so `findExistingSession` reads the correct index. The in-flight `switchSession` is also guarded by `_ref.mounted`. The `_buildComplete` flag in `build()` remains fragile but the primary race path is closed |
| Deleted messages come back on the next variation switch | `ChatMessageOpsController` published the shortened list optimistically and committed on its own `_deleteCommits` chain, while `ChatSwipeController` committed on a separate `_queue`. Both re-read the durable row inside their transaction, so a swipe that started before the delete's transaction landed read the pre-delete message list and wrote it straight back | ✅ **Fixed** — one `ChatSessionWriteQueue` per `ChatNotifier`, shared by both controllers (and by edit / move / hide / clear). A mutation enqueued after a delete only starts once that delete has committed, so it reads the post-delete list. Ordering alone is not enough in the other direction: a commit enqueued *before* the delete still returns a pre-delete row, so publication is claimed synchronously via `beginPublication()` and an older commit repaints only while `isCurrentPublication` still holds. Tests in `test/chat_session_write_queue_test.dart` |
| Variation switch lands a tap late | `changeSwipe` / `changeAgentSwipe` awaited the Drift transaction *and* a full session re-encode before publishing, so the counter and the bubble only moved once the write finished | ✅ **Fixed** — the switch is computed synchronously, published immediately (`_switchVariation`), then committed on the write queue; `_opSeq` keeps an older commit from republishing over a newer switch. The optimistic paint deliberately does not invalidate the chat list |
| New chat opens the chat you just deleted | Session ids are `${charId}_$index` and the freed index was handed straight to the next chat, so the new session inherited the deleted one's id — and a fire-and-forget `_prefetchAdjacent` could re-insert the deleted row into the static cache *after* `clearCache`, while `createNewSession` never published its own row | ✅ **Fixed** — `_cacheEpoch` in `ChatSessionService` drops prefetch results issued before an eviction; `createNewSession` / `createInitialSession` publish their durable row; `_nextSessionIndex` takes `currentSessionIndex` as a high-water mark so deleting the chat you are in does not free its index |
| Chat screen keeps serving a deleted session | `ChatHistoryNotifier.deleteSession` left `chatProvider(charId)` bound to the row it had just removed — only the magic drawer invalidated it, the chat list did not. The next write recreated the row (`commitDeleteMessages` ends in a full `ChatRepo.put`) | ✅ **Fixed** — `deleteSession` invalidates `chatProvider` for the owning character itself; `findExistingSession` picks the most recent survivor and repairs `currentSessionIndex` when the recorded one is gone |
| Chat WebView hangs after a delete | `_applySessionSwitch` awaited `_syncState.messageMutationPending` unbounded and outside its `try`/`finally`, and returned early without lowering the cover when the bridge was null. `_sessionSwitching` stuck true leaves the surface hidden behind the switch cover *and* wrapped in `IgnorePointer` — a chat that is blank and eats every tap | ✅ **Fixed** — the wait is bounded by `_kBridgeOpTimeout`, the whole switch body is inside the `try`/`finally`, and every exit routes through `_setSessionSwitching`, which is safe to call during the build phase |
