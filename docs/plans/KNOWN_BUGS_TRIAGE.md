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

### G7 — `fix/backup-onboarding-polish` — **PR [#434](https://github.com/hydall/Glaze/pull/434)**
- **#24** the export button showed the import label — **fixed.**
  `backup_progress_preparing` reads "Preparing import…" and was the export
  button's busy label as well as the import flow's progress line, so exporting
  a backup told the reader in as many words that it was importing one. Export
  has its own string now, in both languages.
- **#111** onboarding offered Export on a fresh install — **fixed.**
  `fromOnboarding` reached the screen but was only ever read by `_reloadApp`,
  so the sheet drew both sections either way. During onboarding it is opened
  from "Restore from backup", on an install with nothing in it — an offer to
  write an empty archive. `_NormalView` takes `showExport`, and the separator,
  the button and the hint go together. The settings sheet is unchanged.

4 new tests; negative control confirmed (exactly the two behavioural cases fail
on nightly, the two controls pass). The exporting state is reached in the test
by overriding `backupServiceProvider` with a future that never completes —
`_performExport` flips its flag before it awaits, so the label settles without
a database.

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

### G9 — `fix/janitor-greetings` — **PR [#436](https://github.com/hydall/Glaze/pull/436)**
- **#98** — **the card's title is not the bug; the reporter's own thread is.**
  "using datacat imports all greetings normally … with datacat it skips the 1st
  greetings … going directly to the datacat site and downloading the card from
  there includes the first greeting". So the reproducible half is DataCat, and
  the local half does not reproduce — the extractor already collected every
  greeting from three sources and deduplicated them, which the reporter also
  says ("when you extract it locally the first greetings comes").
- **The DataCat mechanism.** DataCat mirrors JanitorAI rows, and Janitor keeps
  the opening line in `first_message` **and** the whole set in `first_messages`.
  On some cards the singular field is empty and only the set arrives.
  `_datacatCharacterData` read the singular field for `firstMes` and
  `alternate_greetings` for the rest — and never read `first_messages` at all.
  Slot one came out blank, every greeting shifted down by one, and the card
  "skipped" its first. DataCat's own site works because their exporter takes the
  set's first entry as `first_mes`, which is the rule adopted here.
- **Found on the way, unreported:** the Janitor *browse* path had the same
  disagreement the other way — it mapped `first_messages` straight onto the
  alternates, so the opening line was listed twice.
- One rule in `normalizeGreetings`, used by all four paths (DataCat, Janitor
  browse, Chub, the local extractor which had already arrived at it inline).
  The sentence worth keeping: **a card whose singular field is empty is not a
  card without a greeting — it is a card whose greeting is first in the list.**
  Order is preserved rather than sorted; for a card with several greetings the
  order is the author's.

21 new tests; `_datacatCharacterData` and Chub's `_convertToGlaze` are public so
the mapping is reachable from a test rather than only through a live request.
Negative control confirmed. **Not verified:** the card the reporter linked —
that wants a DataCat request for that id on a device. **Also in that thread and
not addressed:** "lorebook extraction for that card does not work", which is a
different subsystem and needs its own card if it still reproduces.

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

### G11 — `fix/imggen-timer-cache` — **PR [#435](https://github.com/hydall/Glaze/pull/435)**
- **#97** — **the reported symptom is already fixed; the spec written for it
  found the inverse, which is worse.** Wrote a browser spec for the retry
  sequence before changing anything: it passes on nightly. `isolateOne`
  restamps a live placeholder as it isolates it, so a retried generation does
  start from zero — PR #338 (2026-08-28), after the card.
- **What does reproduce:** any re-render during a generation sends the clock
  back to 0.0s. Every render replaces the message body wholesale, so the
  placeholder is a new element and the restamp fires again. A new message
  arriving during a 40-second generation threw away the 40 seconds the reader
  was watching, every time anything in the chat changed — so the clock never
  told them how long they had actually waited.
- **Neither place that held the clock could.** The element is replaced on every
  render; the formatter's cached HTML is memoized on the message text, so the
  `data-start` baked into it is whatever the first render of that text stamped
  (which is the reuse the card was reaching for). The start is held by the
  placeholder module now, keyed on message id + image index: a re-render
  resumes, a retry starts from zero (the entry is dropped once the block stops
  being pending), and a row unmounted by the virtual window keeps its clock,
  because scrolling away is not finishing.
- Two things this needed. **The prune runs on the next frame** — it is
  triggered from a render that is still writing a *detached* section, so the
  document it would otherwise sweep is the one from a moment ago and the block
  that just finished is still live in it. And **the message id is threaded
  through `writeShadowContent`, not walked up to**: a section is built and
  written before it is appended, so on the render that creates a placeholder
  there is no `data-message-id` above it to find. The first attempt walked the
  ancestor chain and silently keyed everything on an empty id.

2 new browser specs; negative control confirmed (on nightly the retry spec
passes and the re-render spec fails). Three source assertions in
`webview_assets_test.dart` moved with the code they pin, two were added.
**Not verified on a device:** the specs run in headless Chromium.

### G12 — `fix/ol-start` — **already fixed on nightly**
- **#136** `0. test` renders as `1. test` — **no longer reproduces.** PR #350 already
  captures the first item's number and emits `<ol start="N">`
  (`block_syntax.js:143-157`), the case is in the corpus as `ordered-list-zero`, and
  `cards.spec.js` asserts `start === 0` for it. Ran that spec against nightly: passes.
  The thread's "on chat preview it still shows 0" is correct behaviour — the preview
  shows the raw text the user typed. No branch; card moved to Done, not tested.

### G13 — `fix/audio-embed-overflow` — **PR [#418](https://github.com/hydall/Glaze/pull/418)**
- **#100** audio embed overhangs the bubble — **fixed.** The player in the screenshot
  is Chromium's own `<audio>` control, which it lays out at a fixed 300px; a bubble on
  a phone gets 88% of the screen less its padding, about 260px on a 360px device, so
  the control kept its intrinsic width and painted through the rounded border. Browser-
  sized media is now capped at the width of the message it sits in, in `SHADOW_STYLE`
  next to the `img` rule that has always done this. `<video>`, `<iframe>`, `<canvas>`,
  `<embed>` and `<object>` get the same cap — all six default to a fixed intrinsic
  width, and the bug is the width, not the tag.

  **Declined the audit's second suggestion**, `overflow: hidden` on `.msg-body`. That
  clips the symptom and breaks a documented feature: a card is allowed to paint outside
  its bubble, and every CSS-only overlay card (`#toggle:checked ~ .overlay`) depends on
  it.

  Corpus entry `audio-embed` plus a spec that squeezes a message to a phone-bubble
  width: 40px of overhang on nightly, none with the rule. Full suite 98 passed.

### G14 — `fix/prompt-inspector` — **PR [#433](https://github.com/hydall/Glaze/pull/433)**
- **#106 + #49 are one bug, and the audit's fix for it was wrong.**
  `SheetView` does **not** pad its body against the nav bar — it publishes the
  inset through `MediaQuery.padding.bottom` and expects the body to consume it,
  deliberately, so rows scroll behind the bar while the last one rests above it.
  A scroll view only gets there when it derives its own padding: passing an
  explicit `padding` **replaces** the MediaQuery-derived one, so the inset is
  discarded — and every scroll surface in the inspector passes its own. The
  Context tab ends with two tappable tiles (API settings, "Unhide all"), and
  those are the buttons #106 cannot reach. Six surfaces add it back through one
  documented helper. **Not `useSafeArea: true`**: every other `SheetView` sheet
  in the app is shown without it on purpose, and adding it here would cut the
  sheet's own background short of the screen edge and inset the content twice.
