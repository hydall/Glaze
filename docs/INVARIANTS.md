# Generation Invariants — Glaze

Formal runtime behavior that must not change during any refactor.
Every structural PR must preserve these invariants or explicitly document a deviation.

---

## 1. Chat Generation Invariants

### INV-C1: At most one active chat generation per `charId`

`ChatNotifier.sendMessage()` checks `state.isGenerating` before starting.
If a generation is already active for this character, the call is rejected.

### INV-C2: Generation state is always eventually cleaned up

For every generation start, there must be a matching cleanup on every exit:
- Completion
- Error
- Abort (`abortGeneration()`)
- App restart (fresh `ChatState` with `isGenerating = false`)

Note: `ChatNotifier` uses `ref.keepAlive()`, so provider disposal is not a cleanup path. State resets on app restart when `build()` runs fresh.

### INV-C3: Partial text is preserved on abort

When the user aborts mid-stream and partial text exists, the partial response is
saved as a completed message, not discarded. `AbortHandler.abortGeneration()`
captures the stream and atomically mutates the latest durable session. Generation
remains blocked until persistence (or durable reload after a conflict/failure)
settles; cache and reactive session state never receive a speculative snapshot.

### INV-C4: `isGenerating` is consistent with actual generation activity

`ChatState.isGenerating == true` while the generation owns the character,
including durable abort finalization after the SSE request has been cancelled.
On app restart, `build()` creates a fresh `ChatState` where `isGenerating` defaults to `false`.

### INV-C5: Session variables are restored on abort/error ✅

If macro expansion mutates `sessionVars` during prompt build, those mutations
must **not** be persisted on any non-happy exit path. Only the successful
generation/continuation commit applies the `pendingSessionVars` delta returned
by the isolate.

`SavedMessageWriter` carries the generated result, but
`GenerationPipeline._commitGenerationResult` is the durable boundary: it merges
the generated delta into the latest row inside `ChatRepo.mutateSession`.
Continuation uses the same delta merge. Error, rollback, and abort paths do not
apply the generated delta.

`currentSessionVars` lives only inside the isolate's local scope during
`buildPrompt()` in `lib/core/llm/prompt_builder.dart`; nothing is persisted
before the success branch, so there is no variable rollback write. Non-success
paths reload or preserve the latest durable variables.

### INV-C6: Background generation continues independently

When generation is running for character A and the user switches to character B,
generation for A continues. `ChatNotifier` is keyed by `charId` — each character
has its own independent state. Switching screens does not abort other characters.

### INV-C7: Stale completions are discarded

If an SSE stream completes after a new generation has started (e.g. very fast regen),
the stale callback must detect the mismatch and discard the result.
Guard: `AbortHandler.isCurrentGen(genId)` — exposed to the stream as
`isAborted: () => !abortHandler.isCurrentGen(genId)` via `ChatGenerationService.generate()`
→ `StreamGenerationService.run()`. `AbortHandler.nextGenId()` increments `_activeGenId`
on abort and on each new generation start.

---

## 2. Image Generation Invariants

### INV-IG1: Image generation runs after text generation completes

`ImageTagStage` is scheduled by `PostGenCoordinator` only after the SSE stream
completes and the assistant message commit succeeds. With Studio disabled it
runs against that committed result. With Studio enabled it awaits
`CleanerStage`, reloads the canonical session from `ChatRepo`, and only then
processes image tags, so images bind to the selected final/cleaned/partial
swipe. It never runs concurrently with text generation. `continueMessage()`
uses the same pipeline and post-generation coordinator, bound to the merged
message — see INV-CM2. An errored stream returns before post-gen, and an abort
bumps `AbortHandler`'s gen id so every stage bails, so neither reaches the
image stage at all.

The WebView says the same thing. `ChatState.isGeneratingImage` is raised by
`ImageGenProcessor` before it dispatches the first block of a message and
dropped after the last — on the pipeline path and on every manual retry — and
it reaches the page through `bridge.setImageGenerating()`. A pending block is
rendered *queued* whenever that flag is down: no elapsed clock (nothing is
elapsing), no Stop button (there is no `_imgGenCancelToken` to cancel yet), and
a label that says so. That covers the whole reply stream and the post-gen work
before the image stage, which with Studio on runs the cleaner first and can
take seconds. The flip carries no re-render of its own — the reply's last chunk
is already painted — so `refreshImgGenPlaceholderState()` restamps the blocks
on screen, and restamps `data-start` with them: the clock was stamped when the
block was *rendered*, so without that a block that waited out a long reply
would jump straight to "48.2s" the moment it went live.

### INV-IG2: Image generation has independent abort infrastructure

Uses `_imgGenCancelToken` (separate from the text `_cancelToken`) and `isGeneratingImage`
state (separate from `isGenerating`).

### INV-IG3: Image generation abort clears `isGeneratingImage`

Both `abortGeneration()` and `cancelImageGeneration()` clear the flag.
Cancelled image tags are replaced with `[IMG:ERROR:...]`.

### INV-IG4: One image at a time unless the user opts out

`ImageGenService.processMessageImages()` walks the image tags of a message in
document order and awaits each generation from start to end before starting the
next. `ImageGenSettings.concurrentGeneration` (off by default) is the only way
to fire them together; even then the results are written back in tag order.

### INV-IG5: A pending image tag is only ever replaced by its own outcome

Every rewrite goes through `ImageTagMarkup.scanPendingTags()` and touches the
span of a single tag. An image that fails, is cancelled, or is refused becomes
`[IMG:ERROR:...]` carrying its original instruction — a block is never dropped
from the message, so the UI can always offer a regenerate action for it.

### INV-IG6: Image actions address one block, by document position

`ImageTagMarkup.scanImageBlocks()` numbers every image block of a message —
pending, finished and failed alike — in document order. The chat formatter
stamps that same position on each rendered block as `data-img-index`, the
webview sends it back with `onImgRetry` / `onImgFind` / `onImgRegen` /
`onImgOptions`, and `ImageRecoveryService` resolves it through
`resetImageBlockAt()` / `replaceImageBlockWithResult()`. A reroll therefore
regenerates the tapped image only and leaves the other images of the message
untouched. A missing index (markdown images) disables the generation actions
rather than falling back to the whole message.

### INV-IG8: A block keeps every image it generates

`ImageBlockPayload` (image_tag_markup.dart) is the single codec for a block's
images: they are listed oldest first and the visible one is marked, so a
regeneration appends rather than overwrites. A pending block carries them
through behind `@` (`[IMG:GEN:@/a.png;;/b.png|<instruction>]`) and an error
card behind its `variants` string. Only the visible image counts as context for
the next generation (`extractImageResultPaths`), and `rewriteResultPaths`
resolves every variant so the switcher can page through them without a round
trip to Dart.

What a block keeps is images it actually has: a regeneration drops the paths
whose file is gone (`ImageRecoveryService.dropMissingImages`) before it carries
the rest forward, so a switcher never pages onto a picture that cannot load.

### INV-IG9: An image block is stored as an `<img>` element with a relative src

A finished block is written by `ImageTagMarkup.encodeResultElement()` only:

```html
<img data-iig-instruction='{"prompt":"…"}'
     data-iig-variants='generated/a.jpg;;generated/b.jpg'
     data-iig-index='1' src="generated/b.jpg">
```

* `src` is the visible image and is always **relative to the Glaze data root**
  (`_saveGeneratedImage`, `findImageOnDisk`, `restoreChatWebViewLocalFilePath`
  all store it that way, `resolveGlazeFilePath` joins it back onto the current
  root). An absolute path stops resolving when that root moves — a new iOS
  container UUID, a database copied between desktop build channels — and a
  loopback `/__glaze_file__` URL, whose port only exists for one app launch,
  breaks the picture permanently. Neither may reach storage: every text the
  WebView hands back (`onEditSave`, `onMessageContext`, `onSelectionAction`)
  goes through `ChatBridgeController.restoreImgResults()` first, and
  `chatWebViewResolveLocalFileUrl` unwraps a URL that was stored by an older
  build instead of requiring a migration.
* the block's other images ride along in `data-iig-variants` so `src` stays one
  plain path, readable by anything that renders HTML.
* `[IMG:RESULT:…]` is still **read** everywhere a block is read — older
  messages keep rendering, resetting and regenerating unchanged — but it is
  never written any more. The same `<img data-iig-instruction…>` element with
  no image in its `src` is a *pending* block, which is what keeps
  `scanPendingTags()` and `scanResultElements()` from ever claiming the same
  element (`ImgGenPatterns.isPendingIigElement`).
* the WebView formatter parses the element with `parseImageResultElement()`,
  the mirror of the Dart writer, and a pending one with
  `parseImagePendingElement()`. Both spellings of a pending element
  (`<img data-iig-instruction… src="[IMG:GEN]">` and the bare
  `<img src="[IMG:GEN:…]">`) are consumed **whole** and rendered as the loading
  placeholder. Leaving the tag in the markup would put an `<img>` with no
  loadable source into the message, and the reader would watch the browser's
  broken-image icon for the length of the generation.

### INV-IG10: The loading placeholder is sealed off from message CSS

