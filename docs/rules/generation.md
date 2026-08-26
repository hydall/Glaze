# Generation Lifecycle Rules

Mandatory rules for any code that participates in chat generation, summary, memory draft, or transport.

Full formal invariants with code references: `docs/INVARIANTS.md`

---

## Generation types and their scopes

| Type | State owner | Streaming | Abort |
|------|-------------|-----------|-------|
| Chat | `ChatState.isGenerating` per `charId` | Yes (SSE) | `AbortHandler`: `CancelToken` + `_activeGenId` |
| Image gen | `AbortHandler._imgGenCancelToken` + `isGeneratingImage` | No (one-shot) | Separate cancel token from text SSE |
| Summary (manual) | Widget-local in `summary_tab.dart` | No | Not abortable (INV-S2) |
| Summary (auto) | `AutoSummaryStage`, from `PostGenCoordinator` | No | Not abortable (INV-S2) |
| Memory draft | `MemoryBookController` | No | Per-draft `CancelToken`; mutex via `memory_active_drafts_provider` |
| Ext blocks | `ExtensionPostGenService._blocksCancelTokens` | No (per-block LLM call) | `cancelBlocks()` cancels every registered per-run token; independent of chat cancel token (INV-EG5) |
| JS extension (`glaze.generateText`) | `ActiveApiConfigProvider` (active or connection-profile slot) | No (one-shot, 55 s timeout) | Per-call `CancelToken` from the bridge handler |
| JS extension (`glaze.triggerGeneration`) | `GenerationDispatcher` | Routed through `ChatNotifier.continueMessage` / `regenerateLastAssistant` | Reuses chat + memory-draft mutex (INV-JS3) |
| JS extension periodic | `PeriodicTriggerScheduler` (`Timer.periodic`) | No (side-effect tick) | Each tick creates a fresh `CancelToken`; cancelled ticks are swallowed |

`ChatNotifier` owns `AbortHandler` per `charId` and delegates `abortGeneration()` to it.

---

## Entry paths (chat)

| User action | Orchestrator | Post-SSE (`GenerationPipeline`) |
|-------------|--------------|----------------------------------|
| Send message | `_runGeneration` → `GenerationPipeline.run()` | Yes — image tags, extensions, sync |
| Regenerate | `_runGeneration` → `GenerationPipeline.run()` | Yes |
| Continue | `ChatGenerationService.generate()` directly | **No** — see INV-CM2 |

---

## Mutual exclusion ✅ ENFORCED (PR-B C12)

Chat generation and memory draft **cannot** overlap for the same session/character:

- `MemoryBookController.generateDraft()` rejects when `chatProvider(charId).isGenerating`.
- `sendMessage` / `regenerateLastAssistant` / `continueMessage` reject when
  `memoryActiveDraftsProvider` contains the session id.

See `docs/INVARIANTS.md` INV-M3, INV-M4 and
`test/characterization/memory_draft_mutex_test.dart`.

Image generation runs after text generation completes on the normal/regen path
(`GenerationPipeline` → `processImageTags()`). Summary is independent.

---

## genId / CancelToken ownership

Every chat generation gets a unique id from `AbortHandler.nextGenId()` (monotonic
`_activeGenId`). All SSE callbacks **must** treat the generation as stale when
`!abortHandler.isCurrentGen(expectedGenId)` before mutating `ChatState`.

```dart
// Pattern passed into StreamGenerationService
isAborted: () => !abortHandler.isCurrentGen(genId),
```

`AbortHandler.setCancelToken()` attaches the Dio `CancelToken` for the active gen.
Image generation uses a separate `_imgGenCancelToken`.

---

## Abort signal chain

```
ChatNotifier.abortGeneration()
  → AbortHandler.abortGeneration()
      → _activeGenId++              ← invalidates pending callbacks
      → _cancelToken?.cancel()      ← propagates to Dio / SSE
      → _imgGenCancelToken?.cancel()
      → cancel cleaner / extension work
      → capture partial stream and clear transient streaming indicators
      → atomically persist partial/restoration against latest durable session
      → re-check generation/ref ownership
      → publish the durable session to cache/state
      → isGenerating / isPostGenRunning / isGeneratingImage → false
      → clear restoration snapshot

Separately:
  → SseClient: DioException(cancel)
  → StreamGenerationService: isAborted() → early return, isGenerating false
```