- **#153 was bigger than "no callId".** A captured request is joined to its
  outcome by `callId + attempt`, and `_recordCallEvent` returns early when the
  callId is null — but the main chat stream also emitted **no transport event
  at all**; only `AuxLlmClient` and the ledger paths did. So there was nothing
  to join even with a key. Both halves fixed: the context comes from a named
  `mainCaptureContext()` that states what each field is load-bearing for, and
  the stream records exactly one outcome at whichever terminal it reaches
  (guarded — `onComplete` and `onError` are not exclusive on every transport,
  and a second write would collide on `callId + attempt` rather than add). A
  first-chunk timeout is recorded as a **timeout**, not as the cancel it is
  implemented as, so a provider that never answered is not filed under "you
  stopped it". The status vocabulary moved out of `AuxRetryRunner`, where it was
  private, into `describeCallAttempt`, so the main stream describes itself in
  the same words as every other call instead of a second set.
- **#101 measured, not changed.** The card is a screenshot with no text, and
  images are not readable on this side. The strip measures correctly: every
  tab's content is centred in its own slot, Images included, and the pill shares
  its label's centre. What a reader *does* see with three tabs is the third
  half-cut at the right edge — deliberate, and what `_kVisibleTabs = 2.35` is
  for. Four tests record the measurements; changing that constant on a guess
  would move every tab strip in the app. **Asked in the PR** whether the report
  is the half-cut tab or something else.

20 new tests; negative control confirmed. **Not verified on a device:** that the
bottom tiles are now reachable. `MediaQuery.padding.bottom` is 0 on the test
surface unless a test sets it, which is exactly why this went unnoticed.