A message body is authored content — cards ship their own `<style>`, and those
rules land in the same shadow root as everything the formatter renders. The
`[IMG:GEN…]` placeholder is app chrome, so
`renderer/imggen_placeholder.js` gives each `.imggen-loading` a shadow root of
its own and moves its content inside, out of reach of message rules that a
specificity war could never win (a card's `!important` beats any selector in
`SHADOW_STYLE`). Two leaks are closed by hand: the host still lives in the
message tree, so its geometry is pinned as inline `!important`; and inherited
properties cross a shadow boundary, so the wrapper inside starts from
`all: initial`. The nested root is **open** — `InteractionDispatch` finds the
stop button through `composedPath()` and `ImgGenTimer` descends into it for the
elapsed-time ticker, both of which a closed root would break.

### INV-IG11: A tag inside a reasoning block never generates

A model plans its images out loud — "then I'll put `[IMG:GEN:…]` here" — and a
tag it writes inside `<think>…</think>` is a note to itself, not a request.
Generating from it produces a picture nobody asked for, in the middle of the
model's own scratchpad.

`ImgGenPatterns.reasoningSpans()` marks those spans and
`ImageTagMarkup.scanPendingTags()` walks past them. That scan is the single
gate every generation goes through — `hasImageGenTags`, `scanImageBlocks`, the
replace/reset helpers and `ImageGenProcessor` all read a message through it —
so a reasoning tag is never generated, never rewritten into an error or
"disabled" card, and never counted in the block numbering.

The WebView agrees on both halves, which is what keeps `data-img-index`
addressing the same block on either side: `_processText` carries an
`inReasoning` flag into the recursive pass over a think block, and the three
pending spellings there are restored as the literal text the model wrote (step
19b) instead of becoming an image block. Only a **closed** block counts as
reasoning, on both sides — an unclosed `<think>` is not folded away by the
formatter either, so a tag after one still generates.

Finished `<img data-iig-…>` blocks are deliberately *not* filtered: they are
pictures that already exist, and `scanResultElements()` is what keeps their
paths resolving and strips them from a sync payload.

### INV-IG12: A model never reads or writes a finished image block

Glaze is the only writer of a finished block: `encodeResultElement()` runs the
moment the image file has been saved, so the `src` and `data-iig-variants` of a
stored block always name files that exist on *this* device.

Neither is any use to a model, and handing them over is actively harmful. The
history used to carry the stored element verbatim, and a model that reads one
writes one back: a block pointing at files nobody generated, which renders as
the browser's broken-image icon under a variant switcher counting pictures that
never existed — one more of them with every turn, until the count reads like
the length of the chat.

`ImageTagMarkup.reduceBlocksToInstructions()` is the single gate. Whatever
state a block is in, it comes out as `[IMG:GEN:<instruction>]` — the tag that
asked for the picture, and the only spelling a model may see or write:

* chat text on its way **into** a prompt goes through it — `HistoryAssembler`
  (main model and Studio), `ExtensionContextAssembler` and the
  `InfoBlockService` prompt builders;
* a reply on its way **into** storage goes through it in
  `SavedMessageWriter.writeAssistant()`, so a finished block a model wrote by
  hand lands as a pending one and the post-gen image stage generates a real
  picture for it (INV-IG1);
* the cloud-sync payload uses the same reduction
  (`SyncSerialization.normalizeImageGenContent`), for the same reason — a path
  into one device's data root means nothing on another.

A tag inside a reasoning block is still left alone (INV-IG11): the reduction
reads the message through `scanImageBlocks()` like everything else.

### INV-IG7: Regenerating an image never adds a message swipe

`ImageRecoveryService` resets the retried blocks through
`ImageGenProcessor.resetImageContentInPlace()`, which rewrites the swipe the
user is looking at (content, `swipes[swipeId]`, its agent swipe and metadata)
and clears the error flag left by the failed block. Rerolling a picture must
not grow the reply's swipe count or duplicate the text around the image — only
a text generation creates swipes.

---

## 3. Summary Generation Invariants

### INV-S1: Summary is always non-streaming

`SummaryService.generateSummary()` goes through `AuxLlmClient.callOnce()`, which
calls the protocol's `ChatTransport` with `stream: false`. No SSE. The protocol
comes from `ApiConfig.protocol` — the summary must never hardcode one provider's
wire format.

### INV-S2: Summary does not create generation registry entries

Summary generation does not touch `ChatState.isGenerating` or any `charId`-keyed
generation guard. Neither the manual run (`summary_tab.dart`) nor the automatic
one (`AutoSummaryStage`) passes a `CancelToken`, so once started it cannot be
aborted.

### INV-S4: Auto-summary only fires on a bot turn

`AutoSummaryStage` runs from `PostGenCoordinator` (post-assistant-turn only) and
additionally requires `session.messages.last` to be a non-error assistant /
character message. A user message must never trigger it.

### INV-S3: Summary does not mutate chat messages

Summary generation only reads history and writes to `ChatSummary` via `SummaryRepo`.
It must not modify `ChatSession.messages`.

---

## 4. Memory Draft Generation Invariants

### INV-M1: Memory draft does not use chat generation state

`MemoryDraftGenerator` owns its own `SseClient` and receives an external `CancelToken`.
It never reads or writes `ChatState.isGenerating`.

### INV-M2: Memory draft is always non-streaming

`MemoryDraftGenerator.generate()` calls the API with `stream: false` unconditionally.

### INV-M3: Memory draft cannot start while chat generation is active ✅ ENFORCED (PR-B C12)

`MemoryBookController.generateDraft()` rejects a start request
when `chatProvider(_charId).value?.isGenerating == true` for the
target character. The user gets a "Chat generation is active"
error message via the existing `onError` callback.

The check is read-only on the chat notifier — it does not wait for
the generation to finish; the user must explicitly abort the chat
generation or wait for it to complete.

### INV-M4: Chat generation cannot start while memory draft is active ✅ ENFORCED (PR-B C12)

`ChatNotifier.sendMessage()`, `ChatNotifier.regenerateLastAssistant()`,
and `ChatNotifier.continueMessage()` reject a start request when a
memory draft is currently being generated for the same `sessionId`.

Both invariants share a single new state container:
`lib/features/memory/state/memory_active_drafts_provider.dart`
(`StateNotifierProvider<MemoryActiveDraftsNotifier, Set<String>>`).
Drafts are added to the set when generation starts and removed when
it ends (success, error, or cancel).

Shared state contract is pinned by
`test/characterization/memory_draft_mutex_test.dart` (7 tests).

### INV-M5: Memory draft approval preserves source range ✅ ENFORCED

`MemoryBookController.approveDraft()` must copy `MemoryDraft.messageRange`
into the resulting `MemoryEntry.messageRange`. This range is provenance used by
source-window exclusion, message-distance recency, diagnostics, and future
excerpt selection.

Compatibility rule: legacy generated entries whose title is only a numeric
range such as `91-105` are read with a `messageRange` backfill in
`MemoryEntry.fromJson()`. This does not rewrite the stored JSON until the book
is saved normally.

### INV-M6: Retired agentic MemoryBook artifacts are purged ✅ ENFORCED (v66)

The retired generic write-loop no longer creates `source = 'agentic'` MemoryBook
entries or drafts. `AppDatabase.purgeRetiredAgenticMicroMemory()` removes only
pre-v66 agentic artifacts and their derived embedding/catalog/entity/salience
rows; it preserves user-curated entries, scan drafts, range summaries, Ledger
state, and all MemoryBook settings.

`MemoryBookRepo` remains the exclusive repository owner for normal manual scan,
draft approval, and user-directed MemoryBook writes. No automatic post-turn
path writes MemoryBook entries.

---

## 4b. Studio Tracker Invariants

These cover the tracker-around-generator pipeline used by Studio. See also
`docs/rules/generation.md` for the rules every contributor touching `MemoryStudioService`,
`ControllerPhaseRunner`, `StudioAgentExecutor`, or `ControllerBatcher` must
follow.

### INV-ST1: Trackers receive ≤ contextSize last messages, not full history ✅ ENFORCED (Phase 3)

`StudioHistoryLimiter.limitTrackerHistory` owns the tracker history cap and
slices the trailing `contextSize` messages before tracker prompt construction.
It also owns per-message text truncation (head 40% + `[Trimmed ...]` marker +
tail 60%, rune-counted) and conservative HTML stripping that preserves
`==...==` markers and code fences. The tracker context hard-cap is 200.

The final generator does NOT use this trim — it uses
`StudioPreset.maxFinalHistoryMessages` (default 50). MemoryBook injection
(`dynamic_context` block: memory, summary, worldInfo) is NOT trimmed — only
the `chat_history` block is. Users without rolling summary keep long-term memory
via MemoryBook (static `dynamic_context` injection), not via chat history.

### INV-ST2: maxFinalHistoryMessages applies to the generator ✅ ENFORCED

`StudioHistoryLimiter` keeps a persisted, stable `chat_history` suffix for the
final generator. After a completed assistant turn crosses either
`StudioPreset.maxFinalHistoryMessages` (default 50) or the 70K estimated token
high-water mark, it advances the boundary by roughly half the current window
on a complete user-assistant chunk boundary. A trailing user message never
rotates the window. Trackers are governed by INV-ST1 instead.

### INV-ST3: Same-(provider, model, phase) trackers batch into one LLM request ✅ ENFORCED (Phase 5)

`ControllerBatcher.groupAgents` keys batch groups by resolved protocol, model,
and agent phase. Agents selected by `shouldRunIndividually` are pulled out and
run as individual requests. Pre-generation and post-processing agents must not
share a batch because their runtime context differs; the POST-cleaner remains a
separate post-generation rewrite pass.