**Never break this chain.** If `CancelToken` doesn't reach `Dio`, stop only clears UI
while the TCP stream continues.

Partial/restoration persistence lives in `AbortHandler`, not in `ChatNotifier`
directly. On a conflict or persistence failure, reload the durable row; never
publish a speculative restoration. The generation mutex remains held until
this durable settlement completes. See INV-C3 in `docs/INVARIANTS.md`.

---

## State cleanup on every exit path

`ChatState.isGenerating` must return to `false` on: completion, error, abort, app
restart (`ChatNotifier.build()` fresh state). `ChatNotifier` uses `ref.keepAlive()` —
provider disposal is not a cleanup path.

---

## Prompt ordering (do not reorder)

1. Vector lorebook scan (async, `PromptPayloadBuilder`, before isolate)
2. Keyword lorebook scan (sync, `PromptBuilder`, inside isolate)
3. Merge keyword + vector (keyword wins; dedupe vector by id)
4. Memory candidate selection + excerpt packing (`memoryPackingMode`: full / hybrid / chunk_first — see `docs/ARCHITECTURE.md` §4)
5. Context cutoff — oldest messages trimmed first; deferred `{{memory}}` macro finalization runs after cutoff when `memorySelection` is present

---

## Reasoning / thinking controls

`requestReasoning=false` and/or `omitReasoning=true` mean Glaze should not ask
the transport for provider-native reasoning and should not persist reasoning
unless the provider explicitly returns it on an enabled final response. Do not
interpret these flags as a universal provider-side "thinking off" switch.

The effort scale is protocol-agnostic in the UI (`auto | min | low | medium |
high | max`, same six steps everywhere, like SillyTavern) and is translated at
send time by `converters/reasoning_effort.dart`: `auto` sends nothing, OpenAI
wire formats collapse `max` to `high` and `min` to `minimal` (GPT-5 family) or
`low`, and Anthropic/Gemini read the raw step as a share of the thinking
budget. Never widen a stored preset's effort by rewriting it on protocol
switch — resolve it at the transport instead.

`showNativeReasoning` is a **display** control and must never change what is
requested. On the Responses API it selects `reasoning.summary` only; the
`reasoning` block itself and its `effort` stay governed by
`requestReasoning` / `omitReasoning` / `omitReasoningEffort`, exactly as on
Chat Completions.

## Sampling parameters

The `omit*` flags on `ApiConfig` are the **only** switch for `temperature`,
`top_p`, `frequency_penalty` and `presence_penalty`. Never gate a parameter on
its value: `temperature: 0` and `top_p: 1` are settings a user can pick, and
suppressing them makes the slider a silent no-op that the prompt inspector
cannot show. `top_k` is the single exception — Anthropic and Gemini reject
`0`, so `0` keeps meaning "not set".

The flags are protocol-agnostic; every transport honors them. What *is*
protocol-bound is which parameters exist at all, and `ApiConfigDraft.
normalizeValues` is the one place that decides it: it clears a value the
active protocol has no field for (penalties outside the OpenAI wire formats,
`top_k` on official OpenAI and the Responses API). Keep that list in step with
the `_supports*` getters in `api_settings_screen.dart` — a value the editor
hides but normalization keeps will still go on the wire from a control the
user can no longer see.

Provider notes:
- OpenAI-compatible/custom transports omit `reasoning_effort` when reasoning is omitted.
- Anthropic/Gemini transports omit their native thinking config when reasoning is omitted.
- Gemini 3.x may still think internally by default and may report/bill thought tokens. Gemini 3.1 Pro documents thinking levels, not a guaranteed full off switch.
- Avoid sending undocumented fields such as `reasoning: { exclude: true }` globally. Add provider-specific body fields only behind explicit protocol/provider support and tests.