(#145 was the duplicate of #153 and is already checked off on the board; #35 "prompt inspector i18n" is checked off too, so the hardcoded-English findings there are considered done.)

### G15 — `fix/update-checker` — **PR [#438](https://github.com/hydall/Glaze/pull/438)**
- **#132** — **fixed.** `_checkCiBuild` decided availability on SHA inequality
  alone. But two different SHAs do not mean the branch is ahead: the installed
  build can be the newer of the two (the run after it failed, or it came from a
  branch that has since moved), and then the "update" is a step backwards. The
  compare endpoint was **already being called** for the release notes and
  answers this in the same response — `status` is `ahead`, `behind`,
  `identical` or `diverged` — so it costs no extra request. `behind` and
  `identical` now resolve to up-to-date. `diverged` still counts as something to
  offer: it carries commits the installed build does not, and it is the build
  the channel is publishing.
- **An unresolved comparison still offers the update, deliberately.** A
  force-pushed branch leaves an installed SHA that can never be compared again,
  and treating that as up to date would stop updates for that install
  permanently — silently, and in a way nobody would report. Offering an
  unverifiable build is the lesser failure; the reader can decline it.
- The **stable** channel was already right (`_checkRelease` compares versions,
  not identity) and is untouched.
- **#137** — **already fixed**, by PR #350, which added
  `AutomaticUpdateCheckController`: an hourly timer, paused on background and
  resumed on foreground, wired in `app.dart`. Nothing covered any of it, so it
  is covered now.

16 new tests; negative control confirmed. `installedCommit` is injectable on the
service — `buildCommit` is a `String.fromEnvironment` const, so it is empty
under `flutter test` and the pre-release path bailed out before reaching
anything worth asserting on, which is why this code had no tests.
**Not verified against GitHub:** the tests stub the API; that a real `behind`
comparison comes back with that literal string is from GitHub's documented
response rather than an observed call.

### G16 — `fix/notification-icon` — **PR [#429](https://github.com/hydall/Glaze/pull/429)**
- **#149** the notification icon shows the card image / a first letter / nothing
  — **the avatar half is fixed; the small-icon half was already fixed and is now
  hardened.** The presenter handed the platform the character's
  full-resolution `avatars/<id>.png`. Android decodes that into a bitmap before
  it will draw the notification and a card is routinely several megabytes — big
  enough to be refused, at which point the step-down drops the avatar, the
  `Person` goes icon-less and Android draws its own first-letter circle. Whether
  a character got its picture came down to how heavy its card happened to be,
  which is the "sometimes the image, sometimes a letter" exactly.
  `notificationAvatarPath` prefers `thumbnails/<id>.jpg` — the same picture at a
  size nothing objects to, already written for every card — and keeps the
  full-resolution avatar as the fallback. For the "nothing at all" end there is
  a new rung between the messaging style and the plain notification: reaching
  the plain step means the *style* was refused, not the avatar (the step above
  carries none and still failed), and a plain Android notification can still
  show the card as its large icon.
- **#9** the small icon must be an envelope, not the retry arrow — **already
  fixed on `nightly`, path removed.** `824e4ef1` (2026-09-04) made `new_message`
  the icon; #9 is from 2026-08-28 and #149 from 2026-09-07, so the reporter was
  plausibly on a build from before it. What was left is that
  `ic_stat_icon_config_sample` — the circular retry arrow left over from the
  Capacitor build, referenced now only by a dead `com.hydall.glaze.ic_generation`
  manifest entry — sat *second* on `androidIconCandidates`, so one failed
  drawable lookup put a refresh arrow on every message notification for the rest
  of the process. It is off the list; the Glaze mark takes its place, so every
  fallback is something a new message can plausibly wear.
- Adjacent, same file: `resolveGlazeFilePath` joined a `data:`/`https:` path
  onto the data root and returned a path no file lives at.
  `relativeGlazeFilePath`, its inverse, has always guarded against that; both
  halves are symmetric now.

8 new tests; negative control confirmed (with `notificationAvatarPath`, the icon
list and the URL guard reverted to their `nightly` shapes, exactly those 4
fail). Full `flutter test` green. **Not verified, and it matters here:**
everything the report is about is Android-only and none of the Android
`NotificationDetails` can be exercised from a test — `Platform.isAndroid` is
false on every host the suite runs on. Tested is the path resolution and the
icon ordering that feed them. A phone would settle whether the thumbnail really
stops the letter fallback and whether the new rung shows the card on a device
that refuses `MessagingStyle`.

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

### G21 — `fix/docs-and-readme` — **PR [#419](https://github.com/hydall/Glaze/pull/419)**
- **#116** The README Discord badge renders "invalid server" — guild id and invite do not match
- **#33** The README "Download the latest release from Releases" link is `../../releases`, which resolves above the repository
- **#23** (nightsyr mention) — credit nightsyr in the README as an honorary tester, alongside the testers listed in the app
- **#146** — glossary entry stating that Glaze's local tokenizer is an estimate and can differ from the provider's count; all languages (`glossary_en.json` + `glossary_ru.json`)

All four **fixed**, with one finding worth keeping:

- **#116** the badge's guild id really is wrong — the invite resolves to
  `1484662788394582016`, the id every Discord report link in the tracker carries, not
  the `1355184294868484196` in the badge. But **correcting it does not fix the badge**:
  shields.io's Discord source reads the guild *widget* API, and with the widget off it
  answers `chat: widget disabled` instead of `chat: invalid server`. Verified both by
  fetching the two badge URLs. So the badge is now a static **Discord · Join** badge,
  which cannot report on a server at all. Enabling Server Settings → Widget in Discord
  would allow the live count back — that is the maintainer's call, and it is in the PR.
- **#33** absolute Releases URL, plus a version badge linking to `releases/latest` —
  the "download button" the card names. `../../releases` resolves correctly only
  because GitHub happens to render a README two path segments deep.
- **#23** a Testers subsection in both READMEs, nightsyr first, from the app's own Hall
  of Fame list.
- **#146** a *Why token counts differ* article in both glossaries, filed next to
  `token`: `o200k_base` locally vs the provider's own tokenizer, and the ~4-chars-per-
  token fallback before the vocabulary has downloaded.

The glossary had **no test at all**; it has one now (`test/glossary_content_test.dart`):
term ids in step across both languages, every `[[link]]` resolving, and a term
cross-listed under two categories saying the same thing in both places. That last one
exists because EN files `chat-session` and `connections` under two categories each —
identical copies today, which the test now holds in place.

Also noticed, not part of these cards: the EN and RU glossaries agree on all 73 term
ids but not on which category a term sits in (EN cross-lists two, RU does not).

### G22 — `fix/tab-scroll-position` — **already fixed on nightly**
- **#61** Discover ⇄ My Characters loses the scroll position — **no longer
  reproduces.** PR #358 added `TabScrollMemory`
  (`lib/shared/widgets/tab_scroll_memory.dart`): one `ScrollController` per tab,
  provided *inside* each tab body so the outgoing body keeps scrolling while it
  animates out, and the offset restored as the incoming position is created, before its
  first frame. `test/tab_scroll_memory_test.dart` covers both directions; ran it on
  nightly, passes. The card's second half — a floating jump-to-top button — is a
  feature, and the re-tap-jumps-to-top behaviour is intentional per the maintainer's
  own reply. No branch; card moved to Done, not tested.

### G23 — `fix/spoiler-reveal` — **PR [#439](https://github.com/hydall/Glaze/pull/439)**
- **#112** — **the reveal was happening and then undoing itself.** Glaze does
  not hide spoilers behind a tap and is not meant to. A JanitorAI spoiler is
  text painted the same colour as its own highlight, and `htmlToMarkdown` drops
  the *hiding* colour on purpose so the highlight can show with readable text
  instead — `_convertMark`'s comment says exactly that. Then
  `BackgroundTextMd` painted that text `Colors.white` whatever the highlight
  was, so an author who hid their spoiler behind a **pale** colour (white, light
  grey — the common case) got white on near-white: as unreadable as the
  grey-on-grey it started as, for the same reason.
- `readableOn` picks black or white by **contrast ratio** against the highlight.
  The crossover is the ratio rather than a luminance of 0.5 — that shortcut is
  the usual one and lands in the wrong place (the ratios meet at ~0.179), so it
  keeps painting white over everything from mid-grey up, which is most of the
  range this bug lives in. A highlight too transparent to be a background at
  all defers to the surrounding text colour, since the text is then on the page
  rather than on a chip.

10 new tests, covering the three HTML spellings a spoiler arrives in as well as
the colour rule and both sides of the crossover; negative control confirmed.
**Not verified:** the screenshot on the card is unreadable from here, so which
shade that author used is unknown — the fix covers the range rather than one
colour.

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
| 136 | `0. test` renders as `1. test` | Fixed by PR #350 — `<ol start="N">`, corpus card `ordered-list-zero`, spec passes on nightly |
| 61 | Tab scroll position lost | Fixed by PR #358 — `TabScrollMemory`, `test/tab_scroll_memory_test.dart` passes on nightly |

---

## Part 1b — groups added in step 2 (from your answers)

### G25 — `fix/chat-first-open` — **PR [#421](https://github.com/hydall/Glaze/pull/421)**
- **#154** display scripts not applied on the first open — **fixed**, and the audit was
  right in kind: the initializer read `displayRegexesProvider.value` synchronously. On
  the first open after launch neither half of that list has resolved (the preset comes
  from the DB, the global scripts from SharedPreferences), so the sequence got an empty
  list, `setMessages` baked the un-rewritten text into every message, and nothing
  re-rendered it. Two further holes on the same path: `activeRegexesProvider` awaited
  the preset repo but *read* `globalRegexProvider.value`, so even a resolved list could
  come back without a single global script; and the `displayRegexesProvider` listener
  returned early while the bridge was not ready — precisely the window the list
  resolves in — which lost the change for the whole session. Now awaited, awaited, and
  recorded (`regexContextStale`) for the post-init re-render.
- **#87** blank chat, bridge lost, dead buttons — **mechanism fixed, needs a device to
  confirm.** The page behind the chat can die while the app still believes in it:
  Android kills the render process under memory pressure (the keep-alive WebView every
  chat shares, backgrounded while another app runs, is the ordinary case) and iOS can
  terminate the web content process. Neither event was handled anywhere, and that one
  state explains both halves of the report — nothing renders, `window.bridge` is gone,
  every call into the page returns having done nothing, and reopening the chat was the
  only cure. `onRenderProcessGone` / `onWebContentProcessDidTerminate` now report it;
  the Dart side stops believing in the page and the native view is replaced (disposing
  the shared keep-alive first, or the replacement re-attaches the same corpse). The two
  failure paths that used to end at a dialog — an init that could not reach the page,
  and a bridge that never appeared — take the same recovery first, because waiting out
  the 30s handshake against a dead page buys nothing. `ChatWebViewRecovery` rations it:
  three rebuilds in two minutes, then the reader is told, and a completed init clears
  the budget.

6 new tests (2 provider-level, both fail on nightly; 4 on the rebuild budget with a
fake clock). The renderer-death wiring itself has no test seam — `ChatBridgeController`
wraps a real `InAppWebViewController` — which is why the decision logic was extracted
into a class that does. Confirm with `adb shell am send-trim-memory <pid> COMPLETE`.

Both are the same subsystem as G3 (bridge/WebView init), but a different failure: G3 is
the streaming placeholder, G25 is the initial `setMessages` + bridge handshake. #129 and
#155 were archived as duplicates of #87.

### G26 — `fix/keyboard-inset` — **PR [#423](https://github.com/hydall/Glaze/pull/423)**
- **#7** keyboard padding scrollable inside the chat container — **fixed a false
  premise.** The bridge already splits Flutter's inset the right way (padding = inset
  minus the *measured* viewport shrink, because whether a keyboard resizes the WebView
  or overlays it is up to the embedder). But its premise, stated in its own comment, was
  that a shrink of the visible viewport shows up in `#chat-container.clientHeight` —
  and the element was `height: 100vh`. `100vh` is by definition the viewport with every
  retractable UI retracted: it never shrinks for a keyboard. So the measured shrink was
  always zero, the whole inset always became padding, and on an embedder that does not
  resize the layout viewport (iOS WKWebView, Android edge-to-edge) the keyboard was
  counted twice — once as screen the reader cannot see, once as padding. Now
  `height: 100vh; height: 100dvh`, and `_visibleViewportH()` takes the smaller of the
  element's client height and `visualViewport.height`, which an overlaying keyboard does
  shrink. `visualViewport` was already listened to for resizes — it was just never
  read. No change to the reconciliation itself: it consumes the same two numbers and was
  already correct given an honest shrink.

  The asset guard that pinned the old measurement is updated and now records why, plus a
  new guard on `100dvh`. **Needs a device**: desktop Chromium has `dvh == vh` and no
  soft keyboard, so nothing here is exercisable in the harness beyond the shape of the
  code. **Not fixed, same card:** the iOS "no inertia while editing" half — momentum
  loss in a `-webkit-overflow-scrolling: touch` scroller holding a focused input, a
  different mechanism that needs a device to work on at all.