### INV-ST4: Nested agentSwipes (cleaned / final) ✅ ENFORCED

The `AgentSwipe` class and `agentSwipes` / `agentSwipeId` / `studioOutputs`
fields live on `ChatMessage`. The POST-cleaner writes a blue `'cleaned'`
sub-swipe via `ChatRepo.appendAgentSwipe(kind: 'cleaned')`, preserving the
original `'final'` as the parent (lazy-migrated on first clean). Blue
sub-swipe navigation goes through `ChatMessageService.setAgentSwipe` /
`changeAgentSwipe`; the WebView renders an `agent-switcher` (blue) control
when `agentSwipes.length > 1`. `appendAgentSwipe` syncs
`agentSwipes`+`agentSwipeId` into `swipesMeta[swipeId]` so green-swipe
round-trips preserve the nested swipes. `ChatRepo.updateAgentSwipeContent`
and `ChatRepo.removeAgentSwipe` are the atomic in-place swipe editers
(used by the swipe-first cleaner flow — see below); they re-sync
`swipesMeta` the same way.

A full regeneration (`SavedMessageWriter.writeAssistant` with
`regenTargetId`) resets `agentSwipes` to a single fresh `'final'` pointing
at the new text — the old `'cleaned'` sub-swipe (which applied to the
previous content) is dropped. The `studioFinalOnly` re-run branch (append a
`'final'` without touching green swipes) is NOT restored: it depended on
the removed 8-controller `regenerateIntermediateAgent` orchestration.
Hold mode (Marinara) is not implemented.

#### Swipe-first cleaner lifecycle (UX phase) ✅ ENFORCED

`CleanerStage.run` pre-creates an empty `'cleaned'`
swipe at cleaner start and finalizes it based on the outcome. The cascade
checks partial text BEFORE `skipped`/fallback, so a timeout or skip with
streamed text never loses what the user saw live:
- `wasCleaned==true` → `updateAgentSwipeContent` fills it with the cleaned
  text + `genTime` (cleaner elapsed) + `tokens` (estimateTokens).
- `wasCleaned==false` AND `_lastStreamedText` non-empty → save the complete
  latest streamed partial into the swipe (ops log marks `partialSaved`). Covers
  `timeout`, `skipped`, and any other non-ok status that produced stream
  chunks before failing.
- `wasCleaned==false` AND nothing streamed AND `status=='skipped'` →
  `removeAgentSwipe` reverts active to the parent `'final'`.
- `wasCleaned==false` AND nothing streamed (other) → `removeAgentSwipe`
  reverts to the parent `'final'`.
- Abort mid-cleaner → `removeAgentSwipe` (no partial save on abort).
- Hard pipeline failure (`catch`) → best-effort finalize: save partial if
  `_lastStreamedText` is non-empty, otherwise `removeAgentSwipe`. Skipped
  when the cascade already committed (`_finalized==true`).
- `finally` → best-effort `removeAgentSwipe` when no path finalized
  (`_finalized==false`), so a stale empty `'cleaned'` bubble never lingers.

`CleanerStage._lastStreamedText` /
`_preCreatedCleanerSwipeId` / `_preCreatedMessageId` / `_finalized` are
instance fields, reset in the `run` finally block so state
never leaks across runs.

### INV-ST5: Tracker failure aborts Studio after two retries ✅ ENFORCED

`ControllerPhaseRunner` owns the tracker phase and the hard-failure decision.
`StudioBatchCoordinator` owns whole-batch retries, while
`StudioAgentExecutor` owns individual tracker retries; each path gets the
initial attempt plus two retries. If a tracker still fails, or a batch response
has a missing/unparseable `<result>` block, `ControllerPhaseRunner` returns an
error before the final generator runs. There is no individual fallback from an
exhausted batch and no final generation with partial tracker output. The final
generator's own failure also aborts the turn.

### INV-ST6: Batch budget and concurrency caps ✅ ENFORCED (Phase 5.7.2)

Batch `maxTokens` = Σ per-tracker `maxTokens`, capped by `resolved.contextSize ~/ 2`
(output ceiling = half the context window; the other half is input). Batch
`temperature` = MIN across the group (low-temp wins for deterministic
trackers). Batch `contextSize` = MAX across the group (the tracker that needs
20 messages gets 20; the tracker that needs 5 sees more, which is safe).

Concurrent in-flight tracker requests: `_maxConcurrentGroups = 4` for the
phase. Conservative default for desktop (Marinara runs 8/4 on a server; one
user hitting one provider with 8 concurrent SSE streams is a real rate-limit
risk).

### INV-ST7: Studio cache-friendly prompt ordering ✅ ENFORCED (Phase 6.1)

`ControllerBatcher.buildBatchSystemPrompt` orders the batch system prompt as
`<role>` (shared role text) → `<lore>` (shared static + dynamic + trimmed
history) → `<agents>` (per-agent `<agent_task>` XML) → required output format.
Shared stable content sits at the prefix; per-agent volatile content sits at
the tail. `StudioMessageBuilder.buildSharedBatchMessages` orders shared messages
as `static_context` → `dynamic_context` → `chat_history` for the same reason.
This gives the provider's prompt cache (Anthropic ephemeral /
OpenRouter `cache_control`) a long stable prefix to hit across turns.
`cacheControlTtl` / `cacheBreakpointMode` are wired through
`ResolvedAgentConfig.fromApiConfig` → `ChatTransportRequest` → transport.

### INV-ST8: Studio configuration is turn-scoped ✅ ENFORCED

A normal generation resolves one `StudioTurnConfigSnapshot` at turn start and
passes it through prompt construction, trackers, final generation,
POST-cleaner, and Ledger. Downstream stages must prefer the supplied snapshot
and must not re-read mutable Studio preset, API, or pipeline settings during
that turn. The API-config list is immutable. A manual action that starts a
separate operation may resolve a fresh snapshot.

`StudioLedgerService` remains the compatibility facade, but it does not own
durable mutation details. `LedgerTurnCommitter` exclusively owns normal-turn
Ledger/fact/snapshot writes, and `LedgerReconciliationCommitter` exclusively
owns reconciliation and replacement writes. Their transaction and stale-fence
ordering must not be bypassed by runners, stages, or callers.

### INV-ST9: Cleaner execution has lease authority ✅ ENFORCED

Cleaner runs acquire a `CleanerRunLease` keyed by `(sessionId, messageId)`.
Same-key execution is latest-wins: the successor cancels all registered tokens
and waits for prior cleanup. Superseded queued runs do not start; distinct keys
may run concurrently. A run may publish shared cleaner UI/token state only
while `lease.ownsSharedState`, and may perform normal message-specific effects
only while `lease.isCurrent`.

### INV-ST10: Memory Graph (entity extraction + salience) is DISABLED

`MemoryPostTurnService.runPostTurn` is a **no-op** — only the cadence
counter is incremented. The heuristic `MemoryEntityExtractor` (relies on
`[A-Z][a-z]` proper-noun detection) does not work for Cyrillic text and
produces garbage entities. The 4 graph tables
(`memory_entity_rows`, `memory_salience_rows`, `memory_cadence_rows`,
`memory_consolidation_rows`) remain in the DB for forward compat but
receive no new rows.

Entity tracking is handled by **Studio Ledger** (LLM-based, writes
`npc:Name.field`, `world:location`, `scene.present_entities` into
`tracker_rows`) — see INV-ST1 through INV-ST9.