Studio Mode (tracker-around-generator, Phase 5+):
- Studio trackers (intermediate agents) always force reasoning off/omitted.
- The final Studio generator inherits the resolved `ApiConfig` reasoning
  settings. Studio also strips prompt-level hidden-reasoning directives from
  final-generator instructions when reasoning is disabled/omitted, but this
  only affects prompt text, not provider-internal thinking.
- One main LLM (the generator) writes the visible reply; trackers run as
  sidecars and contribute notes that shape the next prompt. Trackers do NOT
  duplicate the generator's output. Failed trackers abort the Studio turn after
  the initial attempt plus two retries; the final generator does not run with
  partial tracker output. See INV-ST5 in `docs/INVARIANTS.md`.
- Trackers with the same `(provider, model)` and `!runIndividually` are
  batched into one LLM request via `<agents><agent_task>` XML. The batch
  system prompt is cache-friendly: shared `<role>` + `<lore>` first, per-agent
  `<agents>` tail (INV-ST3, INV-ST7). Heavy trackers
  (`expression`/`illustrator`/`lorebook` name match, or explicit
  `StudioAgent.runIndividually`) run as individual requests.
- Retry chain on tracker failure: re-request the same tracker/batch twice, then
  return a hard Studio error. Missing or unparseable `<result>` blocks count as
  tracker failure and ask the user to restart generation. There is no
  individual fallback from a failed batch.
- Trackers receive `StudioAgent.contextSize` (default 5, hard-cap 200) last
  messages via `_limitTrackerHistory` + `truncateAgentText` (head 40% + tail
  60%) + `stripHtmlTags`. The generator uses a stable history window with
  `maxFinalHistoryMessages` (default 50) and a 70K-token high-water mark. After
  a completed assistant turn crosses either threshold, the boundary advances
  by roughly half the current window on a complete chunk boundary. Only
  `chat_history` rotates. See INV-ST1, INV-ST2.
- Studio presets are reusable prompt/agent configurations stored in
  `studio_preset_rows` and selected globally via `activeStudioPresetId`.
  Per-session state is limited to an on/off toggle in `studio_config_rows`.
  Agent, cleaner, and Ledger runtime settings live in the preset's
  `StudioRuntimeSettings`, not in global `PipelineSettings`.
- A normal turn resolves one immutable `StudioTurnConfigSnapshot` before prompt
  construction. Trackers, final generation, POST-cleaner, and Ledger consume
  that same snapshot; mid-turn settings/preset/API changes affect the next
  turn. Separate manual operations may resolve a fresh snapshot (INV-ST8).
- POST-processing is separate from the tracker pipeline: the POST-cleaner
  runs after the full reply and writes a blue `'cleaned'` agent sub-swipe
  via `ChatRepo.appendAgentSwipe(kind: 'cleaned')`, preserving the original
  `'final'` as the parent. Hold mode (Marinara) is NOT implemented (Phase
  1.3 decision). See INV-ST4.
- **Swipe-first streaming (UX phase):** the `'cleaned'` swipe is pre-created
  at cleaner start (empty content, parent snapshot cloned) so the blue
  switcher is visible immediately while the rewrite streams into the chat
  bubble. On completion the swipe is filled in place via
  `ChatRepo.updateAgentSwipeContent`; on failure with partial text the
  truncated text is preserved; on failure with no text the swipe is removed
  via `ChatRepo.removeAgentSwipe`. Each swipe carries its own `genTime`
  (cleaner elapsed) + `tokens` (estimateTokens) so the per-swipe badge
  persists.
- Cleaner runs are lease-owned per `(sessionId, messageId)`. A newer same-key
  run cancels and waits for the previous cleanup; superseded queued runs never
  start. Only the latest shared-state owner may publish cleaner UI/token state
  (INV-ST9).
- **Separate audit model setting:** `PipelineSettings.cleaner.postCleanerAuditModel`
  exists, but is not currently wired into runtime resolution. `CleanerStage`
  passes the same resolved `cleanerConfig` to both the character/world audit
  and the cleaner, so the setting currently has no runtime effect.