### G27 — `fix/protocols-pipeline` — **PR [#425](https://github.com/hydall/Glaze/pull/425)**
Both cards asked for a check, and for both the answer was **already yes**: summary
generation runs on `AuxLlmClient`, which resolves its transport through
`pickChatTransport`; ext blocks call `pickChatTransport` directly and surface
failures through the shared `formatError` → `formatBlockErrorContent` path added in
PR #347. So nothing was re-plumbed. What was fixed is the two things those paths
still failed to inherit from the chat pipeline.
- **#71** summary on the common pipeline — **already true; one real leak fixed.**
  `ApiConfig.omitTemperature` marks a connection whose provider rejects a
  `temperature` field outright (OpenAI reasoning models, several proxies answer HTTP
  400 when it is present). `AuxApiConfig` — the narrowed config every aux caller
  builds — had no such field, so the flag died at the boundary: a connection the chat
  could talk to would fail on a summary, a Studio slot, a card rewrite or a Janitor
  lorebook rebuild. Aux calls pin their own temperature (0.3 for summaries), which is
  exactly why the omission hid so well — the parameter is always sent, so it never
  looked like something was missing. Now on `AuxApiConfig`, through both
  `ChatTransportRequest` constructions in `AuxLlmClient`, and threaded from the
  connection at all five construction sites.
- **#133** ext blocks on the pipeline with its error handling — **already true;
  the missing piece was the deadline.** The call passed no `receiveTimeoutMs`, so it
  inherited the transport's Dio ceiling (120s OpenAI-shaped, 180s Anthropic/Gemini)
  — the wrong instrument twice over: far too long for a provider that accepted the
  connection and then said nothing, and on a stream it can fire *mid-answer* when a
  model pauses to think. Worse, the call awaited a completer only the transport's
  callbacks complete, so a transport that returned without invoking one left the
  block awaiting forever. The chat solved this long ago with `IdleTimeoutGuard` — a
  deadline on the *first* chunk (text or reasoning), cancelled the moment the stream
  shows life. Ext blocks now use the same guard with the connection's own
  `firstChunkTimeoutMs` (60s fallback) and hand it the deadline via
  `receiveTimeoutMs: 0`.

The call was untestable where it stood, so it moved: `BlockLlmRunner` holds the
guard, the cancel-token bridging, the buffering and the `StateError` for a
callback-less transport, and `InfoBlockService` takes it by constructor — the same
seam tactic as `ChatWebViewRecovery` in G25. 9 new tests (2 aux flag, 6 runner,
1 summary), negative control confirmed; full `flutter test` green (3907/3907).

### G28 — `fix/permissions-and-battery` — **PR [#426](https://github.com/hydall/Glaze/pull/426)**
- **#29** notification prompt on app open → onboarding step — **done.** The
  dialog fired at startup because that is where the request lived:
  `_configurePlatform()` called `requestNotificationsPermission()` from
  `ensureInitialized`, which runs on launch. On Darwin it was worse than a call
  — `DarwinInitializationSettings(requestAlertPermission: true)` made
  `initialize()` itself put the dialog up. Both are gone from startup (the
  Android channel is still created there — a channel the reader has tuned must
  not be lost), and `requestPermission()` performs the ask on demand. The new
  slide sits between Chat Layout and All Set and reuses the action-row shape the
  API and Persona slides already have: an Allow tile, and the flow button
  reading **Skip** until it is granted. It exists only where there is something
  to ask for — Windows and Linux post without asking — which is why
  `buildOnboardingSlides()` is computed rather than `const`.
- **#30** battery-optimization dialog — **removed**, along with the
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission from our manifest. Nothing
  declares it now that the only caller is gone, and the plugin's own manifest
  does not re-add it, so it really drops out of the merged manifest rather than
  sitting there as an unused Play-restricted permission.