**Do NOT re-enable** the heuristic extractor without rewriting it for
non-English text. Reference for a future LLM-based approach:
[Lumiverse Memory Cortex](https://github.com/prolix-oc/Lumiverse/tree/main/src/services/memory-cortex)
— heuristic Tier 1 + LLM sidecar Tier 2 with arbitration.

---

## 4c. Tracker Snapshot Rollback Invariants

The tracker snapshot system provides per-agent-swipe rollback for canonical
tracker state written by Studio Ledger.

### INV-TS1: Snapshots are write-once; rollback is emergent ✅ ENFORCED (Phase 1-4)

`tracker_snapshots` rows are never updated in place (other than the
`committed` 0→1 flip via `commit` / `commitLatest`). The only allowed
writes are:

- `TrackerSnapshotRepo.upsertTrackers` — insert-or-replace by composite
  PK `(sessionId, messageId, swipeId, agentSwipeId)` after Ledger applies an
  accepted canonical state update.
- `commit` / `commitLatest` — flip `committed` 0→1 (`ChatNotifier.sendMessage`,
  Phase 6).
- Delete methods (`deleteForMessage` / `deleteAnchor` / `deleteBySessionId`).

Selection of the rollback snapshot is **emergent**: deleting the rows for a
message makes the previous committed snapshot become the new latest.
`getLatestCommitted` / `getLatestCommittedExcludingMessage`
return the highest-`createdAt` committed row, which naturally rolls back
when newer rows are deleted. Applying that selected snapshot to the mutable
`tracker_rows` materialization is explicit and transactional.

Code refs: `lib/core/db/repositories/tracker_snapshot_repo.dart`,
`lib/core/llm/ledger/ledger_turn_committer.dart`,
`lib/core/llm/ledger/ledger_reconciliation_committer.dart`, and
`ChatMessageService.commitDeleteMessages` → `deleteForMessages`. The UI
publishes the shortened message list before this
commit runs (`ChatMessageOpsController.deleteMessages` is optimistic), so the
snapshot rollback is *not* observable state — it lands with the transaction,
and a failed commit restores the pre-delete session in the UI.

### INV-TS2: Sentinel anchor survives per-message deletes ✅ ENFORCED (Phase 7)

The migration-v51 baseline snapshot lives at the sentinel anchor
`(messageId='', committed=1)`. `deleteForMessage(messageId)` only deletes
rows with a non-empty `messageId` — it **must never** drop the sentinel
anchor. Only `deleteBySessionId` and `deleteByCharacterId` (full-session /
full-character cleanup) may drop it.

This guarantees legacy sessions (migrated from `tracker_rows` in v51)
always have a baseline snapshot until the session itself is deleted.

Code ref: `TrackerSnapshotRepo.deleteForMessage` in
`lib/core/db/repositories/tracker_snapshot_repo.dart`: its `where` clause
filters by `messageId.equals(messageId)` and the
sentinel anchor has `messageId = ''`, so it is never matched.

### INV-TS3: Read path is snapshot-first with `tracker_rows` fallback ✅ ENFORCED (Phase 3)

The read call sites use `getLatestCommitted` / `getLatest` first and fall back
to `trackerRepoProvider.getBySessionId` when no snapshot exists. This keeps
legacy sessions (pre-snapshot, not yet re-saved) working without a forced
migration of every read.

Studio Ledger reads the effective committed snapshot before applying its next
typed canonical update; tracker UI reads the same snapshot-backed state.

### INV-TS4: Snapshot granularity is per-agent-swipe ✅ ENFORCED (Phase 1)

Each snapshot is anchored at `(sessionId, messageId, swipeId, agentSwipeId)`
— not per-message or per-session. This lets the rollback system restore
state at the exact granularity the user navigates: swiping back through
agent sub-swipes (e.g. `'final'` → `'cleaned'`) restores the matching
tracker state, because each agent sub-swipe has its own snapshot row.

### INV-TS5: POST-cleaner clones parent snapshot ✅ ENFORCED (Phase 2)

The POST-cleaner clones the parent message's snapshot into the new `'cleaned'`
agent-swipe anchor so the cleaned sub-swipe inherits the parent's tracker
state; the original `'final'` snapshot is preserved. Two paths:

- **Swipe-first flow (UX phase, `CleanerStage.run`):**
  the snapshot is cloned at pre-create time (right after
  `appendAgentSwipe(kind: 'cleaned', content: '')`), before the cleaner
  runs. So even if the cleaner crashes the pre-created swipe already has a
  valid snapshot anchor.
- **Legacy fallback (`post_cleaner_service.applyCleanedText`):** used when
  pre-create failed earlier; clones after the append inside `applyCleanedText`.

Code ref: `CleanerStage` (pre-create snapshot clone) and
`PostCleanerService.applyCleanedText` (fallback); both call
`snapshotRepo.upsertTrackers(...)` with the parent's
`messageId`/`swipeId` and the new `agentSwipeId`.

### INV-TS6: Branch copies snapshots for sliced messages ✅ ENFORCED (Phase 5)

`chat_session_service.branchSession` calls
`trackerSnapshotRepo.copyForSessionBranch` to copy snapshots for the
sliced message IDs to the new session ID. Snapshots beyond the branch
point are not copied (the branch starts fresh from the slice). The PK
includes `sessionId` as a prefix, so branches don't alias even though
messages are not re-id'd on branch.

Code refs: `TrackerSnapshotRepo.copyForSessionBranch` and
`ChatSessionService.branchSession`.

### INV-TS7: Snapshots are covered by backup + cloud sync ✅ ENFORCED (Phase 8, 9)

`tracker_snapshots` entered the backup format at v5 and remains in the current
backup whitelist (`backup_exporter.dart`, backup schema v12). It has full cloud
sync coverage via
`SyncTrackerSnapshotStore` + `TrackerSnapshotSyncStore` adapter (Phase 9).
Session deletes record `SyncDeletionTracker.record('tracker_snapshot',
sessionId)` so the cloud counterpart is deleted too.

Code ref: `lib/core/services/backup/backup_exporter.dart:_knownTableNames`,
`lib/features/cloud_sync/adapters/ext_blocks_sync_stores.dart:TrackerSnapshotSyncStore`,
`lib/features/chat_history/chat_history_provider.dart:deleteSession`.

---

## 5. Prompt Semantics Invariants

### INV-PS1: Prompt block order is determined by the preset's `blocks` array

The preset's `blocks` list fully controls what appears in the prompt and in what order.
Character fields appear only when a matching preset block ID resolves them.
If a block is disabled, that field is omitted. `PromptBuilder` is the sole enforcer.

### INV-PS1b: Image attachments are sent to the model unless explicitly hidden

`ChatMessage.imageHidden` defaults to `false`, so a picture attached to a
message travels with it into the request (`PromptMessage.imagePath` →
`toApiMap()` → the protocol converters). The eye button on the attachment
(`toggle-image-hidden` → `onToggleImageHidden` →
`ChatMessageService.toggleImageHidden`) flips the flag; `HistoryAssembler.assemble`
and `buildFallbackPrompt` then drop `imagePath` from the prompt message. The
bubble keeps rendering the image either way — hiding affects the request only.

### INV-PS2: Vector scan runs before keyword scan; keyword deduplicates vector

1. Vector lorebook scan runs async in `PromptPayloadBuilder.buildFromSession()` — results packed into `PromptPayload.vectorEntries`.
2. Keyword lorebook scan runs synchronously in `PromptBuilder` (inside the Dart isolate).
3. `mergeKeywordVector()` deduplicates: vector entries whose IDs appear in keyword results are dropped. Keyword results always win.

### INV-PS2b: Vector / embedding / index UI hangs off the API toggle

`vectorSearchAvailableProvider` (`lib/core/state/lorebook_embedding_provider.dart`)
is the single source of truth for whether the app shows anything about vectors,
embeddings or indexes. It mirrors the condition `resolveEmbeddingConfig` uses —
an **embedding** preset (`activeEmbeddingConfigProvider`, see INV-PS2c), not
itself an `embedding`-mode preset, with `embeddingEnabled` on (the
**Embeddings → Vector search** switch of the API screen).

While it is `false`, these stay hidden rather than disabled: the lorebook
search-type picker and vector params (list + global + per-book settings), the
embedding-settings entry point, the editor's index / reindex / drop-indexes
toolbar, the reindex banner, the per-entry vector section and its `vec` / `idx`
badges, and the memory sheet's retrieval-mode row, reindex / drop-indexes
actions and index badges. Stored values are never rewritten by the gate — the
previous choices come back when the toggle is switched on again.

### INV-PS2c: The embedding preset is selected apart from the chat preset

The API screen's **LLM** and **Embeddings** tabs each carry their own preset
pill. The chat side follows `activeApiPresetIdProvider` (SharedPreferences
`activeApiConfigId`), the embedding side `activeEmbeddingPresetIdProvider`
(`activeEmbeddingConfigId`), and switching one never moves the other — a vector
index is tied to the model that produced it, so it must not follow the chat
connection around.

`ApiListNotifier.build` seeds `activeEmbeddingConfigId` once, from the saved
chat preset (or the first preset), so an upgrade keeps running embeddings on
the preset they were already on. A stored id pointing at a deleted preset is
re-seeded the same way.

The one remaining link is the preset's **Use LLM API** toggle
(`embeddingUseSame`, and the same fallback when a dedicated embedding endpoint
is blank): while it is on, `resolveEmbeddingConfig(embeddingConfig, llmConfig)`
borrows the endpoint and key of the *active LLM preset* — the model, chunk size
and rate limit still come from the embedding preset. With the toggle off,
`embeddingConfigProvider` does not even watch the chat selection.

Saving follows the same split: `ApiConfigDraft.applyLlmTo` writes the
connection / sampling / reasoning half, `applyEmbeddingTo` the embedding half,
and the API screen sends each to its own preset (one combined `toConfig` write
while both tabs sit on the same preset).

### INV-PS3: History cutoff is oldest-first

When context overflows, history is trimmed from the **oldest** end.
`ContextCalculator._trimHistory()` walks backwards from the newest end, accumulating
messages until the budget is full. The oldest messages are dropped because they are never accumulated.

### INV-PS3b: The prompt budget always reserves the completion window ✅ ENFORCED

The provider enforces `prompt_tokens + max_tokens <= contextSize`, and the
transport layer sends `max_tokens` (`apiConfig.maxTokens`) as the completion
budget with every request (`*_chat_transport.dart`). The prompt must therefore
never be allowed to fill the entire context window, or the model has no room to
answer and returns an **empty completion**.

`ContextCalculator.safeContext` reserves `maxTokens` up front:

```
safeContext  = max(0, contextSize - maxTokens)
historyBudget = safeContext - staticTotal - effectiveReserve - memoryTokens
```

This mirrors `fallback_prompt_builder.dart`. Large memory injection
(`chunk_first` packing, high `maxInjectedTokens`) shrinks `historyBudget` but
can never reclaim the reserved completion window. If `historyBudget <= 0`,
`_trimHistory` returns an empty list with `cutoffIndex == history.length`
(all history dropped) — the caller still keeps the synthetic memory block and
static prompt, but the operator should lower memory budget / raise context size.

`safeContext` is clamped to `>= 0` so a misconfigured `maxTokens >= contextSize`
yields a zero window instead of a negative budget.

### INV-PS4: Memory injection is guarded by a token budget ✅ ENFORCED (PR-B C13)

`MemoryInjectionService.buildInjection()` enforces a hard upper bound
on the tokens spent on memory injection. The cap is configured per
`MemoryBookSettings.maxInjectionBudgetPercent` (default `0.35`, i.e.
35% of the active context budget).

**Formula:**

```
maxInjectionTokens = max(0, contextBudgetTokens) * maxInjectionBudgetPercent
```

where `contextBudgetTokens` is supplied by the caller (typically
`apiConfig.contextSize`). Entries are kept in score-descending
order; once the running total of `estimateTokens(entry.content)`
exceeds `maxInjectionTokens`, the tail of the list is dropped.

In `memoryPackingMode == 'chunk_first'`, `MemorySelector` passes all
non-excluded candidates to `MemoryExcerptSelector.selectChunkFirstGlobal()`,
which budgets on **injected chunk tokens**, not full-entry sizes. The hard
cap still applies to the final packed text.

If `contextBudgetTokens` is not supplied (null/0) or
`maxInjectionBudgetPercent <= 0`, the guard is a no-op — legacy
behaviour is preserved for callers that don't yet pass the budget.

The percentage default lives in `MemoryBookSettings` (see
`lib/core/models/memory_book.dart`) so per-book overrides can be
added in the future without changing the service signature.

### INV-PS5: Memory injection position is deterministic

Memory can be injected into the prompt via one of three mechanisms.
The first two are keyed off `MemoryGlobalSettings.injectionTarget`
and `MemoryBookSettings.injectionTarget` (per-book override); the
third is an explicit preset block the user can add/enable like any
other system block:

* **Dedicated `memory` preset block**: a `PresetBlock(id: 'memory',
  name: 'Memory Book', isStatic: true)`. It ships in
  `defaultPresetBlocks()`, `seedDefaultPresets()`, and is re-injected
  by `finalizeImportedPreset()`, and can be added from the preset
  editor's "Add Block" menu. `resolveBlockContent` resolves it to
  `MacroContext.memoryContent` (the deferred placeholder during
  finalization, then the packed memory after the cutoff), exactly
  like the `{{memory}}` macro. A disabled block (`enabled: false`)
  is skipped and falls back to the `injectionTarget` mechanism below.

* **`hard_block`** (default): a hard system message with
  `blockId='memory'` and `blockName='Memory Book'` is added before
  the first history message. The check is skipped when the preset
  already has a block with `id='memory'` or contains the `{{memory}}`
  macro (so the user can disable the hard block by adding an
  explicit `enabled: false` block in the preset, or by placing
  `{{memory}}` in a custom wrapper).

* **`macro`**: no hard block is added automatically. Memory is
  reachable through the `{{memory}}` macro or the dedicated `memory`
  block inside the preset, which give the user full control over
  placement and wrapper tags. If neither sink is present but memory
  was selected, the memory is dropped and `memoryMacroMissing` is set
  in `memoryCoverage` so the Memory Activity card can warn the user.

Summary injection is independent and unchanged: the `{{summary}}`
macro resolves to `MacroContext.summaryContent` (user-authored
summary only — no memory piggyback). It is the user's responsibility
to place `{{summary}}` in a preset block if they want it injected.

**Accounting rule** (token breakdown): preset chrome is attributed
to `sourceTokens['preset']` and dynamic macro injections
(`{{summary}}`, `{{memory}}`, `{{lorebooks}}`, `{{guidance}}`) are
attributed to their dedicated buckets (`sourceTokens['summary']`,
`sourceTokens['memory']`, etc.) — never both.

Concretely, `resolveBlockContent` returns TWO flavours of the
resolved content:

* `content` — fully expanded (what the LLM actually sees), used
  for `messages` and the merged `PromptMessage` system block.
* `contentForAccounting` — same shape, but with dynamic macro
  injections blanked out (`replaceMacros` is run against a context
  where `summaryContent` / `memoryContent` / `lorebooksContent` /
  `guidanceText` are null). This is what `attributionBlocks` see, so
  `sourceTokens['preset']` reports ONLY the preset's static chrome.

Before this split, a preset block that contained `{{memory}}` would
double-count the memory tokens — once via the `id='memory'`
hard-block attribution and once via the merged preset buffer that
included the expanded content.

**Preset-only accounting** (`contentForAccounting` /
`MacroContext.forPresetAccounting()`): counts only text that belongs
to the preset file. **Blanked** (counted elsewhere): character fields
(`{{char}}`, `{{description}}`, `{{personality}}`, `{{scenario}}`,
`{{mesExamples}}`), persona (`{{user}}`, `{{persona}}`), and runtime
injections (`{{summary}}`, `{{memory}}`, `{{lorebooks}}`,
`{{guidance}}`). Those appear in `macroTokens` and/or dedicated
`StaticBlock` buckets (`description`, `personality`, `memory`, …).

**Still counted as preset**: literal block text, `{{setvar::}}` /
`{{setglobalvar::}}` definitions, `{{getvar::}}` expansions of
in-preset variables, and custom global vars set inside the preset.

Dedicated injection blocks (`char_card`, `char_personality`, …):
`contentForAccounting` uses **raw block content only**, not injected
character/persona payloads.

`presetNetTokens` equals `sourceTokens['preset']` (no further
subtraction — external macros are already excluded in accounting).

### INV-PS7: Macro resolution order is fixed

Within a single `MacroEngine.replaceMacros()` call, macros resolve in this order:
1. Comment stripping
2. Static character macros
3. `{{reasoningPrefix}}` / `{{reasoningSuffix}}`
4. `{{summary}}` / `{{memory}}` / `{{lorebooks}}` / `{{guidance}}`
5. Trim
6. Session variable macros (`setvar`/`getvar`)
7. Global variable macros (`setglobalvar`/`getglobalvar`)
8. Custom named macros
9. `{{random::}}` / `{{pick::}}`
10. Dice `{{roll::}}`
11. Date/Time
12. Escape handling

### INV-PS8: Recursive lorebook scan is bounded

`scanLorebooks()` limits recursion to `maxIterations = 5` when `recursiveScan` is enabled,
or `1` when disabled. This prevents infinite loops from circular entry references.

### INV-PS9: Block-level append-to-last-user-message

`PresetBlock.appendToLastMessage = true` causes the block's content (after macro expansion) to be **appended to the last user-role message in the chat history** at prompt-assembly time.

Rules (enforced in `lib/core/llm/prompt_builder.dart:_assembleMessages` via `applyAppendToLastMessage`):

1. The block's own `role` is irrelevant in this mode — the content is always merged into the **last** user message found in `historyMsgs`. Block role may be `system`, `user`, or `assistant`; the merged message keeps the user role.
2. Macros (`{{lorebooks}}`, `{{summary}}`, etc.) are expanded **before** append, in `resolveBlockContent()` — see INV-PS7. A block like `<lorebooks>{{lorebooks}}</lorebooks><summary>{{summary}}</summary>` expands to fully-rendered text and is appended as-is.
3. Multiple blocks with `appendToLastMessage = true` are appended in **preset order**, joined with `\n\n`. Their `blockName`s are listed in the merged message's `blockName` as `"<orig> + <name1>, <name2>"` for preview attribution.
4. If the history has no user-role messages (empty chat / first message is assistant or system), the appended blocks are **silently dropped**.
5. The block is still subject to the standard `enabled` and `isStashed` gates — disabled or stashed blocks are ignored.
6. The append happens in `_assembleMessages` **after** `HistoryAssembler.assemble(history)` and **before** `interleaveDepthWithHistory`, so depth blocks are still positioned by history depth and regex pipeline sees a single merged user message.

### INV-PS10: Empty block emission is explicit

After macro expansion, content that is empty or whitespace-only is not sent as
an API message by default. `PresetBlock.sendEmptyBlock = true` is the explicit
per-block opt-in for emitting that blank message.

Enforced at four points:

1. `resolveBlockContent()` checks trimmed content before and after macros (`lib/core/llm/prompt_block_resolver.dart`). Variable mutations still run even when their block is not emitted.
2. `_assembleMessages` carries the block opt-in into the built message (`lib/core/llm/prompt_builder.dart`).
3. The final message filter in `buildPrompt`, same file.
4. `buildApiMessages()` retains whitespace only when `sendEmptyBlock` is true (images remain independently sufficient), mirrored by `buildPreviewMessages()`.

Consequences:

- Non-empty block content is not rewritten or trimmed on the way out. The trim is only an emptiness test.
- A block containing only `{{setvar::...}}`, `{{memory}}`, or another macro that resolves empty does not create an accidental blank message. Setvar accounting remains as described in INV-PS5.
- Two places stay trim-based on purpose, because neither emits a block as its own message: `applyAppendToLastMessage` (INV-PS9) joins block text into an existing user message, where whitespace would only add blank lines; and lorebook attribution reporting, which maps rendered entries back to snapshots.

---

## 6. Stream vs Non-Stream Parity

### INV-P1: Final output is identical regardless of transport mode

Both streaming (SSE) and non-streaming paths produce the same final
`(text, reasoning)` pair for the same API response content.
Both paths use `StreamAccumulator` for reasoning extraction.

### INV-P2: Reasoning extraction is equivalent

Both streaming and non-streaming paths use `StreamAccumulator` to split
`<think…>` tags. The non-streaming path feeds the entire response as one
delta through the same accumulator, producing identical output.

### INV-P3: Abort behavior differs by design

- Streaming: partial text can be preserved (incremental accumulation)
- Non-streaming: no partial text available on abort

This asymmetry is intentional and correct.

---

## 7. Abort Invariants

### INV-A1: Abort propagates to the HTTP layer

When `ChatNotifier.abortGeneration()` is called:
1. `_activeGenId++` — invalidates stale callbacks
2. `_cancelToken?.cancel()` — propagates to Dio, closes the SSE stream
3. `_imgGenCancelToken?.cancel()` — cancels any in-flight image generation
4. Manual state restoration + partial text persist in `abortGeneration()` itself

Cancelling only UI state while leaving the TCP connection open is a bug.

### INV-A2: Abort restores pre-generation state

On abort, `ChatNotifier.abortGeneration()` restores:
- The placeholder message (converted to partial or removed)
- `ChatState.isGenerating → false`
- `ChatState.isGeneratingImage → false`
- Session variables mutated during prompt build — ✅ on success only (see INV-C5)

### INV-A2b: A rollback restores the variation's error state too

Error state is per swipe (`swipesMeta[i]['isError']`, see
`ChatMessageService.setSwipe`). When a regen is cancelled and the pre-regen
snapshot is put back — `AbortHandler._finalizeAbortWithPartial` (no partial
text) and `RegenResolver.resolve` (rollback branch) — the restored message
takes its `isError` from `restoredVariationIsError(snapshot, swipesMeta)`, not
a hard `false`. Clearing the flag there turned an errored variation into a
normal-looking bubble whose text is an error message, and re-opened the
post-gen chain gated on `isError` (INV-EG4). Partial text is a new, healthy
swipe and stays `isError: false`.

### INV-A3: Regen during active generation aborts first

`ChatNotifier.regenerateLastAssistant()` does not simply reject when generation is active.
It calls `abortGeneration()` first, then proceeds with the new generation.
If abort fails to clear `isGenerating`, the subsequent check rejects.

---

## 8. Continue Message Invariants

### INV-CM1: Continue message appends to the last assistant message

`ChatNotifier.continueMessage()` runs the ordinary chat pipeline —
`GenerationPipeline.run(continueTargetId: <last assistant id>)` — so the request
uses the same transport, protocol, prompt assembly and post-generation stages as
a send. The pipeline branches into `_resolveContinuation()` once the stream
completes: it folds the generated block into the message being extended
(`mergeContinuationMessages`, paragraph boundary) and commits that one message
through `ChatRepo.commitGenerationResult(regenTargetId: <target id>)`. The
commit's anchor guard checks content, `swipeId`, `agentSwipeId`, `swipes` and
`swipesMeta` against the pre-run snapshot; a conflict is rejected instead of
overwritten. It does not create a new swipe or keep the temporary generated
message. The active green and nested swipes are updated to the same merged
content. Passing the target as `regenTargetId` also keeps Studio history
rotation out of the continue path: continue adds no turn, so the window must not
advance.

While the continuation streams, `ChatState.continuationTargetId` holds the id of
that assistant message. The WebView layer keys off it: the sync dispatcher skips
the virtual typing placeholder and flags the target bubble as typing instead,
and the streaming listener grows that bubble with
`joinContinuation(original, streamedText)`. The bubble therefore shows exactly
the text the merge will persist, instead of a separate block that collapses into
the original when the merge lands. The field is cleared whenever the run
settles (success, error, or abort).

Stop during a continuation merges the partial text into the target message
(`AbortHandler._finalizeContinuationAbort`) rather than appending it as a new
assistant message. `continueMessage()` clears `abortHandler.restorationMessage`
before starting, so a snapshot left by an earlier regenerate cannot be
re-appended by that abort.

When the last message is **not** an assistant message there is nothing to
extend: a trailing user message is delegated to `regenerateLastAssistant()`,
which generates a normal reply through `GenerationPipeline`; any other trailing
role is a no-op.

Mutex: `continueMessage()` rejects when `_isMemoryDraftActive` (same as
`sendMessage` / `regenerateLastAssistant`) — see INV-M4.

### INV-CM2: Continue runs the same post-generation stages as a send

`_resolveContinuation()` hands the merged message to `PostGenCoordinator.run()`,
so the continue path runs the full post-SSE tail: sync + notification, POST-
cleaner / Ledger (Studio ON), ExtBlocks, inline `[IMG:GEN]` processing, chat
embedding, memory drafts and auto-summary — all bound to the merged message,
which is the session's last message by then.

Two pipeline behaviours stay off the continue path by construction:
regen rollback (continue keeps no `restorationMessage`) and the append-a-new-
message commit (continue commits the merged message in place).

### INV-CM3: Continue prompt injects one system turn after the extended reply

`PromptPayload.continueInstruction` carries `kContinueInstruction`
(`"Expand your latest message, continue."`, `core/services/preset_defaults.dart`)
and is set only when `StreamGenerationService.run()` is given a
`continueTargetId`. `insertContinueInstruction()` (`core/llm/history_assembler.dart`)
places it as a `system` turn immediately after the last chat message, ahead of
the depth-0 injections pinned to the end of the window and ahead of every preset
block ordered after `chat_history`. Depth-anchored blocks at depth ≥ 1 stay
where they are: they sit *before* the extended reply, so they cannot come
between it and the instruction.

Three assembly paths honour it: the ordinary preset builder
(`prompt_builder.dart`), the preset-less fallback (`fallback_prompt_builder.dart`),
and the Studio final writer (`studio_message_builder.dart`, via
`StudioContext.continueInstruction`). Studio's **controller** agents never see
it — they analyse the scene rather than extend the reply, so
`buildAgentMessages` passes it through only when `isFinalResponse` is true.

Consequence: the request's last message is a system turn, not the assistant
reply. Continue therefore never relies on provider prefill — no Anthropic
prefill echo prepended to the streamed text, and no dropped trailing assistant
turn when extended thinking is on.

### INV-CM4: A failed continuation writes nothing to the message

A continuation that fails — transport error, first-chunk timeout, thrown
pipeline exception, or a completion carrying no usable text — must leave the
message it was extending byte-for-byte as the user saw it. No error swipe, no
appended error bubble, no partial merge.

`StreamGenerationService` routes every error site through `_continueFailure()`
when `continueTargetId` is set: it returns a settled `ChatState` carrying
`error`, and never calls `SavedMessageWriter.writeError` /
`writeRegenError`. `GenerationPipeline._settleContinuationFailure()` (and the
continue branch of `_handlePipelineError`) then clears the streaming flags and
publishes a `ContinueFailureNotice` on `continueFailureProvider`.

That notice is the failure's only surface: `ContinueFailureListener` (mounted in
`app.dart`) turns it into the red `Continue Failed` toast.