- The Studio tracker-cycle is logged in the agentic operations log as a
  `studioTracker` kind record (Phase 10). The record carries an aggregate
  `AgentOperationAttempt` covering the whole cycle elapsed time; per-agent
  breakdown (success / failure, agent names) goes into the `summary` text
  since `StudioPipelineResult` does not expose per-agent LLM attempts as a
  structured array. Records are emitted on the success path and on hard
  failure. Aborted / disabled runs are not logged.
- Live cycle status is surfaced to the chat UI via `studioCycleStateProvider`
  (Phase 11) and rendered by `StudioStatusCard` (floating card at the top
  of the chat). The cycle phases are:
  `idle → running → writingFinal → done | error`. Aborted
  runs reset to `idle`.

---

## Session variables on abort/error ✅ ENFORCED (PR-B C11)

`SavedMessageWriter` carries `pendingSessionVars`, but persistence occurs only
when `GenerationPipeline._commitGenerationResult` merges their delta into the
latest durable row via `ChatRepo.mutateSession`. Continuation uses the same
rule. Error, rollback, and abort paths do not apply the delta. See INV-C5.

---

## Continue message

`ChatNotifier.continueMessage()`:

1. Calls `ChatGenerationService.generate()` (SSE + prompt build) directly.
2. Appends streamed content to the **existing** last assistant message. That
   message's id sits in `ChatState.continuationTargetId` for the whole run, so
   the WebView streams into its bubble instead of a typing placeholder.
3. Delegates to `regenerateLastAssistant()` when a **user** message trails
   (nothing to extend — generate a reply instead).
4. Does **not** run `GenerationPipeline` post-steps (image tags, extensions, sync).

See INV-CM1, INV-CM2 before changing this path.

---

## Extension post-generation

After normal/regen completion, `PostGenCoordinator` launches
`ExtBlocksStage.launchForSwipe()` directly for ordinary generation. In Studio,
`CleanerStage` launches it after the cleaner finalizes or is skipped. Both paths
delegate to `ExtensionPostGenService.processAfterGeneration()` and then
`runBlocksForMessage()`, binding blocks to the visible final or cleaned swipe.
Failures are logged only (INV-EG2). Execution is gated by
`extensionsSettings.enabled` and the active preset id (INV-EG3). The block
chain does not start on aborted or errored generation (INV-EG4).

### Block triggers

`BlockTrigger` controls when a block runs. The chain filter is enforced by
`_runChain(trigger:)` in `ExtensionPostGenService` — the same chain is
reused for all three trigger types:

| `BlockTrigger` | Entry point | Cancel / lifecycle |
|---|---|---|
| `afterAssistant` | Ordinary: `PostGenCoordinator`; Studio: `CleanerStage`; both → `ExtBlocksStage.launchForSwipe` → `processAfterGeneration` → `runBlocksForMessage` | Registers a per-run token in `_blocksCancelTokens` (INV-EG5) |
| `afterAssistant` manual rerun | Chat WebView ext-block callback → `runBlocksForMessage` | Registers a per-run token and can replace blocks for the selected swipe |
| `afterUser` | `ChatNotifier.sendMessage` → `unawaited(_dispatchAfterUserBlocks)` → `runAfterUserBlocks` | Registers its own per-run token; fire-and-forget from the notifier's perspective |
| `periodic` | `PeriodicTriggerScheduler` → `Timer.periodic(periodicIntervalSeconds)` → `runJsBlock` (no chain) | Runs only through the currently active visual chat bridge; each tick creates a fresh token and loses authorization when active chat changes; scheduler pauses in app background (INV-JS6) |

### Block execution model

```
blocks = preset.blocks.where(enabled && trigger == requested).sortBy(order)
prevFuture = null
for block in blocks:
    blockFuture = _runSingleBlock(block, prevFuture?.content)
    if block.dependsOnPrevious:
        prevFuture = await blockFuture   // serial
    else:
        prevFuture = null                // parallel; side-effect via .then(addOrReplace)
```

- **Serial** (`dependsOnPrevious = true`): block awaits the previous block; receives its output as `previousOutput`.
- **Parallel** (`dependsOnPrevious = false`): block is launched without `await`; `unawaited(future.then(...))` writes the result via `infoBlocksProvider.notifier.addOrReplace()`.