- **#53** three-state Battery Saver — **done.** `BatterySaverMode
  {system, on, off}` is the choice; `AppSettings.batterySaver` survives as the
  *resolved* answer, so all ~40 read sites are untouched, and stays persisted as
  the last known value so a cold start paints the right thing before the
  platform answers. `SystemSettings.isPowerSaveMode()` plus a new event channel
  extend the existing `app.glaze.flutter/system_settings` channel: Android reads
  `PowerManager.isPowerSaveMode` and listens for
  `ACTION_POWER_SAVE_MODE_CHANGED`, iOS reads `isLowPowerModeEnabled` and
  observes `NSProcessInfoPowerStateDidChange` — polling cannot see the moment
  the phone flips, which is the only thing "follow the system" is about. System
  resolves to **off** where there is no signal (Windows, Linux, macOS).

  **The migration is a judgement call, recorded here so nobody has to re-derive
  it.** A stored bool cannot say whether it was chosen or inherited. The old
  default was `true`, so a stored `true` is indistinguishable from never having
  touched the setting — those installs take the new default, System. A stored
  `false` could only be reached deliberately, so it is kept as Off; under System
  it would have flipped itself on the next time the phone started saving power.
  Consequence, stated plainly: **most existing users come out of this update
  with the richer UI**, because they were on the old default and their device is
  not saving power.
- **#52** `0s` immediately in Battery Saver — **done, and it was three bugs, not
  one.** (1) `start()` only installed a `setInterval`, which does not fire until
  a whole period has passed — 1000ms in battery saver. (2) An immediate paint
  alone would not have helped: the clock is started by the send window and the
  typing bubble is appended *after* `dispatch()` returns, so at `start()` the
  chat is still empty. A priming interval now runs at the fast cadence until the
  bubble lands, capped at 3s. (3) The badge was built through `_createGenStat`,
  which **drops a clock reading `'0s'`** — a finished message with no recorded
  time has none, and `'0s'` is exactly what a clock reads on the tick that
  creates it. Going through it would have left an empty gen-stat behind and
  appended a second, populated one a tick later; it is assembled from
  `_buildGenTime` directly now.

10 new Dart tests (7 migration, 3 slide composition) and 5 new playwright specs;
the battery-saver clock spec fails on nightly. `flutter build apk --debug`
succeeds, so the Kotlin compiles. **Not verified:** the Swift half cannot be
compiled on Windows, and the permission dialogs and OS power-save transitions
need a device — worth a check before promotion.

### G29 — `fix/presets` — **PR [#427](https://github.com/hydall/Glaze/pull/427)**
- **#47** imported presets invisible until a reboot — **the reported cause was
  already fixed; the other entry point was not.** The audit blamed
  `StudioPresetWorkflowService.importPreset` for writing without invalidating
  `studioPresetListProvider`; on `nightly` the preset list's import path already
  invalidates it, with a comment saying exactly why. What the audit *also* listed
  and what was still open is the cloud sync pull:
  `refreshDataProvidersAfterPull` invalidates fifteen providers and neither
  preset library. Both are read-once caches (`presetListProvider` an
  `AsyncNotifier` over `getAll()`, `studioPresetListProvider` a `FutureProvider`
  over the same) where the folder providers beside them are Drift streams that
  refresh themselves — and the pull writes presets straight through the repos
  (`case 'theme_presets'`, `case 'studio_preset'`). Nothing ever told either list
  it was stale.
- **#47** (second half) Studio presets sticking to the bottom — **fixed.** The
  list concatenated the two stores, and that grouping survived sorting: manual is
  the default mode and it ranks only the rows the user has actually dragged,
  leaving the rest in the incoming order. `mergePresetItems` interleaves them by
  age instead — a merge, not a sort, so each store's own order (the plain list
  carries a legacy manual order that is not in timestamp order) survives
  untouched and only where the Studio presets slot in changes. One related data
  bug fell out: `PresetItem.createdAt` read `StudioPreset.updatedAt` for an id
  without a `studio_<seconds>` stamp — in practice only the seeded built-in
  `default`, whose `updatedAt` the repo re-stamps on every save. Its "date added"
  was really "date last edited", floating it to the top of newest-first whenever
  it was touched and sinking it to the bottom of the merged list. A built-in
  arrives with the install, like the featured plain presets, so it sorts as the
  oldest entry now.
- **#25** user-set preset images not displayed — **same root cause, one step
  further along.** Covers travel with the preset (`pullPresetImages` drops the
  file next to the path the preset already carries), but whether a cover exists
  is a plain `File.existsSync()` taken during build. With nothing invalidating
  the list, the frame that decided "no file" was the last one drawn and the cover
  that landed a moment later never appeared — again until a restart. The
  invalidation above is what repaints it. **Worth knowing:** the local pick →
  store → display path is sound and already covered by
  `preset_cover_image_test.dart`; the symptom does not reproduce from the code on
  that path. If it persists, which screen and whether the preset came from this
  device would settle it.
- **#79** open the list on the active preset's folder — **done.** A preset filed
  into a folder is not listed at the top level (it lives in the folder, and only
  there), so the screen opened on a list that did not contain the preset in
  effect, with no hint of where it went. The choice is made once per screen and
  only once both the folder list and the membership stream have a value, so a
  mid-load read cannot settle on "no folder" first; a preset in several folders
  always opens the same one. The existing auto-reveal scroll, previously confined
  to the top level, now also runs inside that folder.

13 new tests (11 list composition, 2 sync refresh); negative control confirmed on
both halves. Full `flutter test` green. **Not verified:** the folder the list
opens on and the sync refresh both want a device (or a second account) to watch.

### G30 — `fix/editor-ui` — **PR [#428](https://github.com/hydall/Glaze/pull/428)**
- **#88** the stash button in the prompt-block row — **done.** Stash was a third
  control competing with the drag handle, the pencil and the switch on a 44px
  line; Delete was a full-width red bar at the foot of the open editor, and the
  two buttons that act on one block lived on two different screens. Both are now
  icon-only buttons in the header of whichever chrome hosts the editor — the
  standalone Edit Preset screen (`GlazeScaffold.actions`) and the Presets sheet
  (`SheetView.actions`) each draw the same payload the editor body hands up,
  `PresetBlockEditorActions`. The one button points the other way for a block
  opened out of the stash (restore, not stash), and both return to the block list
  once they have acted so the editor never sits open on a block the list below it
  no longer holds. Author's Note and Summary are static — not stashable, not
  deletable — so their editors carry no header buttons. `PresetBlockRow.onStash`
  is deleted rather than left unused; Studio presets have no stash and are
  untouched.
- **#57** first messages named and laid out badly — **done.** The sheet gave
  `firstMes` a card labelled "First Message" and then one loose card per alternate
  greeting, each labelled with the *placeholder* string, ellipsis and all
  ("Greeting... 2"). They are one card now, `First Messages`, with a count and a
  numbered sub-block per line. The numbering is the character editor's — slot 1
  is `firstMes`, the alternates follow, and an empty slot is dropped without
  renumbering the ones after it — so the message the sheet shows as "#3" is the
  one the editor opens as "#3". Sub-blocks collapse individually (a dozen
  greetings is a wall of text otherwise) except when there is only one, which
  stays open. **Drive-by on the same path:** `generic_editor_greeting_title` read
  `Greeting #{arg0}` in both locales and easy_localization's `args:` only ever
  substitutes `{}` (`_replaceArgRegex`), so the fullscreen greeting editor showed
  the placeholder literally. Fixed to `{}`. ~26 other keys carry `{argN}`; not
  audited — only this one is on the path #57 is about.
- **#59** long name rides upward in the character-sheet header — **done.** The
  hero caption is pinned to the *bottom* of a fixed-height image, so every line a
  long name wraps onto pushed it upward, past the top of the hero and under the
  back button. Capped at two lines now, and a name that needs more scrolls
  top-to-bottom, holds, and starts over. Reduce-motion turns the scroll off and
  leaves it clipped. **Battery Saver deliberately does not gate it:** it defaults
  to `true`, so honouring it here would leave the overflowing name unreadable for
  almost everyone, and the ticker only runs while a sheet whose name actually
  overflows is on screen.
- **#143** depth prompt in Edit Character → Advanced settings — **removed.** The
  three controls (prompt, role, depth) and the untranslated `Injected at a
  specific depth in the prompt` placeholder are gone. The values stay on the
  `Character` — they are part of the SillyTavern V2 card — and are still seeded
  into the editor's item map and written back on save, so an imported card keeps
  its depth prompt and survives a round trip through this editor. Only the
  controls are gone.

13 new tests (7 on the numbering and the scroll phase, 6 widget tests mounting
`PresetEditorBody`). Full `flutter test` green. **Not verified:** the marquee's
speed and hold, and how the two header buttons sit next to the sheet's title,
both want eyes on a phone. The first-messages card has no widget test — the
accordion widgets are private to a 1900-line screen and splitting that file is a
separate change — so the numbering is tested and the layout is not.

### G31 — `fix/jar-background` (1 card)
- **#58** JAR extraction dies when the app is backgrounded. Backgrounding must not kill it — the same foreground-service treatment generation already gets

### G32 — `fix/janitor-custom-tags` (1 card)
- **#69** Catalog filters must offer JanitorAI's live popular custom tags: read `top_custom_tags` from `https://janitorai.com/hampter/characters` and append them **after** the standard tags. Search already works

### G33 — `fix/st-lorebook-settings` — **PR [#440](https://github.com/hydall/Glaze/pull/440)**
- **#135**, two separate losses, both confirmed. **The book's own settings were
  never written out:** `glazeLorebookToSTJson` emitted `{name, entries}` and
  nothing else, so a whole screen of tuning (scan depth, budget cap and reserve,
  insertion strategy, injection position, the vector knobs) was dropped on
  export, and the importer never looked for it either. They ride along in a
  book-level `glazeMetadata` now, the way the entry-level Glaze fields already
  do; the description travels with them. Two cases on purpose: a book with no
  `glazeMetadata` — one SillyTavern wrote — keeps Glaze's defaults rather
  than having values invented for it, and settings that no longer parse cost the
  *tuning* rather than the import.
- **The tri-state entry flags were flattened.** `caseSensitive` and
  `matchWholeWords` are `bool?` on an entry and null means "follow the book,
  then the global" — `LorebookScanner` resolves
  `entry.caseSensitive ?? book ?? global`, which is also what SillyTavern means
  by them, and that resolution order already encoded in Glaze's own scanner is
  the cross-check the card asked for. The importer's `?? false` turned
  "inherit" into an explicit "never", so an entry imported from ST silently
  stopped following a global the reader had set on purpose — silently, because
  the switch reads the same either way.