### INV-CM5: Continuation reasoning is filed, never leaked

Reasoning produced by a continuation — native (`reasoning_content` /
`thinking` deltas) or inline (`<think>` tags parsed by `StreamAccumulator`) —
must never reach the reply text. `joinContinuationReasoning()` appends it to the
message's existing reasoning block, separated by a horizontal rule and headed by
`==accent==Continue==` (accent-coloured, see `docs/markdown-markers.md`). The
merged value is written to the message, the active green swipe's meta and the
active nested swipe, so a swipe round-trip restores it.

The live WebView preview uses the same function, so the streaming reasoning
block shows exactly what the merge will persist. An aborted continuation goes
through the same merge (`AbortHandler._finalizeContinuationAbort`), so partial
reasoning is filed the same way.

### INV-CM6: The extended message shows a `Continuing…` footer

For the whole streaming window the message being extended carries a
`Continuing…` badge in its footer meta column. `ChatState.continuationTargetId`
is mirrored onto `ChatBridgeController.continuationTargetId` by the sync
dispatcher, so every message map `ChatMessageMapper` builds during the run flags
that one bubble with `isContinuing`. The renderer level-reconciles the badge in
`_createFooter` and `updateMessageMeta`; partial patches (memory badges, plain
content updates) carry no `role` and leave it alone. When the run settles the
dispatcher pushes one update with the flag cleared — the only thing that drops
the badge on the failure path, where no message changed.