### Block types

| `BlockType` | Engine | Notes |
|---|---|---|
| `infoblock` | `InfoBlockService` (LLM) | Result stored in `InfoBlock.content` |
| `imageGen` | `ImageGenService` (LLM agent → image API) | `<img data-iig-…>` element with a data-root-relative `src` in `InfoBlock.content` (INV-IG9) |
| `jsRunner` | Active visual chat's `ChatBridgeController.runJsBlock` | Requires the matching chat WebView bridge; script output becomes block content in a null-origin iframe (INV-EG8) |
| `interactive` | `PanelHostService` (LLM agent → sandboxed iframe panel) | HTML persisted to `InfoBlock.content`; panel is rendered as a live iframe island |

### Cancel

`ExtensionPostGenService.cancelBlocks()` cancels every token currently
registered in `_blocksCancelTokens`, covering overlapping chains and reruns.
Each `_runSingleBlock` checks its per-run token before and after every `await`;
cancelled blocks are marked `BlockRunStatus.stopped`. This does **not** affect
the chat text cancel token or in-progress image generation.

### Bridge feedback

On status change, call `ChatBridgeController.updateBlockStatus(messageId, aggregatedStatus)`.
On panel open/update, call `ChatBridgeController.showExtBlocksPanel(messageId, blocks)`.

### JS bridge abort chain

`glaze.generateText` (JS bridge → `SseClient.streamChatCompletion`) takes a
fresh `CancelToken` per call. `_generateBridgeText` in
`ChatWebViewWidget` enforces a 55-second timeout and cancels the token
on expiry. The token is independent of the chat text generation
token — aborting the chat does NOT cancel in-flight JS generate calls.

`glaze.triggerGeneration` reuses the chat path entirely — see
`GenerationDispatcher.dispatch` for the mutex / abort chain.

---

## Adding a new generation path

1. Define abort mechanism (`AbortHandler` or separate `CancelToken`).
2. Add mutual exclusion in **both** directions if it shares a `charId` / session.
3. Verify `isCurrentGen(genId)` before mutating shared state after every `await`.
4. Clear `isGenerating*` on every exit path.
5. Decide whether post-SSE steps (image tags, extensions) must run — use
   `GenerationPipeline` or document an explicit exception like continue.

---

## PR verification checklist

Before merging any generation-related PR:

- [ ] Chat produces correct responses end-to-end
- [ ] Stop preserves partial text when available (AbortHandler / INV-C3)
- [ ] Regen while generating calls `abortGeneration()` first
- [ ] Character switch does not abort other characters' generations
- [ ] Prompt block order matches preset definition
- [ ] Vector scan before keyword; merge deduplicates correctly
- [x] Memory injection respects token budget (INV-PS4)
- [ ] History cutoff trims oldest first
- [ ] Summary does not touch `ChatState.isGenerating` or messages
- [x] Memory draft mutex enforced (INV-M3, INV-M4)
- [ ] Image tags run after text on send/regen (not on continue unless changed)
  - [ ] Extensions post-gen on send/regen only (INV-EG1)
  - [ ] Block chain does not start on aborted or errored generation (INV-EG4)
  - [ ] Extension cancel token independent of chat cancel token (INV-EG5)
  - [ ] `dependsOnPrevious` blocks await preceding block; output chained (INV-EG6)
  - [ ] JS Runner / interactive panel code runs in null-origin iframe (INV-EG8)
  - [ ] Bridge `glaze.*` calls gated by preset capabilities (INV-JS1)
  - [ ] `glaze.triggerGeneration` respects generation mutexes (INV-JS3)
  - [ ] `glaze.playAudio` does not leak the audio session (INV-JS4)
  - [ ] `executeCommand` wired registry routes to the same services (INV-JS5)
  - [ ] Periodic scheduler pauses on app background; no catch-up tick (INV-JS6)
- [ ] Context limit / API-not-configured errors shown to user
- [ ] Abort closes TCP (CancelToken reaches Dio)
- [x] Session vars not leaked on abort/error (INV-C5)
