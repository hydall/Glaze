# Known Bugs — triage, grouping and fix ledger

**Source:** Trello board `GlazeFlutter` (`6a08b1a3055cd731743d9c2b`), list **Known Bugs**
(`6a08b1a3055cd731743d9c29`), cards carrying the **Audited** label
(`6a84d228f6d3b59fad11125e`).
**Snapshot taken:** 2026-09-12 — **156 cards, all 156 audited.**
**Audit source:** DeepSeek bug-triage agent (`tools/bug_triage/`), audited against `nightly`.

**22 of the 156 carry the Trello due-date checkmark (`dueComplete: true`) and are treated
as already resolved** — they are excluded from every group and from the question list.
The full list is at the bottom of `KNOWN_BUGS_QUESTIONS.md`. One consequence worth
calling out: **#145** "response in prompt inspector" is checked off, but **#153**
"response in prompt inspection doesn't work, shows 'no captured'" is not — and they are
the same defect, which is still live in the code. #153 stays in G14; #145 is dropped as
the duplicate.

The step-1 split was: **43** cards actionable, **8** closed without a code change, **22**
already resolved, **83** waiting on one sentence each. Step 2 closed all 83 — see
**Status** below for where they went, and **Part 1b** for the groups they produced.

Comment breakdown of the snapshot:

| Verdict | Cards |
|---|---|
| Real audit (Summary + root cause + proposed fix) | 46 |
| `NEED MORE INFO` — agent produced a code-level reading, but no repro from the reporter | ~25 |
| `NEED MORE INFO` — title-only card, no usable signal at all | ~85 |

That ratio is the headline: **two thirds of the board is title-only notes**, most of them
written by hand straight onto the board rather than mirrored from Discord. They are not
bad reports — they are TODO shorthand — but the triage agent cannot act on them, and
neither can I without a sentence of intent each.

---

## Status

- [x] **Step 1** — pull all audited cards, cluster them, separate the ones missing info
- [x] **Step 2** — re-cluster with your answers (`KNOWN_BUGS_ANSWERS.md`), board sorted
- [ ] **Step 3** — fix group by group, one branch per group, ledger at the bottom

### Board after step 2 (applied 2026-09-12)

| Destination | Cards | Why |
|---|---|---|
| **Known Bugs** (stays) | 156 → **111** | the working set |
| **Fixed** | +25 | you marked them done: #1 #2 #3 #5 #8 #16 #27 #46 #50 #54 #55 #56 #68 #70 #72 #74 #81 #82 #84 #85 #109 #114 #140 #142 #151 |
| **features** | +6 | #4 #48 #62 #63 #77 #156 |
| **Stale/not confirmed** (new list) | +5 | #31 #75 #80 #83 #125 |
| archived | 9 | dropped: #11 #39 #44 #67 · duplicates: #15→#7, #42, #76→#107, #129→#87, #155→#87 |

You said "новую доску" for stale — I made it a **list** on the same board
(`Stale/not confirmed`, id `6aa566f9c7d1c8f2b82ee340`) rather than a separate board, so
it sits next to Fixed and Done. Say the word and I move it to a real board instead.
Archived cards are recoverable from the board's archive, nothing was deleted.

---

## Part 1 — Fix groups (enough info to act)

One branch per group, all cut from `nightly`. `#N` is the card index in the appendix table.

### G1 — `fix/continue-overhaul` — the Continue feature — **PR [#410](https://github.com/hydall/Glaze/pull/410)**
The audit read all four as one root cause: `continueMessage()` treating a continuation
like a normal reply, and `mergeContinuationMessage` copying nothing but `content`. Half
of that was already repaired on nightly *after* the audit ran, which the audit could not
know. What was actually left:

- **#118** Token-count badge disappears after Continue (and after Regenerate) — **fixed**. The streaming window strips `.token-count-inline` out of a `.gen-stat` that survives, and the finishing update only retexted an element it assumed was still there. Also: the merge now sums both runs' `tokens`/`genTime` instead of dropping them.
- **#150** Notification and chat-list preview show the *head* of the message, not the continuation — **fixed** via a recorded `continuationOffset` that both preview surfaces slice at.
- **#110** Continue re-generates the same reply / reasoning leaks into the body — **already fixed**: INV-CM3 injects `kContinueInstruction` as a system turn, INV-CM5 files the reasoning. Verified in code, not just in the docs.
- **#119** Timeout error on Continue replaces the whole message (sev high) — **already fixed**: INV-CM4, `_continueFailure` never writes to the message.

New invariant: **INV-CM7** (a continued message keeps its stats and knows where it grew).

Files: `chat_provider.dart`, `continuation_message_merger.dart`,
`stream_generation_service.dart`, `saved_message_writer.dart`, `message_preview.dart`,
`sync_notification_stage.dart`, `renderer/message_renderer.js`.

### G2 — `fix/reasoning-render` — reasoning block rendering — **PR [#411](https://github.com/hydall/Glaze/pull/411)**
- **#45** Swipe drags only `.msg-body` — the reasoning block and game-time stay pinned, so the message tears apart mid-swipe — **fixed**. `SWIPE_TARGET_SELECTORS` now names the whole moving set and both paths (touch gesture, `animateVariantSwap`) use it; the footer deliberately stays put; each target locks its own height. Took the multi-element route rather than the audit's wrapper element, which would have changed the documented DOM contract that the bubble-layout CSS depends on.
- **#123** Reasoning box vanishes after regenerating with a non-reasoning model — **does not reproduce**. `updateMessageContent` already re-creates a missing `.msg-reasoning`; the audit was reading older code. Locked in with `specs/reasoning_block_lifecycle.spec.js` (including the swipe-back case the report was actually about) instead of being closed on my word.

Documented in `docs/rules/message-rendering.md` rather than as an INV — INV-MR1–8 are all about message scripts, which is a different subject.

### G3 — `fix/streaming-bubble-state` — typing-bubble lifecycle — **PR [#412](https://github.com/hydall/Glaze/pull/412)**
- **#141** The previous reply briefly renders as the currently-streaming bubble; duplicate messages (a regression that came back) — **duplicate half fixed, ghost half does not reproduce**.
  - The duplicate is the typing bubble of a run that ended while its chat was closed. The page is a keep-alive singleton, so it outlives the widget that holds the bubble's only record; close the chat mid-run and the widget is disposed before the falling edge that would remove it. `setMessages` carries a bubble across a re-render *on purpose* (a live run streams into that node), so the leftover is handed to the reopened chat and to every re-render after it. Reproduced in the harness first: reopening rendered `["a1","u1","a2","__streaming__"]`.
  - The ghost (previous reply re-appearing under a new send) is already closed on nightly: `_sendMessage` clears the streaming state synchronously before the bubble is painted, `closeStreamPublishing` shuts the deferred frame publish, and the reconcile is epoch-keyed. `send_window_streaming_reset_test.dart` guards it.
  - The **persisted** duplicate the audit flagged as "worth verifying on the writer/commit path" is not reachable: `commitGenerationResult` rejects a second commit on its tail anchor, and `SavedMessageWriter` rebuilds from the base session rather than appending to its own output. Said so in the PR rather than claiming a fix for it.