10 new tests in `st_lorebook_settings_test.dart` (the existing
`st_lorebook_roundtrip_test.dart` is untouched), including all three states of
both flags in both directions; negative control confirmed. **Not verified
against SillyTavern itself:** the round trip here is Glaze → JSON → Glaze.
That ST loads a file carrying the extra key follows from its importer ignoring
unknown keys — the same assumption the existing entry-level `glazeMetadata`
already rests on — but opening one in a real ST install is what would confirm
it.

### G34 — `fix/android-file-picker` — **PR [#430](https://github.com/hydall/Glaze/pull/430)**
- **#32** a fresh export is missing from the picker under the Downloads
  shortcut — **cause found, fix is Android-runtime and untestable here.** The
  picker reaches the Glaze folder two ways and only one walks the filesystem:
  from the device root through `ExternalStorageProvider`, which lists real
  directories and sees everything, and through the Downloads shortcut through
  `DownloadsProvider`, which lists `MediaStore` rows. `FileExportService` writes
  every Android export with plain file IO (`writeAsString` / `writeAsBytes` /
  `copy`) into `/storage/emulated/0/Download/Glaze/<subfolder>`, which puts the
  bytes on disk and leaves the media database none the wiser — real, reachable
  from the root, invisible under the shortcut, exactly as reported. A new
  `app.glaze.flutter/media_store` channel over `MediaScannerConnection.scanFile`
  registers the file, and all three export paths call it after the write lands.
  Fire-and-forget (the Kotlin side answers when the scan is handed off, never
  leaving an export awaiting a callback that may not come) and it can never fail
  the export — the file is already written by then, and every non-Android
  platform answers `notImplemented`. Safe where Android 11+ already indexed the
  file through MediaProvider's FUSE layer: a scan of an indexed file is a no-op.

3 new tests over the channel. `flutter build apk --debug` run to compile the
Kotlin — CI runs `analyze` and `test` only, so nothing in the pipeline would
catch a mistake in `MainActivity.kt`. Full `flutter test` green. **Not
verified:** whether the shortcut then lists the file is an Android-runtime
question no test here can answer. If it survives this, the next step is writing
through `MediaStore.Downloads` instead of raw file IO — a bigger change, worth
making only once we know a scan is not enough.

### G35 — `fix/message-delete-race` — **PR [#424](https://github.com/hydall/Glaze/pull/424)**
- **#78** deleted messages come back — **the reported cause was already fixed; its
  mirror was not.** `ChatSessionWriteQueue` exists for exactly this symptom and its own
  doc says so ("deleted messages come back the moment you flip a variation"): one queue
  for every durable session write, plus publication tokens so an older commit still
  writes but no longer repaints. What was left is the same race from the delete's side:
  `commitDeleteMessages` wrote the shortened list **the plan carried**, wholesale. The
  plan is computed on the frame of the tap (that is the point — the bubbles have to go
  immediately) and the transaction behind it is long on a big chat, so anything that
  reached the row in that window was written back out by the delete: a reply that
  finished streaming was erased, a variation switch that had committed was undone, and
  the row disagreed with the screen until the chat was reopened. The deletion is now
  re-applied by message id *inside* the transaction against the row as it is, and the
  deleted counter is read from the row so two deletions in flight each add their own.
  Messages predating ids fall back to the planned list — an index-based delete is only
  correct against the snapshot it came from.

  2 new tests; the race one fails on nightly, the legacy-id one is a negative control.

### G36 — `fix/sheet-flicker` — **PR [#422](https://github.com/hydall/Glaze/pull/422)** — partial
- **#148** the whole sheet flashes white while editing the summary — **two real sources
  of churn fixed; the flash itself not reproduced.** The Memory sheet watched
  `summaryEnabledProvider` from `build`, and every summary write bumps the revision that
  provider keys on — the debounced save while the reader types, and every auto-summary
  during a chat — so each write rebuilt the chrome, re-measured the header and rebuilt
  both tab bodies to move one switch. And the expanded field editor pushed every
  keystroke into the underlying field's controller *and* called `setState` on the form
  holding it, which that controller already repaints on its own.

  **Leading hypothesis for the white, written down so nobody has to find it twice:** the
  expanded editor is a `MaterialPageRoute(fullscreenDialog: true)` on the root
  navigator, i.e. over the sheet, and Flutter's Android page transitions paint a
  full-screen `ColoredBox` of `ColorScheme.surface` behind the transition
  (`page_transitions_theme.dart:115` and `:547`). In the **light** theme that surface is
  near-white, so opening or closing that editor would paint the screen near-white for
  the length of the transition. If that is it, the fix is a `PageTransitionsTheme`
  decision affecting every route in the app — not something to change on a guess.
  **Ask the reporter:** platform, light or dark theme, and whether the flash comes with
  the expand button (and again on close) or while typing in the small field.

  No new test: the only harness that mounts this sheet is the opt-in golden one, and a
  widget test around it hung on the sheet's post-layout header measurement. The change
  is scope-of-rebuild only — nothing on screen differs.

### G37 — `fix/guided-ui` (1 card)
- **#6** Port the Vue Guided Generation UI **1:1** — the current one is rough, and the preset editor still has no way to edit the guided prompts

### G38 — `fix/shino-default` — **PR [#431](https://github.com/hydall/Glaze/pull/431)**
- **#28** Shino as the default for fresh installs, drop `Default Chat` —
  **done, with one half deliberately left undone.** "Default Chat" was a bare
  skeleton — a main prompt, an NSFW block, a one-line jailbreak — assembled
  inline in `preset_seeder.dart` and written before anything else; nobody chose
  it, it simply sorted first, and `getEffectivePreset` falls back to "first
  available preset" when no active one is set. It is no longer created, and a
  first run is pointed at `default_shino`, which `seedFeaturedPresets` already
  builds from `assets/presets/shino.json`. The decision is a pure function so
  the cases that must *not* be touched are stated rather than implied: an
  install past its first run, and any install that already has an active preset
  — a restored backup and a Vue migration both write one and can both leave the
  first-run flag clear (`js_backup_importer` clears it on purpose).
- **Where it runs is the interesting part.** The obvious version — a startup
  task that writes `activePresetIdProvider` once SharedPreferences is open —
  **fails `navigation_smoke_test` deterministically** on two back-navigation
  cases. Writing the provider a couple of `await` hops later than
  `loadActiveSelections` does leaves it dirty while the router builds its first
  routes; a `ConsumerStatefulWidget`'s ticker mode flips during an overlay
  build, Riverpod resumes the suspended subscription and flushes there, and the
  resulting `scheduleRefresh` calls `setState` during build. Checked that it is
  the *timing* and not the value: seeding `activePresetId` into the smoke
  test's preferences on `nightly`, so startup publishes a non-null preset the
  ordinary way, leaves all 23 cases green. `applyFirstRunPresetChoice` therefore
  runs from `main()`, beside the other one-shot preference migrations — by the
  time startup reads the preference the value is simply there, and it is
  published exactly as it is for any install that already had one.
  `loadActiveSelections` is untouched.
- **Not done on purpose:** existing installs keep their Default Chat. Deleting
  it would destroy whatever the user edited into it and break any chat or
  character bound to it through `presetConnections` — irreversible, and not what
  "для свежих" asks for. Removing it by hand is one action in the Presets list.
  Asked in the PR whether a migration that deletes it for everyone is wanted.