---

## 9. Extension Post-Generation Invariants

### INV-EG1: Extensions run only after a successful normal/regen chat completion

After-assistant ExtBlocks dispatch through `ExtBlocksStage` under
`PostGenCoordinator`: directly as background work for ordinary chat, or from
`CleanerStage` after Studio selects and reloads the canonical swipe.
`ExtBlocksStage` then calls `ExtensionPostGenService.processAfterGeneration()`.
They do not run during SSE streaming. `continueMessage()` uses the same pipeline
and post-generation coordinator, bound to the merged message (INV-CM2).
After-user blocks use the separate
`ExtensionPostGenService.runAfterUserBlocks()` entrypoint.

### INV-EG2: Extension failures do not fail chat generation

`ExtBlocksStage` catches errors and reports post-generation status; the
assistant message and chat state remain committed.

### INV-EG3: Extensions are gated by settings

Processing is a no-op when `extensionsSettings.enabled` is false or
`activePresetId` is null/empty. Info blocks are stored per `sessionId` via
`infoBlocksProvider`.

### INV-EG4: Block chain does not start if text generation was aborted or errored

`PostGenCoordinator` is reached only after the generation result is committed.
An aborted generation never reaches this dispatch. `ExtBlocksStage` and
`ExtensionPostGenService.processAfterGeneration()` reject a trailing user or
errored message, so the block chain cannot start for an error result either.
The regen path additionally requires a non-error regenerated message.