- **#131** The "Generating" bubble never returns when you leave and re-enter a chat mid-generation — **mostly stale; the clock half fixed**. The audit's proposed fix is already in nightly (`_resetStreamingPresentationState()` at the top of `_initWebViewOnce` plus a level-triggered `_reconcileActiveGenerationPresentation` after it). What was still broken was the elapsed clock: the page never received `setSendPending` at init, only its Dart-side mirror, so a chat reopened inside the send window showed a bubble that did not tick.

The ledger's guess at the shared root held up: the placeholder was **edge-triggered
and multi-owner**, and the fix is both halves of making it level-triggered —
`retireTypingPlaceholder()` before the paint that reopens a chat, and an idle
reconcile that retires rather than only clearing its flags. Documented as
**INV-C8**.

Deliberately left alone: the falling edge's `if (!state.regenStreamingSent)` guard,
which the audit wanted made unconditional. I could not construct a state where both
streaming flags are true at once, and the level-triggered half now covers a missed
edge from any direction — so making it unconditional would add a bridge call on
every regen falling edge to guard a case that does not exist.

### G4 — `fix/catalog-auth-resilience` — **PR [#416](https://github.com/hydall/Glaze/pull/416)**

Shared shape confirmed: each provider holds a credential its server can stop honouring,
and exactly one code path per provider knew how to replace one. Every other path
reported the rejection verbatim behind a Retry that re-sent the same dead credential.

- **#104** DataCat card detail → `HTTP 403: Forbidden` — **fixed**. Every authenticated
  DataCat call now runs through one wrapper that drops the stored session token on a
  401/403, re-identifies and asks again once. The browse path's throwaway probe
  (`datacatEnsureSession` / `datacatValidate`) went with its only caller, so browsing
  costs one request per page instead of two.
- **#113** raw Turnstile JSON in the dialog — **half fixed here**. The DataCat side (a
  card read that 403s and cannot recover) is this PR; the raw blob itself is
  `_extractApiMessage` returning a whole string body, which is G5.
- **#152** JanitorAI browse/search/pagination → `session expired (401)` — **fixed**, and
  **the audit was stale**: it asked for a page reload + retry on 401, which
  `_fetchLocked` already does (`janitor_webview_proxy.dart`). What was missing was an
  answer for a 401 that survives the refresh. A public read now retries with the
  refused token left off, gated by `janitorReadIsPublic` — an allowlist, default-deny,
  GET only. The stored session is left alone: a JWT the server would not take is not
  evidence the login is finished.