7 new tests (the decision in isolation, the same through
`applyFirstRunPresetChoice` against mock preferences, and a contract test that
`defaultPresetId` is an id `featuredPresets` actually ships). Full
`flutter test` green. **Not verified:** what a genuinely fresh install lands on
— wiping an install and watching the first chat pick Shino is the check that
would close it.

### New functionality with a spec — not a bug, kept separate
- **#60** Add prompt editing for JAR (how lorebook keys get built, etc.) under **Third Party Providers**; during lorebook extraction a settings button appears in the header that leads there. You gave a full spec, so it is not going into `features` blind — but it is new functionality, so it queues after the bug groups.

### Verify-only — **done.** Six closed, one reopened
You answered "seems fixed, but check" on these. Checked against `nightly` on
2026-09-14; six moved to **Fixed**, #49 stays on the board and folds into G14.

| # | Card | Verdict |
|---|---|---|
| 12 | no proxy for jar | **fixed** → Fixed |
| 43 | separate advanced/simple closed lorebooks | **fixed** → Fixed |
| 49 | prompt inspector sab | **NOT fixed** — reopened, folded into G14 |
| 73 | search on pc | **fixed** → Fixed |
| 128 | 405 Naistera | **fixed** → Fixed |
| 130 | decouple embedding settings | **fixed** → Fixed |
| 138 | trigger type dropdown in memory books | **fixed** (the control is gone) → Fixed |

- **#12** — the capture does exactly what the card asked for and undoes it.
  `JanitorWebViewProxy` forces the account into proxy mode against a throwaway
  unreachable preset (`_enterExtractionMode`), because an account on JLLM
  (`"janitor"`) never assembles a proxy prompt and `generateAlpha` is what the
  capture reads. The snapshot is restored in the `finally`
  (`_restoreProfile`), and a mutex guards the whole run — two overlapping
  captures would restore each other's snapshots and leave the account
  misconfigured.
- **#43** — the two kinds are separated all the way through. `publicJsonBooks`,
  `publicJsBooks` and `closedLorebooks` partition what the character carries;
  the Public section splits into "Lorebooks" and "Scripts" sub-groups when both
  are attached (flat when only one kind is, since there is then nothing to tell
  apart), and the two carry *different actions on different pipelines* — JSON
  downloads 1:1 with no LLM, a JS/Nine-API book opens an explanation and is
  rebuilt by the model (`_downloadJs` → `_buildJs`).
- **#49** — **the audit's "already fixed" was wrong, and this is a real bug.**
  The inspector is built on `SheetView`, which publishes the nav-bar/gesture
  inset through `MediaQuery.padding.bottom` and *relies on the body to consume
  it* — the comment in `sheet_view.dart` says so, and the point is that a
  scrollable body treats the inset as scroll content padding so rows stay
  visible behind the nav bar while the last row rests above it. Both inspector
  bodies break that contract by passing an explicit `padding` to their
  `ListView`, which replaces the MediaQuery-derived one outright:
  `RequestTimelineView._timeline` passes
  `const EdgeInsets.fromLTRB(12, 12, 12, 24)`, and
  `TokenizerSheet._buildMainView` passes `EdgeInsets.all(16)` plus the *top*
  inset only. The published bottom inset is discarded in both, so the last row
  sits under the nav bar. Same defect family as **G14 #106** (the bottom action
  row under the nav bar), which is why it belongs there rather than in a branch
  of its own.
- **#73** — fixed by the desktop parity work (PR #352, 2026-08-31): "Search
  lives permanently in the desktop header and follows the query." Desktop now
  carries the sidebar's dialog search (`DesktopLeftSidebar._buildSearchField`
  into `ChatHistoryList`), and screen-published header actions bring the
  settings search into the window title bar. **Caveat:** the card never said
  *which* search, so this closes the three that exist; a specific one still
  misbehaving needs a fresh report.
- **#128** — fixed by the sillyimages port, and the 405 is named in the code:
  the retired `/prompt/api/img` route answers 405 Method Not Allowed, and
  `NaisteraImageProvider` now posts `{base}/api/generate` with `job_id`
  polling. `normalizeModel` maps retired model labels onto ids the API still
  accepts, so a settings blob written by an older build keeps generating.
- **#130** — decoupled. Embedding presets have their own list
  (`embeddingPresetListProvider`), their own active id
  (`activeEmbeddingPresetIdProvider`), their own seeding key and their own tab;
  the shared `api_configs` table is partitioned by `mode == 'embedding'`. The
  last implicit coupling — "Use LLM API" borrowing *whatever the LLM tab
  happened to be on* — is gone too: the borrow now names which LLM preset it
  takes the endpoint from.