### INV-EG5: Extension cancel token is independent of the chat generation cancel token

`ExtensionPostGenService` owns the plural `_blocksCancelTokens` set because
after-user, after-assistant, manual, and periodic runs may overlap.
`cancelBlocks()` cancels every token in that set; it does not touch the chat
generation or image-generation tokens. Conversely, aborting chat generation
does not cancel already-started ExtBlocks. Stopped persisted blocks are marked
`BlockRunStatus.stopped` in the DB.

### INV-EG6: `dependsOnPrevious = true` blocks run serially; output chaining is preserved

When a `BlockConfig` has `dependsOnPrevious = true`, `ExtensionPostGenService` awaits
the preceding block's future before starting the dependent block. The preceding block's
`InfoBlock.content` is passed as `previousOutput` to the dependent block's prompt
builder. Blocks with `dependsOnPrevious = false` (default) are launched without
`await` and run concurrently.

### INV-EG7: Image-gen block results are stored via `ImageStorageService`; content holds the path token

After `ImageGenService.generateImage()` succeeds, the image bytes are saved to disk
through `ImageStorageService`. `InfoBlock.content` is set to the stored image
block — an `<img data-iig-…>` element whose `src` is relative to the Glaze data
root, same format as inline img-gen (INV-IG9). The WebView bridge renders it
with the panel's own image controls inside the ext-blocks panel, and still
reads the `[IMG:RESULT:<path>]` of blocks written before that form.

### INV-EG8: JS Runner / interactive panel code runs in a sandboxed iframe with null origin ✅ ENFORCED

User-authored JS (`BlockType.jsRunner` and `BlockType.interactive` panel
content) executes in a `<iframe sandbox="allow-scripts">` **without**
`allow-same-origin`. The iframe has a null origin and therefore cannot
reach `window.parent`, `window.flutter_inappwebview`, or any other
parent-context object. API keys live in native Drift and are never
serialised into the JS context.

`glaze.*` calls are the only sanctioned way for the script to talk back to
Dart. `JsBridgeService.dispatch` resolves the canonical method registry and
enforces its capability before handler dispatch (see INV-JS1). The two paths
share the same contract, not mutable process-wide chat authority:

* `ChatBridgeController.runJsBlock()` — visual WebView, used while a
  chat is open.
* Sandboxed panels relay through that same Chat WebView and receive the host's
  authoritative panel and message identifiers.

`runSandboxedScript` is implemented in
`assets/chat_webview/bridge/chat_bridge_controller.js`. It wires the iframe's
`postMessage` channel to a Dart `glazeBridge` handler with a
matching source-check (`e.source !== iframe.contentWindow` /
`!== contentWindow`).

---

## 10. JS Extension Bridge Invariants

### INV-JS1: `glaze.*` calls are gated by per-preset capability permissions (default-deny) ✅ ENFORCED

Every public bridge method is defined in the immutable
`JsBridgeMethodRegistry`, including its capability resolver and host
availability. `JsBridgeService.dispatch` rejects methods absent from that
registry and enforces the resolved capability before invoking a handler.
The production constructor requires a `PermissionCheck`; test compositions use
an explicit harmless fake.
Production wires `_bridgePermissionCheck` in `ChatWebViewWidget`, which reads
`activePresetPermissionsProvider`. The `PresetPermissions` model has 19
toggles; only `showToast` defaults to allow.

| Method | Capability |
|---|---|
| `glaze.getVariables / setVariables / deleteVariable` (`scope: chat`) | `read_chat_vars` / `write_chat_vars` / `delete_chat_vars` |
| same (`scope: character`) | `read_character_vars` / `write_character_vars` / `delete_character_vars` |
| same (`scope: global`) | `read_global_vars` / `write_global_vars` / `delete_global_vars` |
| same (`scope: message`) | `read_message_vars` / `write_message_vars` / `delete_message_vars` |
| `glaze.generateText` | `generate_text` |
| `glaze.triggerGeneration` | `trigger_generation` |
| `glaze.injectPrompt / uninjectPrompt` | `inject_prompt` / `uninject_prompt` |
| `glaze.playAudio` | `play_audio` |
| `glaze.executeCommand` | `execute_command` |
| `glaze.showToast` (default ALLOW) | `show_toast` |

The Chat WebView is the sole registry-defined bridge host. Scope-sensitive
variable methods resolve their capability from `params.scope`; fixed-capability
methods carry a fixed resolver. Handler code does not maintain a second
capability table.

### INV-JS2: Variable writes are atomic; payload is JSON-validated and ≤ 64 KiB ✅ ENFORCED

JS variable writes go through dedicated repo methods that wrap the
read-modify-write in a Drift transaction:

* `ChatRepo.updateSessionVarsJson(sessionId, mutator)` — `chat` scope
* `CharacterRepo.updateExtensionsJson(charId, mutator)` — `character` scope
* `GlobalVariablesRepo.update(mutator)` — `global` scope; serialized
  writes (`_writeLock`) and 64 KiB cap
* `MessageVariablesNotifier.update(sessionId, messageId, mutator)` — in-memory, not persisted

`JsBridgeService._validateJsonValue` enforces JSON compatibility
(no NaN, finite numbers, string keys, ≤ 64 KiB total per payload) and
surfaces failures as `ArgumentError` → bridge `invalid_request` code.

### INV-JS3: `glaze.triggerGeneration` respects generation mutexes (INV-C1, INV-M3/M4) ✅ ENFORCED

`GenerationDispatcher.dispatch(charId, rawMode, reason)` is the only
entry point that touches the chat notifier from a JS call. The
dispatcher returns `TriggerResult`:

* `TriggerNoSession` — no chat state for `charId`
* `TriggerBusy(busyKind: 'chat')` — INV-C1 violated
* `TriggerBusy(busyKind: 'memory_draft')` — INV-M3/M4 violated
* `TriggerAccepted` / `TriggerError`

`auto` mode resolves to `continue` (last msg = assistant) or
`regenerate` (last msg = user). The dispatcher never auto-aborts;
the JS side decides whether to retry. See
`test/trigger_generation_test.dart` for the full contract.

### INV-JS4: `glaze.playAudio` does not leak the audio session ✅ ENFORCED

`AudioBridgeService` keeps a single `AudioPlayer` per widget and
`dispose()`s it on widget dispose. `routeSource` is the pure
`@visibleForTesting` helper that maps the source string to the
matching `audioplayers` `Source` subclass. Built-in cues
(`click` / `alert` / `haptic`) bypass the audio player entirely
(`SystemSound` / `HapticFeedback`).

### INV-JS5: `executeCommand` routes `/trigger`, `/getvar`, `/setvar`, `/inject`, `/toast` to the same services as the dedicated bridge methods ✅ ENFORCED

`buildWiredCommandRegistry(WiredCommandDeps)` is the production
default. Each handler re-enters the same live `JsBridgeService` through
canonical dispatch:

* `/trigger` → `glaze.triggerGeneration`
* `/getvar` / `/setvar` → `glaze.getVariables` / `setVariables`
* `/inject` → `glaze.injectPrompt`
* `/toast` → `glaze.showToast`

The outer call must have `execute_command`; canonical dispatch then also
requires the dedicated capability (`trigger_generation`, scope-specific
variable access, `inject_prompt`, or `show_toast`). The command context is
forwarded unchanged so session, character, message, and global routing match
the dedicated method.

Sandboxed panel requests relay only through their containing Chat WebView.
Absent Chat WebView bridges produce the explicit unavailable outcome; they do
not execute or retry in a headless runtime.

`buildDefaultCommandRegistry` is retained for tests/CMS — its
handlers echo arguments. The `CommandRegistry.run` contract catches
all handler exceptions and returns `CommandResult.error`.

### INV-JS6: Periodic scheduler pauses on app background, never produces catch-up ticks ✅ ENFORCED

`SessionLifecycleTracker` bootstraps `periodicTriggerSchedulerProvider` while a
visual chat is mounted and publishes its real `charId`/`sessionId` through
`GenerationNotificationService.activeChatContext`. A tick requires that active
authority and the matching registered Chat WebView bridge; authority changes
cancel in-flight periodic execution. There is no headless fallback.

`PeriodicTriggerScheduler` is a `WidgetsBindingObserver`. On
`paused` / `inactive` / `hidden` / `detached` it cancels every timer.
On `resumed` it rebuilds the timer set from the current active preset;
the first tick after a long backgrounding period is **not** a catch-up
firing — the timer is fresh.

`_tick` is `unawaited` (fire-and-forget). `PeriodicJsBlockRunner` owns the
per-tick cancel token and executes directly through the visual bridge without
creating an `InfoBlock` row. The `debugLifecycleState` test seam in
`periodic_lifecycle_test.dart` exercises the pause/resume contract.

### INV-JS7: The message-scripts toggle stops JS and nothing else ✅ ENFORCED

Every message body goes through `sanitizeMessageHtml` before insertion —
`writeShadowContent` (`renderer/markdown.js`) and the search re-render
(`message_renderer.js`) both call it with
`{ allowScripts: allowMessageScripts }`, and neither keeps a second path.

With execution **on** the formatted HTML is inserted verbatim. With execution
**off** `stripMessageCode` removes exactly what runs code — `<script>`,
`<iframe>` / `<object>` / `<embed>`, `on…=` attributes, `srcdoc`, and
`javascript:` / `vbscript:` / non-image `data:` URLs — and touches nothing
else. No element is dropped for how it looks, and `<style>` blocks and
`style="…"` attributes reach the per-message shadow root byte-identical: the
CSS policy in `css_sanitizer.js` belongs to the ExtBlock path, which lands in
the light DOM, and is never applied to a message.