- **#89** (item 1) Janny search → 400 "bad syntax" — **fixed as far as code can go
  without the backend**. The request was asking for `facets`, `attributesToHighlight`,
  `attributesToCrop` and `cropMarker` — all four land in Meilisearch's `_formatted`
  block or its facet distribution, **neither of which the provider reads**, and each is
  a clause the backend can reject. Sending only what is read removes four ways for
  search to die. A 400 now also retries without the `sort`, then without the optional
  filter clauses; `isNsfw = false` is never dropped, because a degraded search that
  answers with what somebody asked to be spared is worse than no answer. Items 2 and 3
  of that card stand as the audit found them: 2 is already fixed in nightly
  (per-swipe `isError` in `swipesMeta`), 3 is a feature request and the WebView login
  exists for a real reason (CF binds `cf_clearance` to the solving client's JA3).

Deliberately not done: the catalog grid still renders `state.error` as a bare centered
`Text`. A retry/login affordance there is UI work, and with a public read no longer
dead-ending there is no dead end left to act on. Janny's `/hampter/script/*` reads are
not on the anonymous allowlist either — they may well be public, but nothing
demonstrates it.

### G5 — `fix/error-surface-normalization` — **PR [#417](https://github.com/hydall/Glaze/pull/417)**

Shared shape: the string a failure produced was shown without anyone deciding it was
worth reading.

- **#113** (client half) raw server body in the dialog — **fixed**, and the cause is
  narrower than the audit guessed. Dio parses JSON only when the request asked for it,
  and `catalog_http.dart` asks for `ResponseType.plain` (its hosts answer HTML as
  readily as JSON). So `{"error":{"message":…}}` reached `_extractApiMessage` as a
  **String**, every shape-aware branch below was skipped, and the String branch
  returned the whole body. A text body is now decoded first and read through the same
  shapes; an unrecognized JSON object adds nothing to the localized status line; a
  block page is dropped; every message is capped at 300 chars (the same string lands
  in a modal, a toast, and one line of a memory card); an error wrapped in a
  single-element array is read too. Meilisearch's top-level `message` is deliberately
  preserved — it names the refused clause, which is the whole diagnosis for the Janny
  400 G4 added a retry for.
- **#105** bare `HTTP 308` — **fixed**. A redirect reaches `formatError` as an error
  because dart:io follows 301/302/307/308 for a GET and refuses to for a POST, which
  every completion request is. The four codes now carry a description, a line naming
  the endpoint as the thing to fix, and the `Location` the server pointed at — the
  answer the server actually gave, instead of the maintainer having to say "check your
  url endpoint" by hand. Following it automatically is deliberately **not** done: the
  request carries the API key and a redirect may point at another host. The 401 half of
  that card stands as misconfiguration; it is already mapped and already reads.
- **#120** memory draft shows the Dio dump — **fixed**. The failure goes through
  `formatError` once before it is persisted, so the card and the toast say the same
  thing. Also fixed from the same screenshot: the card kept showing the failure it was
  *currently retrying*, because a draft stays `needs_regeneration` until the new
  attempt lands — "Generating… 21.6s" with the previous error in red underneath.

13 new tests; 10 fail with `lib/` reverted to nightly, and the three that pass either
way are the negative controls. `error_format.dart` is also edited by open PR #415, so
this branch keeps `_formatHttpError`'s four return lines byte-identical and builds the
redirect line into the `header` expression above them — noted in the PR.

### G6 — `fix/cloud-sync` — cloud sync (4 cards)
- **#107** Google Drive: `401 invalid_client` for every user — the shipped OAuth client is revoked. **Needs a fresh Google Cloud OAuth client (PKCE, no secret); this is an ops task as much as a code one.**
- **#115** Dropbox `OAuth state mismatch` on every retry until the app restarts — callbacks are keyed per provider, not per attempt
- **#124** After a pull the open chat stays stale — `invalidateDataProviders()` never touches `chatProvider(charId)` or `ChatSessionService`'s static cache
- **#134** App Settings never sync — no manifest entity covers those SharedPreferences keys

### G7 — `fix/backup-onboarding-polish` (2 cards)
- **#24** The backup *export* button shows the *import* label (`backup_progress_preparing` is shared between both flows)
- **#111** The onboarding "Import Data" sheet also offers **Export** on a fresh install

### G8 — `fix/lorebook-activation-scope` — **PR [#413](https://github.com/hydall/Glaze/pull/413)**
- **#99** Importing a character with lorebooks enables them **globally** — **fixed on the write side**. `convertJanitorScript` now stamps `enabled: characterId == null` (the contract the capture sheet already documents), and `JsLorebookImporter.importCharacterBooks` stops copying the card's own `character_book.enabled` into Glaze's Global switch. Both keep working where they should: `LorebooksNotifier.put` registers a character-scoped book in the activation map.

**Rejected the audit's read-side fix.** It wanted `activeLorebooksFor` to gate
`enabled` on the scope fields. But those fields are a *denormalised mirror* of the
activation maps — `_applyActivations` in the Connections sheet writes the first
linked id into them — so a book the user made global **and** pinned to a character
carries `enabled: true` + `activationScope: 'character'`, byte-identical to a bad
import. Gating would silently un-globalize every one of those. Left a comment where
the branch lives so the next reader does not try it again.

**Known limitation, raised in the PR:** a book imported *before* this change stays
global, and no migration can tell it apart from a deliberately global+pinned book.
One tap on Global in its Connections sheet clears it. Asked whether to migrate
anyway and accept the false positives.

Also found: all three cases in `lorebook_activation_test.dart` were passing through
the `enabled` branch — the fixture left it at its default `true`, so none of them
exercised the scope it was named after. Fixed the fixtures; all three still pass,
now for the stated reason.

The thread's "this character comes with a lorebook" notice is a feature → feature list.

### G9 — `fix/janitor-greetings` (1 card)
- **#98** Local JanitorAI extraction keeps only the first greeting (`alternateGreetings` is never populated although the fetched meta carries `first_messages`); the DataCat path drops the primary greeting on some cards

### G10 — `fix/vision-capability` (1 card)
- **#95** Switching to a non-vision model after sending an image → `HTTP 400` — **fixed as what it is: an illegible failure.**

Two things checked first. Glaze really cannot know whether the active model is
multimodal: `ApiConfig` carries no capability field, and the only model-listing
helper (`EndpointNormalizer.modelsUrl`) is used by image-gen alone. And the remedy
already exists and works — `imageHidden` drops the attachment in all three prompt
builders (`history_assembler.dart`, `fallback_prompt_builder.dart`,
`studio/studio_stream_interceptor.dart`). Verified all three.

So what was actually broken was the message: a bare `HTTP 400 - Bad Request` naming
nothing the reader can connect to a picture they attached three messages ago.
`formatError` now appends a hint when a 400/415/422 came back from a request that
really did carry an image part, in any of the four shapes the transports build
(OpenAI `image_url`, Responses `input_image`, Anthropic `image`, Gemini
`inline_data`) plus a pre-encoded body. Depth-limited walk, so an error over
megabytes of base64 stays fast.

**Routed to the feature list:** the audit's per-config "supports images" flag with
model-catalog auto-detection, composer blocking and history filtering. That is new
configuration surface, a migration and settings UI — and it is exactly what the
maintainer said in-thread he would "figure something out" for.

### G11 — `fix/imggen-timer-cache` (1 card)
- **#97** The image-gen timer does not reset on retry — the formatter memoizes `[IMG:GEN]` output *including* its `data-start` timestamp

### G12 — `fix/ol-start` (1 card, tiny)
- **#136** `0. test` renders as `1. test` — the ordered-list branch discards the number and emits `<ol>` with no `start`

### G13 — `fix/audio-embed-overflow` (1 card)
- **#100** The audio embed is wider than the bubble and paints outside its rounded border

### G14 — `fix/prompt-inspector` (3 cards)
- **#106** The bottom action row sits under the Android nav bar — the sheet is shown without `useSafeArea: true`
- **#153** The Response tab always shows "no captured" — the main request carries no `callId`, so no call event is ever joined to it
- **#101** The `Images` tab label is not centred in its pill (`GlazeTabBar`)

(#145 was the duplicate of #153 and is already checked off on the board; #35 "prompt inspector i18n" is checked off too, so the hardcoded-English findings there are considered done.)

### G15 — `fix/update-checker` (2 cards)
- **#132** The update sheet offers a build **14 days older** than the installed one — availability is decided on SHA inequality alone
- **#137** The update popup only appears at launch; nothing re-checks on resume

### G16 — `fix/notification-icon` (2 cards)
- **#149** The notification icon randomly shows the card image / a first letter / nothing, and the small icon is the generation spinner
- **#9** (notifications) — everything else in that card works; what is left is exactly this: the new-message small icon must be an envelope, not the generation spinner. Same fix, same file — merged here.

### G17 — `fix/draft-clear-on-send` (1 card)
- **#121** The last sent message reappears in the composer after a reload — **fixed**, three holes, not one.

The draft lives in `chat_sessions.draft`, is re-seeded into the input from
`state.session.draft` on every chat open (the notifier is `keepAlive`, so that value
outlives the screen), and was cleared as a *side effect* of whichever append variant
the send happened to take:

1. `appendUserMessageAndAcceptCurrentVariation`'s idempotent (`didAppend == false`)
   branch reports the send as accepted **without** clearing the draft, and the
   session it returns is published into `ChatState` and the session cache. The one
   branch that leaks the sent text specifically.
2. `ChatDraftController.saveDraft` skipped a write whose text matched the in-memory
   draft. `ChatState`'s copy is not evidence about the column — the controller's own
   count guard abandons the publish when the message list moves under the write, so
   state can believe the draft is empty while the row still holds text, and the empty
   write that would clear it was the one being skipped.
3. The clear was left to the 500 ms input debounce, which `dispose` cancels outright.
   Leave the chat right after sending and nothing ever cleared the row.

Draft writes now go through `ChatSessionWriteQueue` — the queue every other durable
session write already uses — so a draft write and the send's append are ordered
instead of racing, and `expectedMessageCount` is read when the write's turn comes up
instead of before the wait. A draft typed *during* a slow send used to carry the
pre-append count and be rejected outright, which lost the user's next message.

No migration needed: `_handleSend` now pushes the empty draft through on the tap, so
the next send in an affected chat clears whatever an older build left behind.

**The audit's interleaving no longer exists.** It describes `_handleSend` clearing the
composer only after the durable append; `nightly` clears it on the tap, which cancels
and re-arms the debounce with an empty controller. Could not construct the reporter's
exact repro from the current code, and the card carries no repro steps — said so in
the PR.

### G18 — `fix/promptworker-throughput` (2 cards)
- **#126** An ST-imported character → `PromptWorker request timed out after 60000ms`
- **#127** PromptWorker overwhelmed by many lorebooks / regexes

Same worker, same 60 s hard cap, same single-request isolate. Sizing work, not a one-liner.

### G19 — `fix/saucepan-import-phase` (1 card)
- **#117** A failed vetted-provider extraction keeps showing "Importing…" for ~3 minutes; the poll loop only looks for a `characterId` and never treats a terminal-without-card run as an error

### G20 — `fix/memory-auto-generate` (1 card)
- **#122** Memory-book drafts are auto-*created* but never auto-*generated*; `autoGenerateEnabled` has no consumer, yet the toggle is shown. Either wire it up or stop advertising it

### G21 — `fix/docs-and-readme` (4 cards, docs only)
- **#116** The README Discord badge renders "invalid server" — guild id and invite do not match
- **#33** The README "Download the latest release from Releases" link is `../../releases`, which resolves above the repository
- **#23** (nightsyr mention) — credit nightsyr in the README as an honorary tester, alongside the testers listed in the app
- **#146** — glossary entry stating that Glaze's local tokenizer is an estimate and can differ from the provider's count; all languages (`glossary_en.json` + `glossary_ru.json`)

### G22 — `fix/tab-scroll-position` (1 card)
- **#61** Discover ⇄ My Characters loses the scroll position (`TabSlideSwitcher` disposes the outgoing child)

### G23 — `fix/spoiler-reveal` (1 card)
- **#112** Spoiler text in the character Info box renders as a blank white block, and tapping does not reveal it

### G24 — `fix/chat-perf` (2 cards) — large, schedule separately
- **#91** Opening the character card from inside a chat drops FPS (hybrid-composition WebView blended under a translucent sheet)
- **#92** Fast scrolling in a long chat is sluggish (`findRowAtScrollTop` is a linear scan, `renderDOM` thrashes, per-message shadow roots, bridge calls every frame)

You already scheduled an overhaul for 0.7.1 in-thread — this group should follow that
plan rather than pre-empt it.

### Closed without a code change (verified against `nightly`)
| # | Card | Why |
|---|---|---|
| 139 | Messages not saving edits | Fixed by PR #350; the fix is in the tree |
| 89 (item 2) | Error warning on all generations of a message | Fixed — error state is per-swipe in `swipesMeta` |
| 96 | Image gen error (404) | Verbose Dio text already replaced by PR #357; the 404 is provider config |
| 103 | Summary generation not working | Provider-side HTTP 500; reporter confirmed it works elsewhere |
| 105 | HTTP 401 | User misconfiguration — the 308 half is fixed in G5 ([#417](https://github.com/hydall/Glaze/pull/417)) |
| 102 | Buttons look different outside settings | Your call in-thread: "Left as is for now" |
| 94 | `**` greying out `""` | Works as intended; parsing order via Themes is research |
| 108 | Can't view previous gens while regenerating | Intended, reframed as a feature request |
| 93 | Tavo backup import | Feature disabled in code (`tavoImportEnabled = false`) |
| 90 | Can't switch between quick access panels | The controller already implements switch-in-place; needs a re-test, not a fix |

---

## Part 1b — groups added in step 2 (from your answers)

### G25 — `fix/chat-first-open` (2 cards, Android) — highest value of the new set
- **#87** On Android the chat opens with **no messages rendered** and has to be reopened. Sometimes the **bridge connection is lost** on top of that, and then the edit / regenerate buttons under a message do nothing.
- **#154** merged here: display regexes are "not always" applied when a chat opens — the WebView initializer reads the async display-regex provider with `valueOrNull`, so an empty list gets baked into that first render.

Both are the same subsystem as G3 (bridge/WebView init), but a different failure: G3 is
the streaming placeholder, G25 is the initial `setMessages` + bridge handshake. #129 and
#155 were archived as duplicates of #87.

### G26 — `fix/keyboard-inset` (1 card, iOS + Android)
- **#7** Opening the keyboard adds the keyboard padding **into the chat container**, so you can scroll that padding and see a block of empty space, and the WebView scrolls as well. On iOS it is worse: editing a message gives a scroll with **no inertia**. (#15 "editing padding" was the duplicate and is archived.)

### G27 — `fix/protocols-pipeline` (2 cards)
- **#71** Make Summary generation run through the **common generation pipeline with protocols**, the same one the chat uses
- **#133** Same check for extblocks — verify they go through that pipeline and inherit its error handling

### G28 — `fix/permissions-and-battery` (4 cards)
- **#29** The system notification prompt fires immediately on app open. It must become an **onboarding step** with Allow / Skip buttons, explaining that notifications are what enable background generation
- **#30** Remove the battery-optimization dialog entirely
- **#53** Battery Saver becomes a **three-state setting** — System / On / Off — defaulting to System (follow the OS power-save mode)
- **#52** In Battery Saver the generation placeholder must show `0s` immediately instead of waiting a full tick

### G29 — `fix/presets` (3 cards)
- **#47** Studio presets stay invisible until a restart (`StudioPresetWorkflowService.importPreset` does not invalidate `studioPresetListProvider`). Also: they must **sort normally** instead of sticking to the bottom of the list after the regular ones
- **#79** When the active preset lives in a folder, opening the preset list should open **that folder** straight away
- **#25** User-set preset images are not displayed

### G30 — `fix/editor-ui` (4 cards)
- **#88** The stash button Danvi put in the prompt-block row moves **into the open prompt-block editor**, next to Delete; both buttons go to the header on the right, styled like the chat-input buttons (icon only, no text)
- **#57** First messages render badly in the character sheet's Prompt Blocks: make them **one block with sub-blocks**, labelled `First message #1`, `First message #2`, …
- **#59** A long character name in the character-sheet header rides upward — make it scroll top-to-bottom and loop
- **#143** Remove the depth-prompt block from Edit Character → Additional settings entirely (it is not needed, which also disposes of the untranslated placeholder)

### G31 — `fix/jar-background` (1 card)
- **#58** JAR extraction dies when the app is backgrounded. Backgrounding must not kill it — the same foreground-service treatment generation already gets

### G32 — `fix/janitor-custom-tags` (1 card)
- **#69** Catalog filters must offer JanitorAI's live popular custom tags: read `top_custom_tags` from `https://janitorai.com/hampter/characters` and append them **after** the standard tags. Search already works

### G33 — `fix/st-lorebook-settings` (1 card)
- **#135** Per-book lorebook settings do not survive an ST import or a Glaze→ST→Glaze round trip (`settings: null`, entry `caseSensitive`/`matchWholeWords` pinned false, exporter never serializes `Lorebook.settings`). Cross-check the real semantics against the SillyTavern repo before writing the mapping

### G34 — `fix/android-file-picker` (1 card)
- **#32** On Android, newly written files are missing from the system file picker when the Glaze directory is reached through the **Downloads shortcut**; it has to be opened from the device root

### G35 — `fix/message-delete-race` (1 card)
- **#78** Deleted messages sometimes come back after certain actions. Needs reproducing first — the deletion path is the suspect, not the session path (#2 and #75 are already off the board)

### G36 — `fix/sheet-flicker` (1 card)
- **#148** Editing the summary makes the **whole sheet flash white**; `SheetView` is the suspect

### G37 — `fix/guided-ui` (1 card)
- **#6** Port the Vue Guided Generation UI **1:1** — the current one is rough, and the preset editor still has no way to edit the guided prompts

### G38 — `fix/shino-default` (1 card)
- **#28** Ship Shino (`default_shino`) as the default preset for **fresh installs** and drop `Default Chat`

### New functionality with a spec — not a bug, kept separate
- **#60** Add prompt editing for JAR (how lorebook keys get built, etc.) under **Third Party Providers**; during lorebook extraction a settings button appears in the header that leads there. You gave a full spec, so it is not going into `features` blind — but it is new functionality, so it queues after the bug groups.

### Verify-only — check the code, then close or reopen
You answered "seems fixed, but check" on these. No branch until the check says otherwise.

| # | Card | What to verify |
|---|---|---|
| 12 | no proxy for jar | Can local extraction switch between JLLM and a proxy and back? |
| 43 | separate advanced/simple closed lorebooks | Do advanced and simple books already take different extraction pipelines? |
| 49 | prompt inspector sab | "sab" = safe bottom area — overlaps G14 #106; confirm it is covered |
| 73 | search on pc | Desktop search |
| 128 | 405 Naistera | Believed fixed by the sillyimages port |
| 130 | decouple embedding settings | Believed already decoupled |
| 138 | trigger type dropdown in memory books | Believed fixed by the Memory Books redesign (#408) |

### Stays on the board, not mine to fix
- **#10** handle idiots on datacat — you are doing this by hand; it stays in Known Bugs

## Part 2 — Cards missing information — closed

All 83 were answered in `KNOWN_BUGS_QUESTIONS.md` / `KNOWN_BUGS_ANSWERS.md`. Outcome:

| Outcome | Cards |
|---|---|
| Already fixed → **Fixed** list | 25 |
| Change requests → **features** list | 6 |
| Unconfirmed → **Stale/not confirmed** list | 5 |
| Dropped or duplicate → archived | 9 |
| Folded into an existing group | 3 (#9→G16, #23+#146→G21, #154→G25) |
| New groups G25–G38 | 24 |
| Verify-only | 7 |
| Yours to do by hand | 1 (#10) |

One correction worth recording: `KNOWN_BUGS_QUESTIONS.md` listed #13 "testers" and #14
"read mark" under "Прочее" by mistake — both already carry the board checkmark and were
never open questions. Your answers skipped them correctly.

## Part 3 — Fix ledger

One row per group. A group is `done` only once `flutter analyze` and `flutter test` are
green and the PR is open against `hydall/Glaze:nightly`. Per your call I move the group's
cards to **In Progress** when the branch is cut and to **Done, not tested** once the PR
merges.

**Waves 1–4 are the order you picked.** Waves 5–7 are my placement of the groups that
only existed after step 2 — reorder freely. One note: **G25 (chat blank on first open,
Android)** is the strongest candidate to jump into wave 1 — it is a "the chat does not
work" bug and it shares its subsystem with G3, so doing them together is cheaper than
doing them apart.

| Wave | Group | Branch | Cards | Status | PR | Trello |
|---|---|---|---|---|---|---|
| 1 | G1 continue-overhaul | `fix/continue-overhaul` | 118, 150 (119, 110 already fixed) | **in review** | [#410](https://github.com/hydall/Glaze/pull/410) | 118+150 In Progress · 119+110 Fixed |
| 1 | G2 reasoning-render | `fix/reasoning-render` | 45 (123 covered, not reproduced) | **in review** | [#411](https://github.com/hydall/Glaze/pull/411) | both In Progress |
| 1 | G3 streaming-bubble-state | `fix/streaming-bubble-state` | 141, 131 | **in review** | [#412](https://github.com/hydall/Glaze/pull/412) | both In Progress |
| 2 | G8 lorebook-activation-scope | `fix/lorebook-activation-scope` | 99 | **in review** | [#413](https://github.com/hydall/Glaze/pull/413) | In Progress |
| 2 | G10 vision-capability | `fix/vision-capability` | 95 | **in review** | [#415](https://github.com/hydall/Glaze/pull/415) | In Progress |
| 2 | G17 draft-clear-on-send | `fix/draft-clear-on-send` | 121 | **in review** | [#414](https://github.com/hydall/Glaze/pull/414) | In Progress |
| 3 | G4 catalog-auth-resilience | `fix/catalog-auth-resilience` | 104, 113, 152, 89 | **in review** | [#416](https://github.com/hydall/Glaze/pull/416) | all four In Progress |
| 3 | G5 error-surface-normalization | `fix/error-surface-normalization` | 113, 120, 105 | **in review** | [#417](https://github.com/hydall/Glaze/pull/417) | all three In Progress |
| 4 | G12 ol-start | `fix/ol-start` | 136 | not started | — | — |
| 4 | G13 audio-embed-overflow | `fix/audio-embed-overflow` | 100 | not started | — | — |
| 4 | G21 docs-and-readme | `fix/docs-and-readme` | 116, 33, 23, 146 | not started | — | — |
| 4 | G22 tab-scroll-position | `fix/tab-scroll-position` | 61 | not started | — | — |
| 5 | G25 chat-first-open | `fix/chat-first-open` | 87, 154 | not started | — | — |
| 5 | G26 keyboard-inset | `fix/keyboard-inset` | 7 | not started | — | — |
| 5 | G35 message-delete-race | `fix/message-delete-race` | 78 | not started | — | — |
| 5 | G36 sheet-flicker | `fix/sheet-flicker` | 148 | not started | — | — |
| 6 | G27 protocols-pipeline | `fix/protocols-pipeline` | 71, 133 | not started | — | — |
| 6 | G28 permissions-and-battery | `fix/permissions-and-battery` | 29, 30, 53, 52 | not started | — | — |
| 6 | G29 presets | `fix/presets` | 47, 79, 25 | not started | — | — |
| 6 | G30 editor-ui | `fix/editor-ui` | 88, 57, 59, 143 | not started | — | — |
| 6 | G16 notification-icon | `fix/notification-icon` | 149, 9 | not started | — | — |
| 6 | G34 android-file-picker | `fix/android-file-picker` | 32 | not started | — | — |
| 6 | G38 shino-default | `fix/shino-default` | 28 | not started | — | — |
| 7 | G6 cloud-sync | `fix/cloud-sync` | 107, 115, 124, 134 | not started | — | — |
| 7 | G7 backup-onboarding-polish | `fix/backup-onboarding-polish` | 24, 111 | not started | — | — |
| 7 | G9 janitor-greetings | `fix/janitor-greetings` | 98 | not started | — | — |
| 7 | G11 imggen-timer-cache | `fix/imggen-timer-cache` | 97 | not started | — | — |
| 7 | G14 prompt-inspector | `fix/prompt-inspector` | 106, 153, 101 | not started | — | — |
| 7 | G15 update-checker | `fix/update-checker` | 132, 137 | not started | — | — |
| 7 | G18 promptworker-throughput | `fix/promptworker-throughput` | 126, 127 | not started | — | — |
| 7 | G19 saucepan-import-phase | `fix/saucepan-import-phase` | 117 | not started | — | — |
| 7 | G20 memory-auto-generate | `fix/memory-auto-generate` | 122 | not started | — | — |
| 7 | G23 spoiler-reveal | `fix/spoiler-reveal` | 112 | not started | — | — |
| 7 | G31 jar-background | `fix/jar-background` | 58 | not started | — | — |
| 7 | G32 janitor-custom-tags | `fix/janitor-custom-tags` | 69 | not started | — | — |
| 7 | G33 st-lorebook-settings | `fix/st-lorebook-settings` | 135 | not started | — | — |
| 7 | G37 guided-ui | `fix/guided-ui` | 6 | not started | — | — |
| — | G24 chat-perf | `fix/chat-perf` | 91, 92 | deferred to the 0.7.1 overhaul | — | — |
| — | JAR prompt settings | — | 60 | new functionality, queued after the bugs | — | — |
| — | verify-only | — | 12, 43, 49, 73, 128, 130, 138 | pending code check | — | — |


---

## Appendix — all 156 audited cards

`#` is the index used throughout this document. `verdict` is what the triage
agent concluded; `bucket` is where this document puts the card.

| # | Card | Title | Verdict | Bucket |
|---|---|---|---|---|
| 1 | [fa2a1c](https://trello.com/c/EjXac5ww) | background generation | need-info | 2b ask |
| 2 | [b0e77b](https://trello.com/c/5jkm7Qrt) | i tried this build. new chat seems to be broken? when i delete an older cha… | need-info | 2a confirm |
| 3 | [70b113](https://trello.com/c/egE9fEPr) | memory books gui | need-info | 2b ask |
| 4 | [b5774e](https://trello.com/c/VQXv7Swb) | extblocks gui | need-info | 2b ask |
| 5 | [81cef3](https://trello.com/c/qs8LokL2) | lorebooks gui | need-info | 2b ask |
| 6 | [83e445](https://trello.com/c/nEGBEz6f) | guided | need-info | 2a confirm |
| 7 | [08ec95](https://trello.com/c/1Zt0altx) | https://t.me/c/3873909202/6945 | need-info | 2b ask |
| 8 | [f79f4b](https://trello.com/c/GvujVDFs) | https://t.me/c/3873909202/6946 | need-info | 2b ask |
| 9 | [ff66bc](https://trello.com/c/USnIXOPL) | notifications | need-info | 2a confirm |
| 10 | [f30174](https://trello.com/c/IVR1zbvr) | handle idiots on datacat | need-info | 2b ask |
| 11 | [a0833e](https://trello.com/c/t79pwRlU) | image on nonimage modal | need-info | 2b ask |
| 12 | [7e92b9](https://trello.com/c/ciQwnv9H) | no proxy for jar | need-info | 2b ask |
| 13 | [eb0d21](https://trello.com/c/MOaQYrYN) | testers | need-info | **resolved (✓)** |
| 14 | [f70b81](https://trello.com/c/dyI6VFqr) | read mark | need-info | **resolved (✓)** |
| 15 | [4ec3c1](https://trello.com/c/jmDsEqH5) | editing padding | need-info | 2b ask |
| 16 | [80c741](https://trello.com/c/HbIrhFuW) | keyboard padding jump | need-info | 2b ask |
| 17 | [a0c71d](https://trello.com/c/wtnTt9sz) | markdown image control | need-info | **resolved (✓)** |
| 18 | [03a675](https://trello.com/c/nNrvTKTL) | repo url in about | need-info | **resolved (✓)** |
| 19 | [cea47d](https://trello.com/c/b0WZDm98) | wire API settings in onboarding | need-info | **resolved (✓)** |
| 20 | [3b7641](https://trello.com/c/iqjOLrfi) | select persona from onboarding | need-info | **resolved (✓)** |
| 21 | [e8b0b7](https://trello.com/c/WAqmNxbb) | bubbles in onboarding not setting | need-info | **resolved (✓)** |
| 22 | [18318d](https://trello.com/c/VX3e25DH) | https://files.kammii.org/tACftoO2qI.webp | need-info | **resolved (✓)** |
| 23 | [2944d2](https://trello.com/c/hyobyNMv) | nightsyr mention | need-info | 2b ask |
| 24 | [67b217](https://trello.com/c/zn9xBols) | preparing import on backup export | audit | G7 |
| 25 | [44b8ee](https://trello.com/c/0Xo40GQQ) | preset images | need-info | 2b ask |
| 26 | [3df33b](https://trello.com/c/zJ6irDqA) | edit button square | need-info | **resolved (✓)** |
| 27 | [0842bd](https://trello.com/c/HF3GMtWA) | variations of a character | need-info | 2b ask |
| 28 | [7cb5c3](https://trello.com/c/Gwnz3N1E) | shino as default | need-info | 2b ask |
| 29 | [95779e](https://trello.com/c/ucBhQJve) | notifications dialog | need-info | 2b ask |
| 30 | [2844d3](https://trello.com/c/zJASudBx) | battery dialog | need-info | 2b ask |
| 31 | [c2cd53](https://trello.com/c/jFbE6YE5) | pc backup import | need-info | 2b ask |
| 32 | [4dd67c](https://trello.com/c/tJcclPdj) | backup file pick | need-info | 2b ask |
| 33 | [301ea5](https://trello.com/c/aihmASTR) | download button in readme | need-info | G21 |
| 34 | [73afb8](https://trello.com/c/FNlCXdWR) | even height magic drawr | need-info | **resolved (✓)** |
| 35 | [8fdfaa](https://trello.com/c/74uBMV7Z) | prompt inspector i18n | need-info | **resolved (✓)** |
| 36 | [f9914d](https://trello.com/c/xiDJGeK2) | load multiple presets and lorebooks | need-info | **resolved (✓)** |
| 37 | [f35605](https://trello.com/c/CrQbBNLA) | pill for idle button | need-info | **resolved (✓)** |
| 38 | [319fbd](https://trello.com/c/AEaOCf8b) | sorting as an icon | need-info | **resolved (✓)** |
| 39 | [899d7b](https://trello.com/c/60sN2X4u) | post a message when action is started/denied | need-info | 2b ask |
| 40 | [12681e](https://trello.com/c/HNV2vrWN) | variation header | need-info | **resolved (✓)** |
| 41 | [0c7c6b](https://trello.com/c/ldTasjRu) | icons in bottom sheet | need-info | **resolved (✓)** |
| 42 | [c8a6b2](https://trello.com/c/ggN5fw4L) | https://janitorai.com/ru/characters/22598517-89e1-43d1-9202-de24f83d4b4d_ch… | need-info | 2b ask |
| 43 | [2d04a5](https://trello.com/c/DTnkNJdX) | separate advanced and simple closed lorebooks in jar | need-info | 2a confirm |
| 44 | [af27f7](https://trello.com/c/LBnUUvgi) | for open advanced show "convert button" | need-info | 2b ask |
| 45 | [355e82](https://trello.com/c/WzWos75A) | swipe reasoning block too | audit | G2 |
| 46 | [4317f0](https://trello.com/c/C71iUa0V) | hide presets that are in folder | need-info | 2a confirm |
| 47 | [b86aeb](https://trello.com/c/AjnPaLhh) | imported presets are not visible until a reboot | need-info | 2a confirm |
| 48 | [7fb114](https://trello.com/c/2nSfw8p5) | folders in usual presets | need-info | 2b ask |
| 49 | [33c843](https://trello.com/c/lBWx0QmK) | prompt inspector sab | need-info | 2b ask |
| 50 | [89688e](https://trello.com/c/41UUgjHi) | magic drawer loading | need-info | 2b ask |
| 51 | [625e09](https://trello.com/c/4YCeJuNW) | connections choosing | need-info | 2b ask |
| 52 | [911678](https://trello.com/c/qTUWjHae) | instantly show timer on no animation | need-info | 2a confirm |
| 53 | [d27c5f](https://trello.com/c/v2jq0F3y) | battery saver on system battery saver | need-info | 2b ask |
| 54 | [1b52d8](https://trello.com/c/Kstyxrqg) | webview background opacity | need-info | 2b ask |
| 55 | [2ce050](https://trello.com/c/HCZeSQPX) | only Flutter background | need-info | 2b ask |
| 56 | [7443a1](https://trello.com/c/zlXgPiy9) | change loading spinner | need-info | 2b ask |
| 57 | [47631c](https://trello.com/c/WaWtZ9jd) | greetings naming in character sheet | need-info | 2b ask |
| 58 | [ca996a](https://trello.com/c/H0QZK8kX) | JAR background extraction | need-info | 2b ask |
| 59 | [98de62](https://trello.com/c/4NmTHygj) | long names in characters | need-info | 2b ask |
| 60 | [9cbf92](https://trello.com/c/bnOq41iy) | prompt blocks tab when using jar | need-info | 2b ask |
| 61 | [06e876](https://trello.com/c/yDcjsQcP) | keep position when changing segmented control tabs | audit | G22 |
| 62 | [a986bf](https://trello.com/c/LKIvVxsz) | dynamic swipe for segmented control tabs | need-info | 2b ask |
| 63 | [f56ab8](https://trello.com/c/dYlOBTda) | updates checking for characters | need-info | 2b ask |
| 64 | [6929f2](https://trello.com/c/bo7W0Ss9) | variation switching not instant | need-info | **resolved (✓)** |
| 65 | [9cf64b](https://trello.com/c/GGfXvPmz) | hide dev settings | need-info | **resolved (✓)** |
| 66 | [3f6174](https://trello.com/c/eDUWsqEy) | system prompt from st | need-info | **resolved (✓)** |
| 67 | [893223](https://trello.com/c/dlJc2CHB) | add a toggle for scroll on edit | need-info | 2b ask |
| 68 | [2c65b1](https://trello.com/c/YsDYzT9T) | scroll with touchpad on pc | need-info | 2b ask |
| 69 | [e787bc](https://trello.com/c/WCqT9dHK) | janitor custom tags | need-info | 2b ask |
| 70 | [652f48](https://trello.com/c/H2jCCOlh) | adding quick actions | need-info | 2b ask |
| 71 | [95f163](https://trello.com/c/OzcFopTH) | summary with protocols | need-info | 2b ask |
| 72 | [f0fa63](https://trello.com/c/C61ubEU4) | stick preset filters to header | need-info | 2b ask |
| 73 | [b0ffa2](https://trello.com/c/PbsYTLVT) | search on pc | need-info | 2b ask |
| 74 | [e8793a](https://trello.com/c/AmGbRTnu) | search for models | need-info | 2b ask |
| 75 | [f19209](https://trello.com/c/EvCsOmzZ) | optimistic delete with swipes | need-info | 2b ask |
| 76 | [f5fa61](https://trello.com/c/34Mz94A7) | gdrive sync | need-info | 2b ask |
| 77 | [28f538](https://trello.com/c/uiM3VXjN) | openrouter specific settings steal from st | need-info | 2b ask |
| 78 | [c95f93](https://trello.com/c/0FMkvpm7) | deleting races | need-info | 2b ask |
| 79 | [ec9c26](https://trello.com/c/k5GmJIdj) | folder navigation presets | need-info | 2b ask |
| 80 | [93fee0](https://trello.com/c/L2Hhhdmt) | start with API | need-info | 2b ask |
| 81 | [dd8a79](https://trello.com/c/jPqZucdE) | make feedback setting based on system setting and let it disable in settings | need-info | 2a confirm |
| 82 | [23be69](https://trello.com/c/rOGtiRiw) | adding quick actions | need-info | 2b ask |
| 83 | [f514ef](https://trello.com/c/zFSgrGzI) | jai jar losing credentials and 502 | need-info | 2b ask |
| 84 | [a33f49](https://trello.com/c/oU9NU60B) | lorebook ui rework (lorebook coverage and triggered items) | need-info | 2b ask |
| 85 | [96cac8](https://trello.com/c/l00CMGBt) | show connected persona in quick access | need-info | 2b ask |
| 86 | [2416db](https://trello.com/c/yRTFamQz) | connection preset not applying, check persona | need-info | 2b ask |
| 87 | [64431c](https://trello.com/c/4toCGgTD) | chat blank on first open | need-info | 2a confirm |
| 88 | [65395f](https://trello.com/c/3xu96PMy) | stashed preset blocks | need-info | 2b ask |
| 89 | [2dc6ef](https://trello.com/c/jf7z06JW) | List of more bugs | audit | G4 |
| 90 | [e054e5](https://trello.com/c/2Zsd4Zng) | Can't Switch in between quick access if one is open | audit | closed |
| 91 | [fb5ecf](https://trello.com/c/U9kLeoam) | performance drop when you open card info when you're in a chat | audit | G24 |
| 92 | [6d83a6](https://trello.com/c/JNK4OYde) | Scrolling fast in chat feels sluggish/laggy | audit | G24 |
| 93 | [eae22e](https://trello.com/c/0Chws2Nd) | Tavo backup import | need-info | closed |
| 94 | [9142d8](https://trello.com/c/TKZvImRB) | ** greying out "" | need-info | closed |
| 95 | [746bec](https://trello.com/c/8UhbGXCv) | Switching from a vision to non vision model after sending image shows HTTP … | audit | G10 |
| 96 | [6e9be3](https://trello.com/c/FeOK1iOr) | Image gen error | audit | closed |
| 97 | [9f1d82](https://trello.com/c/GSzx0unZ) | Image gen timer does not reset when you click retry | audit | G11 |
| 98 | [c1b787](https://trello.com/c/QjOQt2h3) | Only the first greeting being fetched on local janitor import | audit | G9 |
| 99 | [7295ae](https://trello.com/c/44EsdBHH) | Importing cards with lorebooks attached enable them globally | audit | G8 |
| 100 | [23c209](https://trello.com/c/QOf2Hh16) | Audio embed going out of text bubble | audit | G13 |
| 101 | [76d76a](https://trello.com/c/afZCHrvB) | Images option not centered | audit | G14 |
| 102 | [d0b886](https://trello.com/c/GZHf8heT) | buttons in other places than settings look different | audit | closed |
| 103 | [8089f6](https://trello.com/c/jkHnGvLw) | Summary generation not working | audit | closed |
| 104 | [ae6773](https://trello.com/c/M1mbv9CB) | I can't access bot | audit | G4 |
| 105 | [76f522](https://trello.com/c/Xd8pjLNQ) | HTTP 401 and HTTP 308 | audit | G5 |
| 106 | [e014db](https://trello.com/c/D7XWW2zR) | Cant see or use the buttons at the bottom in prompt inspector | audit | G14 |
| 107 | [5f8860](https://trello.com/c/jTouKBSF) | Cloud sync on Drive not working | audit | G6 |
| 108 | [0ad4ce](https://trello.com/c/bQtsTGsY) | when regening a message u can't view the previous gens of that message unti… | audit | closed |
| 109 | [8c600a](https://trello.com/c/riJp0gf6) | Chats not loading | need-info | 2a confirm |
| 110 | [72c6e3](https://trello.com/c/AnW6jMQS) | When using "continue" the llm sometimes gens the same thing | audit | G1 |
| 111 | [7c12c4](https://trello.com/c/IYYnllfa) | On the onboarding menu in the restore backup part it shows an option to exp… | audit | G7 |
| 112 | [b1eeb5](https://trello.com/c/MlQ6kOZb) | Can't see spoiler text in info box | audit | G23 |
| 113 | [c700a1](https://trello.com/c/MtB2rPDi) | New error | audit | G4 |
| 114 | [ef5193](https://trello.com/c/kRAggxOu) | Weird Search Behavior | need-info | 2a confirm |
| 115 | [b6547a](https://trello.com/c/tKw6mkUu) | cloud backup bug | audit | G6 |
| 116 | [3c2a8b](https://trello.com/c/r96ze4mf) | repo readme shows discord server as invalid | audit | G21 |
| 117 | [a4bbc4](https://trello.com/c/elocgmoD) | Saucepan import bug | audit | G19 |
| 118 | [5c7604](https://trello.com/c/uUQsjsZq) | Token count is not visible in the text bubble when you use continue | audit | G1 |
| 119 | [bb9123](https://trello.com/c/6qwm03VU) | If you get "Server took too long to respond" error when clicking on continue | audit | G1 |
| 120 | [2b2309](https://trello.com/c/HZ2PPAKb) | Error on memory gen embeds the error in the box | audit | G5 |
| 121 | [e89933](https://trello.com/c/DK3UFke7) | Last sent message reappearing on input box | audit | G17 |
| 122 | [dacc14](https://trello.com/c/imlNNeBH) | The draft in memory book arent auto generate | audit | G20 |
| 123 | [a54814](https://trello.com/c/VC4lI5Yj) | Reasoning box disappears on previously gen responses if you use a nonreason… | audit | G2 |
| 124 | [61b0a5](https://trello.com/c/6DShT4Oi) | Sync bug on Windows | audit | G6 |
| 125 | [41c945](https://trello.com/c/LZhpAGqb) | Lorebook entries being triggered even when the keywords are not present in … | need-info | 2a confirm |
| 126 | [ff9857](https://trello.com/c/rZAx904G) | broken SillyTavern backup import | need-info | G18 |
| 127 | [a39c77](https://trello.com/c/D0WF9j01) | PromptWorker getting overwhelmed with too many lorebooks/regexes | need-info | G18 |
| 128 | [2bf963](https://trello.com/c/90bz6e8K) | 405 Naistera | need-info | 2b ask |
| 129 | [3c94eb](https://trello.com/c/8DwcUzXl) | empty chat | need-info | 2a confirm |
| 130 | [991ef4](https://trello.com/c/A5JHpgrF) | decouple embedding settings from api settings | need-info | 2a confirm |
| 131 | [831f9a](https://trello.com/c/jHUA6CJH) | "Generating" textbox sometimes disappears when exiting and reopening the ch… | audit | G3 |
| 132 | [4ce7e1](https://trello.com/c/LmhFBayp) | Update pop-up for a way older build on the latest nightly | audit | G15 |
| 133 | [e4d37b](https://trello.com/c/UbjPU1fH) | protocols and error handling in extblocks | need-info | 2b ask |
| 134 | [07c90c](https://trello.com/c/Sofom8CV) | App settings not syncing with cloud sync | audit | G6 |
| 135 | [1e81ff](https://trello.com/c/Zdt1UE0Y) | check lorebook settings when importing st | need-info | 2a confirm |
| 136 | [5472e9](https://trello.com/c/E9kY5eHG) | 0 turns into a 1 after you send it...? | audit | G12 |
| 137 | [febb44](https://trello.com/c/hHlAdCor) | Update pop-up does not show until you restart the app | audit | G15 |
| 138 | [44f3a6](https://trello.com/c/McgxMRW1) | trigger type dropdown in memory books doesn't open | need-info | 2b ask |
| 139 | [04e6ba](https://trello.com/c/nJ2m5owY) | Messages not saving edits | audit | closed |
| 140 | [8ba5a7](https://trello.com/c/FKvwpAub) | JanitorAI session expires | need-info | 2b ask |
| 141 | [0f8e95](https://trello.com/c/kXx3Ca2o) | Previously Genned message showing as currently genning message briefly | audit | G3 |
| 142 | [297100](https://trello.com/c/zlCHaTGW) | tapping memory section in header acrolls chat | need-info | 2b ask |
| 143 | [5e602f](https://trello.com/c/GdkHzi8U) | image.png | need-info | 2a confirm |
| 144 | [30ba29](https://trello.com/c/mzUvUY0k) | prompt inspector - no groups when single request and design | need-info | **resolved (✓)** |
| 145 | [199914](https://trello.com/c/xU4QXwp4) | response in prompt inspector | need-info | **resolved (✓)** |
| 146 | [861f74](https://trello.com/c/z5Yh6hhe) | describe tokenizer differences in glossary | need-info | 2b ask |
| 147 | [cfb3cb](https://trello.com/c/IfzWpO0L) | ignore virtual scroll when searching and selecting | need-info | **resolved (✓)** |
| 148 | [88803c](https://trello.com/c/KMWaPs5p) | memory sheet flickering | need-info | 2b ask |
| 149 | [a2f07f](https://trello.com/c/fFttQqXa) | Inconsistent notification icon | audit | G16 |
| 150 | [414b27](https://trello.com/c/OeglP75n) | notification shows the top part of the message when using continue instead … | audit | G1 |
| 151 | [46874e](https://trello.com/c/Mkqos59h) | no variants on branching | need-info | 2a confirm |
| 152 | [507095](https://trello.com/c/IEJydPzO) | Issues with Janitor third party browse | audit | G4 |
| 153 | [d5ef12](https://trello.com/c/C2wQZouv) | response in prompt inspection doesn't work, shows "no captured" | audit | G14 |
| 154 | [a4474c](https://trello.com/c/LnS7MoHY) | regex not working on first chat open | need-info | 2a confirm |
| 155 | [5a5696](https://trello.com/c/sWa9Xmxj) | first chat open is blank | need-info | 2a confirm |
| 156 | [77c101](https://trello.com/c/4AB3WcS0) | change text color | need-info | 2b ask |