- **#138** — closed because the control it names no longer exists. The #408
  redesign replaced every Material control in the memory settings with kit
  rows: the `DropdownButton<int>`s (one entry per step — two hundred for the
  auto-create interval) became `MenuRangeItem`, and every picker became a
  `MenuSelectorItem` that opens a sheet from `onTap`. There is no
  `DropdownButton` anywhere under Memory Books now, so nothing there can fail
  to open. **If it was somewhere else:** the only real `DropdownButtonFormField`s
  left nearby are the four in the two lorebook settings screens
  (`label_key_search_mode`, `label_search_type`, `label_injection_position`,
  `label_lorebook_reserve_mode`) — still bare Material, and a UI-kit violation
  worth its own card.

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
| 1 | G1 continue-overhaul | `fix/continue-overhaul` | 118, 150 (119, 110 already fixed) | **merged** | [#410](https://github.com/hydall/Glaze/pull/410) | Done, not tested |
| 1 | G2 reasoning-render | `fix/reasoning-render` | 45 (123 covered, not reproduced) | **merged** | [#411](https://github.com/hydall/Glaze/pull/411) | Done, not tested |
| 1 | G3 streaming-bubble-state | `fix/streaming-bubble-state` | 141, 131 | **merged** | [#412](https://github.com/hydall/Glaze/pull/412) | Done, not tested |
| 2 | G8 lorebook-activation-scope | `fix/lorebook-activation-scope` | 99 | **merged** | [#413](https://github.com/hydall/Glaze/pull/413) | Done, not tested |
| 2 | G10 vision-capability | `fix/vision-capability` | 95 | **merged** | [#415](https://github.com/hydall/Glaze/pull/415) | Done, not tested |
| 2 | G17 draft-clear-on-send | `fix/draft-clear-on-send` | 121 | **merged** | [#414](https://github.com/hydall/Glaze/pull/414) | Done, not tested |
| 3 | G4 catalog-auth-resilience | `fix/catalog-auth-resilience` | 104, 113, 152, 89 | **merged** | [#416](https://github.com/hydall/Glaze/pull/416) | Done, not tested |
| 3 | G5 error-surface-normalization | `fix/error-surface-normalization` | 113, 120, 105 | **merged** | [#417](https://github.com/hydall/Glaze/pull/417) | Done, not tested |
| 4 | G12 ol-start | — | 136 | **already fixed** (PR #350) | — | Done, not tested |
| 4 | G13 audio-embed-overflow | `fix/audio-embed-overflow` | 100 | **merged** | [#418](https://github.com/hydall/Glaze/pull/418) | Done, not tested |
| 4 | G21 docs-and-readme | `fix/docs-and-readme` | 116, 33, 23, 146 | **merged** | [#419](https://github.com/hydall/Glaze/pull/419) | Done, not tested |
| 4 | G22 tab-scroll-position | — | 61 | **already fixed** (PR #358) | — | Done, not tested |
| 5 | G25 chat-first-open | `fix/chat-first-open` | 87, 154 | **merged** | [#421](https://github.com/hydall/Glaze/pull/421) | Done, not tested |
| 5 | G26 keyboard-inset | `fix/keyboard-inset` | 7 | **merged** | [#423](https://github.com/hydall/Glaze/pull/423) | Done, not tested |
| 5 | G35 message-delete-race | `fix/message-delete-race` | 78 | **merged** | [#424](https://github.com/hydall/Glaze/pull/424) | Done, not tested |
| 5 | G36 sheet-flicker | `fix/sheet-flicker` | 148 | **merged** | [#422](https://github.com/hydall/Glaze/pull/422) | Done, not tested |
| 6 | G27 protocols-pipeline | `fix/protocols-pipeline` | 71, 133 | **merged** | [#425](https://github.com/hydall/Glaze/pull/425) | Done, not tested |
| 6 | G28 permissions-and-battery | `fix/permissions-and-battery` | 29, 30, 53, 52 | **merged** | [#426](https://github.com/hydall/Glaze/pull/426) | Done, not tested |
| 6 | G29 presets | `fix/presets` | 47, 79, 25 | **merged** | [#427](https://github.com/hydall/Glaze/pull/427) | Done, not tested |
| 6 | G30 editor-ui | `fix/editor-ui` | 88, 57, 59, 143 | **merged** | [#428](https://github.com/hydall/Glaze/pull/428) | Done, not tested |
| 6 | G16 notification-icon | `fix/notification-icon` | 149, 9 | **merged** | [#429](https://github.com/hydall/Glaze/pull/429) | Done, not tested |
| 6 | G34 android-file-picker | `fix/android-file-picker` | 32 | **merged** | [#430](https://github.com/hydall/Glaze/pull/430) | Done, not tested |
| 6 | G38 shino-default | `fix/shino-default` | 28 | **merged** | [#431](https://github.com/hydall/Glaze/pull/431) | Done, not tested |
| 7 | G11 imggen-timer-cache | `fix/imggen-timer-cache` | 97 | PR open | [#435](https://github.com/hydall/Glaze/pull/435) | In Progress |
| 7 | G14 prompt-inspector | `fix/prompt-inspector` | 106, 153, 101, 49 | PR open | [#433](https://github.com/hydall/Glaze/pull/433) | In Progress |
| 7 | G15 update-checker | `fix/update-checker` | 132, 137 | PR open | [#438](https://github.com/hydall/Glaze/pull/438) | In Progress |
| 7 | G23 spoiler-reveal | `fix/spoiler-reveal` | 112 | PR open | [#439](https://github.com/hydall/Glaze/pull/439) | In Progress |
| 7 | G33 st-lorebook-settings | `fix/st-lorebook-settings` | 135 | PR open | [#440](https://github.com/hydall/Glaze/pull/440) | In Progress |
| 7 | G7 backup-onboarding-polish | `fix/backup-onboarding-polish` | 24, 111 | PR open | [#434](https://github.com/hydall/Glaze/pull/434) | In Progress |
| 7 | G9 janitor-greetings | `fix/janitor-greetings` | 98 | PR open | [#436](https://github.com/hydall/Glaze/pull/436) | In Progress |
| 8 | G18 promptworker-throughput | `fix/promptworker-throughput` | 126, 127 | not started | — | — |
| 8 | G19 saucepan-import-phase | `fix/saucepan-import-phase` | 117 | not started | — | — |
| 8 | G20 memory-auto-generate | `fix/memory-auto-generate` | 122 | not started | — | — |
| 8 | G31 jar-background | `fix/jar-background` | 58 | not started | — | — |
| 8 | G32 janitor-custom-tags | `fix/janitor-custom-tags` | 69 | not started | — | — |
| 8 | G37 guided-ui | `fix/guided-ui` | 6 | not started | — | — |
| 8 | G6 cloud-sync | `fix/cloud-sync` | 107, 115, 124, 134 | not started | — | — |
| — | G24 chat-perf | `fix/chat-perf` | 91, 92 | deferred to the 0.7.1 overhaul | — | — |
| — | JAR prompt settings | — | 60 | new functionality, queued after the bugs | — | — |
| — | verify-only | — | 12, 43, 73, 128, 130, 138 | **done** — six closed, #49 folded into G14 | — | Fixed |
| — | glossary categories | `fix/glossary-categories` | — (no card) | **merged** | [#432](https://github.com/hydall/Glaze/pull/432) | — |

**Waves 1–6 are merged.** All 21 PRs (#410–#432) are on `nightly` and every card
they carry is in **Done, not tested**. The cards await a build on a device, not
more code.

**Wave 7 is done** — all seven groups shipped (#433–#440), and three of the
seven cards in it turned out not to be the bug the card described:

| Card | What the check actually found |
|---|---|
| #97 | the reported retry reset is already fixed; a *re-render* mid-generation resets the clock, which is worse |
| #98 | the local-extraction title is wrong; DataCat is the reproducible half, and the Janitor browse path had the inverse bug |
| #106 | the audit's `useSafeArea: true` would have been wrong; the cause is a discarded `MediaQuery` inset |
| #137 | already fixed by PR #350; now covered |
| #101 | measured rather than changed — the strip centres correctly, and the report needs the screenshot read back |

**Wave 7 split in two.** Fourteen groups is twice wave 6, so it runs as two:

- **Wave 7 — self-contained.** G7, G9, G11, G14, G15, G23, G33. Each is one
  screen or one service with a mechanism the audit already names; none touches a
  subsystem another group is in. G14 is the largest at four cards now that #49
  joined it.
- **Wave 8 — heavy or blocked.** G6, G18, G19, G20, G31, G32, G37. G37 is a 1:1
  port of the Vue Guided Generation UI plus new preset-editor surface, G18 is
  throughput work in the prompt worker, and the JAR pair (G31, G32) both sit in
  the capture flow, so they are cheaper together than apart. **G6 carries a
  blocker that is not code:** #107 needs a fresh Google Cloud OAuth client (PKCE,
  no secret) created under the maintainer's account — the shipped one is revoked
  and answers `401 invalid_client` for every user. Its other three cards (#115,
  #124, #134) can ship without it.

**Drive-by, no card:** the EN and RU glossaries agreed on all 73 term ids but not
on where they sat — EN cross-listed `chat-session` and `connections` under
Characters as well as Chat and filed `character-hiding` under Characters, RU had
all three under Chat alone. A Russian reader looking for character-hiding under
Персонажи did not find it. RU follows EN's placement now, text untouched, and
the parity test — which checked term ids and category ids but never which
category a term was *in*, which is why this drifted unnoticed — covers placement.

**Decisions taken (2026-09-14), recorded so they are not re-litigated:**

| Question | Answer |
|---|---|
| Migration deleting `Default Chat` for existing installs (#28)? | **no** |
| Migrate legacy character-scoped lorebooks to `enabled: false` (#99)? | **no** |
| Build the per-config "supports images" flag (#95)? | **no — no heuristics** |
| Align the RU glossary's categories to EN? | **yes** — done, PR #432 |
| Enable the Discord Server Widget (#116)? | **no** — the badge stays static |
| Chase #148's white flash with the reporter? | ignore for now |
| Google Cloud OAuth client for #107? | ignore for now — G6 ships its other three |
| `Stale/not confirmed` as its own board? | **no** — stays a list |
| #60 JAR prompt settings? | **last**, after the bug waves |

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