`renderer/css_diagnostics.js` is the one other pass that looks at message CSS,
and it only reads: it appends a `CSS ERROR` report next to a broken `<style>`
without changing a byte of it. `renderer/target_toggle.js` is the single pass
that *writes* message CSS — the `:target` re-key of INV-JS8 — and it runs
identically in both modes, so it never makes the toggle visible either.

So an HTML/CSS card renders the same before and after the user enables message
scripts — `position: fixed`, `url()` backgrounds, `@font-face`, `<form>` and
SVG animation all behave identically in both modes; only script execution (and
the frame elements that host it) follows the toggle.
`test/webview_assets_test.dart` pins both halves (`message HTML is filtered for
code only, never for markup`, `a message may not run code while execution is
off`).

### INV-JS8: A fragment link inside a message toggles that message's own card ✅ ENFORCED

Message bodies live in a per-message shadow root (`.message-content`), and a
URL fragment is only ever resolved against the document tree. An id written by
a message therefore never becomes the document's target element, so an
ST-style card that opens a panel with `<a href="#panel">` plus
`#panel:target { … }` renders a button that does nothing — and the WebView's
navigation policy (`chatWebViewNavigationPolicy`) cancels the navigation
anyway.

Two halves close that gap, and both are required:

* `renderer/target_toggle.js` re-keys `:target` in the message's own `<style>`
  on `[data-glaze-target]`. It runs on **every** path that writes a message
  body — `writeShadowContent` (`renderer/markdown.js`) and the search
  re-render (`message_renderer.js`) — because either one replaces the tree.
  A message without a `:target` rule keeps its stylesheet byte-identical.
* `InteractionDispatch.handleClick` resolves the clicked link through
  `composedPath()` (`e.target` is retargeted to the shadow host, so
  `e.target.closest('a')` never sees a link the message wrote) and, for a
  `#…` href, stamps that attribute on the matching element **inside the link's
  own root** instead of navigating. Document semantics are kept: at most one
  target per root, and an empty fragment (`href="#"`, what a card's close
  button uses) clears it.

Every other href still goes to Flutter as `onLinkClick` — which is also what
finally makes an ordinary markdown link inside a message open.

`test/webview_assets_test.dart` pins both halves in the group named
"`:target` cards in message HTML".

---

## 11. Message Document Contract

A message body renders into a shadow root (`.message-content`), which is what
keeps a card's CSS out of the app chrome. Cards, though, are written against a
*document* — they look elements up with `document.getElementById`, declare
functions their `onclick=` attributes call, wait for `DOMContentLoaded`, and
put a modal in `document.body`.

This section is the **whole list** of what a card may rely on inside that
shadow root. It is finite and written down on purpose: for a while each case
was found by a user and patched on its own, and the next card always found the
next hole. Implementation: `assets/chat_webview/renderer/message_document.js`
(plus `target_toggle.js` for `:target`). Every item has a case in
`test/webview_js/specs/document_contract.spec.js`.

**Add to this contract rather than shimming one more thing where it happens to
be needed.**

### INV-MR1: A message script runs in the page's global scope

A card's `<script>` is executed by appending a real `<script>` element to the
document's head, so `function toggle() {}` in the card becomes a global and the
`onclick="toggle()"` in the same card resolves. `new Function(src)()` gave the
script a function scope of its own, and the attribute pointed at nothing.

`document.currentScript` is shimmed for the duration to the element the script
was written next to, so ST-style cards that read
`currentScript.previousElementSibling` still find what they decorate. The
`<script>` is removed from the message afterwards, and so is the injected one.

### INV-MR2: The app's own document is restored exactly

Every shim is an **own property** on `document` / `window`, installed with
`Object.defineProperty` and removed with `delete`. Nothing on a prototype is
rewritten, and after a message's code has run, `document` is what it was.

App chrome appended while a message's code may be running has to say so:
`appBody()` (from `message_document.js`) returns the real body, and the
selection bar uses it. Reading `document.body` there would put the app's own
element inside somebody's card.

### INV-MR3: Document lookups find the message's own elements first

`getElementById`, `querySelector`, `querySelectorAll`, `getElementsByClassName`,
`getElementsByTagName` and `getElementsByName` search the message root first and
**fall back to the real document** when it has no answer. The fallback is what
keeps app-level code called from a card working.

### INV-MR4: The document's collections are the message's

`document.forms`, `document.images`, `document.links` and `document.styleSheets`
return the message's own, for the same reason.

### INV-MR5: An `@import` is hoisted into the document head

`@import` inside a shadow root is ignored by the browser, and a `@font-face`
can only be registered from the document — so a card that pulls a web font
this way rendered in `cursive` with nothing on screen to say why.

`hoistStyleImports` reads the `<style>` bodies as the message wrote them
(before the CSS policy strips the rule) and lifts each sheet to a
`<link rel="stylesheet" data-glaze-import>` in the document head.

The cost is deliberate and bounded:

- **only `https:`** — `http:` is a downgrade, and a `data:`/`javascript:`
  stylesheet href is rule injection rather than a font. Anything else is
  refused and reported in the message's CSS-error box.
- **each URL once**, and at most 32 per session, so a message cannot turn the
  app into a request generator.
- what remains is accepted knowingly: the sheet is fetched from a third party,
  which learns the reader's IP, and its rules apply to the whole document —
  app chrome included. `bridge/css_sanitizer.js` still rejects every `url()`
  *inside* message CSS, and `@font-face`, `@page` and `@namespace` are still
  dropped and reported (`inspectBlockedAtRules`).

### INV-MR6: `document.body` is the message's overlay layer

A node handed to `document.body` goes into `.glaze-message-overlay`, a
`display: contents` child of the message root. It lays out where the card
expected it to and stays under the card's own stylesheet, instead of rendering
naked in the app chrome. `document.head` is the message root for the same
reason: a `<style>` a card appends belongs to that message.

### INV-MR7: The load events a card waits for still arrive

The real `DOMContentLoaded` and `load` fired long before the message existed. A
`DOMContentLoaded` / `load` / `readystatechange` listener registered by a
message script — through `document.addEventListener`, `window.addEventListener`
or `window.onload` — is **collected instead of registered**, and called once the
message's scripts have all run. The app's own listeners are never touched.

### INV-MR8: The scope lasts as long as the message's code can run

A card's modal is appended from its click handler, not from its `<script>`. The
document scope is therefore re-installed for the length of any dispatch of a
common interaction event whose composed path passes through a message root, and
removed on the microtask that follows it.

Only for a message whose own code has actually run: a message with no
`<script>` never needs the scope, so for all but a handful of messages the
app's document is never touched at all.

Message scripts are off by default. With the toggle off nothing here runs at
all: `<script>` elements are dropped before insertion, and the message is still
rendered exactly as written — markup and CSS are not a script policy.

---

## Refactor PR Checklist

Before merging any structural PR:

- [ ] Chat generation produces correct responses end-to-end
- [ ] Stop generation (abort) preserves partial text when available
- [ ] Regenerate while generating aborts the current generation first
- [ ] Switching characters during generation continues background generation
- [ ] Prompt block order matches preset definition
- [ ] Vector scan runs before keyword scan; results deduplicated
- [x] Memory injection respects token budget (PR-B C13 / INV-PS4)
- [ ] History cutoff trims oldest messages first
- [ ] Summary returns a string without affecting chat state
- [x] Memory draft mutex with chat generation (PR-B C12 / INV-M3, INV-M4)
- [ ] Image generation completes after text generation (continue included — INV-CM2)
  - [ ] Extensions post-gen runs after normal/regen/continue (INV-EG1, INV-CM2)
  - [ ] Continue injects one system turn after the extended reply (INV-CM3)
  - [ ] A failed continue leaves the message untouched and toasts (INV-CM4)
  - [ ] Continue reasoning lands in the reasoning block, not the reply (INV-CM5)
  - [ ] Block chain does not start on aborted or errored generation (INV-EG4)
  - [ ] Extension cancel token is separate from chat cancel token (INV-EG5)
  - [ ] `dependsOnPrevious` blocks await the preceding block; output is chained (INV-EG6)
  - [ ] Image-gen block results stored via ImageStorageService; content = the `<img data-iig-…>` element (INV-EG7, INV-IG9)
  - [ ] JS Runner / interactive panel code runs in null-origin iframe (INV-EG8)
  - [ ] Bridge `glaze.*` calls gated by preset capabilities (INV-JS1)
  - [ ] Variable writes are atomic + JSON-validated + ≤ 64 KiB (INV-JS2)
  - [ ] `glaze.triggerGeneration` respects generation mutexes (INV-JS3)
  - [ ] `glaze.playAudio` does not leak the audio session (INV-JS4)
  - [ ] `executeCommand` wired registry routes to the same services (INV-JS5)
  - [ ] Periodic scheduler pauses on app background; no catch-up tick (INV-JS6)
  - [ ] A message's `:target` card still opens, closes and survives a search
        re-render (INV-JS8)
- [ ] Context limit exceeded shows an error to the user
- [ ] API not configured shows an error to the user
- [ ] Abort closes the TCP connection (not just UI state)
- [x] Session variables not persisted on abort/error (PR-B C11 / INV-C5)
