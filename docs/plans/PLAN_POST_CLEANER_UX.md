# PLAN: POST-cleaner UX improvements (4 fixes)

**Branch:** `plan/continuity-post-cleaner` (current). **Commit each phase separately on this branch.** No new branches, no PR yet — just sequential commits.

**Repo:** `Z:\GlazeProject\glaze_flutter`. Flutter 3.44 + Riverpod 2 + Drift + freezed. Read `CLAUDE.md` first.

**Commands** (flutter may not be on PATH — fall back to full path):
```powershell
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build   # after editing pipeline_settings.dart (freezed)
```

After editing `assets/chat_webview/**`, the **user** must HOT RESTART (press `R`), not hot reload. The agent cannot run `flutter run`.

---

## Background / root-cause analysis (already done — do not re-investigate)

The user reported 4 issues with the POST-cleaner. Investigation findings (with file:line):

1. **Cleaner streams into the EXISTING bubble, swipe created only at the end.** `generation_pipeline.dart:753-764` streams via `StreamingState(targetMessageId: lastAssistant.id)`. The blue "cleaned" swipe is created only at the very end via `applyCleanedText` → `appendAgentSwipe(kind:'cleaned')` (`post_cleaner_service.dart:390`, `chat_repo.dart:267`), and **only when `wasCleaned==true`** (`generation_pipeline.dart:830-845` early-returns otherwise). On the user's timeout, `wasCleaned=false` → no swipe at all.

2. **Audit ("Аудит персонажа и мира") and cleaner-rewrite share ONE model.** Both call `resolveConfigForCleaner` (`sidecar_llm_client.dart:105`): audit at `post_cleaner_service.dart:472` (`errorLabel:'post-cleaner-audit'`), cleaner at `:81` (`errorLabel:'post-cleaner'`). There is no separate audit model field.

3. **Cleaner elapsed time is NOT in the timer.** The JS `GenTimer` (`assets/chat_webview/bridge/gen_timer.js`) only runs while `isGenerating==true` and writes only into the `__streaming__` element. By the time the cleaner runs, `isGenerating` is already `false`, and the cleaner targets the existing message id, not `__streaming__`. So cleaner time is never displayed.

4. **Token badge disappears on the cleaned swipe.** `appendAgentSwipe(kind:'cleaned')` is called WITHOUT `genTime`/`tokens` (`post_cleaner_service.dart:396-401`), so the new active swipe has `genTime:null, tokens:null`. The mapper omits null fields (`chat_message_mapper.dart:142-143`), so the renderer hides the whole badge (`message_renderer.js:398-401`).

**Why the user's specific run made no swipe:** confirmed in DB — last assistant message of session `mql29fxr0001_3` has exactly 1 agentSwipe `kind=final`. The cleaner-rewrite pass hit `TimeoutException after 0:02:00` on all 3 attempts → `wasCleaned=false` → early return, no swipe. (Audit pass succeeded: `issues=3`.) This is correct error handling, not a bug — but the UX fixes below change the behavior the user wants.

---

## USER DECISIONS (authoritative — implement exactly these)

- **Fix 1 (swipe-first streaming):** Create the blue `cleaned` swipe **at cleaner start** and stream into IT (not the final bubble). On failure, **keep whatever the cleaner already wrote, even if truncated.** Only if the cleaner wrote **nothing at all** (0 chunks received) → delete the empty swipe and revert to `final`. (The user noted the cleaner WAS streaming text live; on timeout that partial text must be preserved.)
- **Fix 2 (separate audit model):** Add a **model selector only** for the audit (not full endpoint/key set). Audit inherits endpoint/key/source from the cleaner config; only the model can differ. Falls back to the cleaner model when the audit model field is empty.
- **Fix 3 (cleaner timer):** Show a **separate badge on the cleaned swipe** = the cleaner's own elapsed time (distinct from the final swipe's genTime). Each swipe shows its own time. Do NOT keep the global GenTimer running.
- **Fix 4 (token badge):** Pass `genTime`/`tokens` into the cleaned swipe so the badge stays visible. (Cleaner elapsed time feeds the `genTime` per Fix 3; tokens = the cleaned response's token count if available, else carry over / estimate.)
- **All work = sequential commits on `plan/continuity-post-cleaner`.** One logical commit per phase.

---

## CRITICAL technical constraint for Fix 1 (read carefully)

On timeout/error, `SidecarCallOutcome.text` is **null** (`sidecar_retry_runner.dart:16-18` — "Null on any failure"). The partial streamed text the user saw lives only in the `onChunk` accumulator inside `_streamLlm` (`sidecar_llm_client.dart:339-376`) and is forwarded to the caller's `onCleanedChunk` callback live, but is **discarded** when the attempt throws.

Therefore, to "keep what the cleaner wrote on failure," the pipeline must **capture the last accumulated chunk itself** via the `onCleanedChunk` callback (it already receives every accumulated chunk at `generation_pipeline.dart:753`). Store the latest non-empty accumulated text in a local var (e.g. `String lastStreamedText = ''`). Then:
- `wasCleaned==true` → finalize swipe with `result.cleanedText` (as today).
- `wasCleaned==false` BUT `lastStreamedText.trim().isNotEmpty` → finalize the swipe with `lastStreamedText` (truncated rewrite). Mark status so the ops log shows it was a partial/timeout save.
- `wasCleaned==false` AND `lastStreamedText` empty → delete the pre-created empty swipe, revert to `final`.

Note: retries reset the accumulator and re-call `onChunk` from `''` (`sidecar_llm_client.dart:227-231`). So `lastStreamedText` naturally tracks the latest attempt's partial output. Guard against storing empty strings (only overwrite when the incoming chunk is non-empty/longer).

---

## PHASES

### Phase 1 — Fix 4 + Fix 3: cleaned swipe carries genTime (cleaner elapsed) + tokens (badge fix)
Smallest, lowest-risk. Do this first.

**Goal:** When the cleaned swipe is created, populate `genTime` (= cleaner elapsed, formatted like the main badge, e.g. `"12s"`) and `tokens`.

**Files:**
- `lib/core/llm/post_cleaner_service.dart` — `applyCleanedText` (line 390). Add params `String? genTime`, `int? tokens`; pass them through to `appendAgentSwipe`.
- `lib/features/chat/services/generation_pipeline.dart` — at the `applyCleanedText` call (line 841): compute `genTime` from `result.totalElapsedMs` (format helper below) and pass it. For `tokens`: prefer a token count from the cleaner outcome if exposed; otherwise estimate from `result.cleanedText.length` (rough `length ~/ 4`) OR carry over `lastAssistant.tokens`. **Confirm with how the main badge computes tokens** — search `stream_generation_service.dart` for where `tokens` is set on the final message (investigation noted lines ~260-270 / 487-499) and reuse the same source/estimator for consistency.
- Time formatting: find the existing helper that turns elapsed ms → `"Ns"` string used for the main `genTime` (grep `genTime` in `stream_generation_service.dart` / `saved_message_writer.dart`). Reuse it; do NOT invent a new format.

**Verify:** `flutter analyze`; `flutter test`. Ask user to hot-restart and confirm the blue swipe now shows a time+token badge.

**Commit:** `fix(cleaner): cleaned swipe carries genTime (cleaner elapsed) + tokens so badge persists`

---

### Phase 2 — Fix 1: swipe-first streaming + preserve partial text on failure
The behaviorally biggest change. Do after Phase 1 so badge metadata wiring already exists.

**Goal:** Create the `cleaned` swipe at cleaner start, stream into it, and on failure keep partial text (or delete swipe if nothing was written).

**Approach (in `generation_pipeline.dart` `_runPostCleaner`, lines 622-886):**
1. After the audit pass and right before `runCleaner` (≈line 746), pre-create an empty `cleaned` swipe: call a new `chatRepo` method or reuse `appendAgentSwipe(kind:'cleaned', content: lastAssistant.content)` seeded with the ORIGINAL text (so it's never visually empty), capture the resulting active `agentSwipeId`. **Decide:** seed with original text vs empty string. Recommended: seed with original `final` text so the bubble shows something immediately, then overwrite via streaming.
2. Change the `onCleanedChunk` callback to stream into the NEW cleaned swipe. Two options — pick the simpler that works with the existing WebView streaming path:
   - (a) Keep using `StreamingState(targetMessageId: lastAssistant.id)` for live rendering (visual only), and write the final text to the swipe at the end. The swipe already exists so the blue switcher shows immediately.
   - (b) Persist each chunk to the swipe (heavier DB writes). Avoid unless (a) doesn't render the blue switcher live.
   - Also store `lastStreamedText` from the callback (see "CRITICAL technical constraint" above).
3. After `runCleaner` returns:
   - `result.wasCleaned==true` → update the pre-created swipe's content to `result.cleanedText` + genTime/tokens (Phase 1 wiring). (If you seeded the swipe via `appendAgentSwipe`, you now need an **update-existing-swipe** method rather than append — see "New repo method" below.)
   - `wasCleaned==false && lastStreamedText.trim().isNotEmpty` → update the swipe with `lastStreamedText` (truncated); genTime = elapsed; status in ops log = `timeout`/`error` but mark `partialSaved`.
   - `wasCleaned==false && lastStreamedText` empty → **delete** the pre-created cleaned swipe, revert active swipe to the `final` (agentSwipeId back to the parent). Reset streaming state.
4. Keep tracker-snapshot cloning behavior (the `applyCleanedText` snapshot clone at `post_cleaner_service.dart:411-438`) for whichever path finalizes a real swipe.

**New repo method (likely needed):** `ChatRepo.updateAgentSwipeContent({sessionId, messageId, agentSwipeId, content, genTime, tokens})` to overwrite the pre-created swipe in place, and `ChatRepo.removeAgentSwipe({sessionId, messageId, agentSwipeId})` to delete it + reset `agentSwipeId` to parent and re-sync `swipesMeta`. Mirror the existing `appendAgentSwipe` transaction + `_syncAgentSwipesToMeta` logic (`chat_repo.dart:267-362`). Read `docs/rules/database.md` and `docs/rules/race-conditions.md` FIRST (atomic read-modify-write inside `_db.transaction`).

**Edge cases:**
- Abort mid-cleaner (`!abortHandler.isCurrentGen(genId)`): existing checks at lines 731/754/767. On abort, treat like "nothing useful" → delete the pre-created swipe (unless partial text exists and you choose to keep — confirm with user; default: delete on abort).
- Regen after cleaner: existing code intentionally skips `isCurrentGen` for the final refresh (lines 859-873). Preserve that.

**Verify:** `flutter analyze`; `flutter test`. Ask user to hot-restart and test: (a) normal clean → blue swipe with content; (b) force a timeout (set a tiny `postCleanerTimeoutMs`) and confirm partial text is kept; (c) confirm empty-cleaner case deletes the swipe.

**Commit:** `feat(cleaner): stream into cleaned swipe live; preserve partial text on failure`

---

### Phase 3 — Fix 2: separate audit model selector
Independent of 1/3/4.

**Goal:** Audit can use a different model than the cleaner rewrite; inherits everything else from cleaner config.

**Files:**
- `lib/core/models/pipeline_settings.dart` (line 50-62 block): add `@Default('') String postCleanerAuditModel,`. Run `dart run build_runner build` after.
- `lib/core/llm/sidecar_llm_client.dart`: add `resolveConfigForAudit(settings)` — same as `resolveConfigForCleaner` but model = `settings.postCleanerAuditModel.isNotEmpty ? postCleanerAuditModel : <cleaner-resolved model>`. Endpoint/key/source identical to cleaner. Keep `errorLabel:'post-cleaner-audit'`.
- `lib/core/llm/post_cleaner_service.dart`: `runCharacterAudit` (line 472) → call `resolveConfigForAudit` instead of `resolveConfigForCleaner`.
- `lib/features/chat/widgets/post_building_menu_dialog.dart` `_CleanerSection` (line 233): under the audit toggle (lines 278-287), add a model selector row for `postCleanerAuditModel` — reuse `_PipelineModelSelector` / `_CurrentApiModelRow` pattern already used for the cleaner model (lines 294-328). Only show it when `postCleanerCharacterCheckEnabled==true`. Label via a new translation key.
- Translations: add keys `post_building_cleaner_audit_model` (+ `_desc`) to `assets/translations/ru.json` AND `en.json` (find both; investigation referenced `ru.json:1702-1703`). Match the existing key naming.
- **Persistence/sync:** `postCleanerAuditModel` is part of `PipelineSettings` (freezed `toJson`/`fromJson`), persisted in the `pipeline_settings_rows` Drift table as JSON. Verify the settings repo serializes the whole `PipelineSettings.toJson()` (so the new field rides along automatically). Grep for where `PipelineSettings` is written/read (`pipeline_settings` repo/provider). If it's whole-object JSON, no extra work. Confirm backup + cloud-sync include pipeline settings (per CLAUDE.md "must persist in backup and cloud sync") — check `lib/features/cloud_sync` + backup whitelist; if pipeline settings already sync as a blob, the new field is covered. If individually mapped, add the field.

**Verify:** `flutter analyze`; `flutter test`. Hot-restart; confirm audit model selector appears under the audit toggle, persists across restart, and `[Sidecar] resolved ... for post-cleaner-audit model=<chosen>` shows the chosen model in logs.

**Commit:** `feat(cleaner): separate model selector for character/world audit`

---

### Phase 4 — Docs + final verification
- Update `docs/ARCHITECTURE.md` (POST-cleaner section) and `docs/rules/generation.md`: cleaned swipe now created at start, partial-text-on-failure semantics, per-swipe genTime/tokens badge, separate audit model field.
- Update `docs/INVARIANTS.md` if any POST-cleaner invariant changes (swipe lifecycle).
- Full run: `flutter analyze` (0 errors) + `flutter test` (all pass — current baseline 1339 passed).
- **Commit:** `docs: POST-cleaner swipe-first streaming, partial-save, audit model`

---

## Verification checklist (every phase)
- [ ] `flutter analyze` → 0 errors
- [ ] `flutter test` → all pass (baseline 1339)
- [ ] `dart run build_runner build` ran if `pipeline_settings.dart` changed
- [ ] Committed on `plan/continuity-post-cleaner` with a clear message
- [ ] If `assets/chat_webview/**` touched → told user to HOT RESTART (R)

## Key file map
| Concern | File:line |
|---|---|
| Cleaner orchestration | `lib/features/chat/services/generation_pipeline.dart:622-886` (`_runPostCleaner`) |
| Stream chunk callback | `generation_pipeline.dart:753-764` |
| wasCleaned early-return | `generation_pipeline.dart:830-845` |
| Apply cleaned / append swipe | `lib/core/llm/post_cleaner_service.dart:390-439` (`applyCleanedText`) |
| Cleaner service run | `post_cleaner_service.dart:55-170` (`runCleaner`) |
| Audit pass | `post_cleaner_service.dart:453-...` (`runCharacterAudit`), config at `:472` |
| Append swipe (DB) | `lib/core/db/repositories/chat_repo.dart:267-362` (`appendAgentSwipe`) + `_syncAgentSwipesToMeta` |
| Config resolver | `lib/core/llm/sidecar_llm_client.dart:105-156` (`resolveConfigForCleaner`) |
| Timeout resolve | `sidecar_llm_client.dart:160-164` |
| Stream accumulator (partial text source) | `sidecar_llm_client.dart:339-376` (`_streamLlm`) |
| Outcome.text null on failure | `sidecar_retry_runner.dart:16-18` |
| Settings model | `lib/core/models/pipeline_settings.dart:50-62` |
| Cleaner settings UI | `lib/features/chat/widgets/post_building_menu_dialog.dart:233-372` (`_CleanerSection`) |
| Badge render (WebView) | `assets/chat_webview/renderer/message_renderer.js:351,398-401` |
| Mapper omits null badge fields | `lib/features/chat/bridge/chat_message_mapper.dart:142-143` |
| Gen timer (JS) | `assets/chat_webview/bridge/gen_timer.js` |
| PostCleanerResult | `post_cleaner_service.dart:689-707` |
| PostCleaner status card | `lib/features/chat/widgets/post_cleaner_status_card.dart` |

## Suggested order
Phase 1 (badge metadata) → Phase 3 (audit model — independent, easy) → Phase 2 (swipe-first + partial save — biggest) → Phase 4 (docs). Phase 1 before 2 because 2 reuses the genTime/tokens wiring. Phase 3 can slot anywhere.

---

## Execution log (commits on `plan/continuity-post-cleaner`)

- `06e5486` — docs: plan committed.
- `df5901a` — **Phase 1**: `applyCleanedText` forwards `genTime` + `tokens` into `ChatRepo.appendAgentSwipe`; `generation_pipeline` computes them at the call site (`genTime = '${(totalElapsedMs/1000).toStringAsFixed(1)}s'`, `tokens = estimateTokens(cleanedText)`). Tokenizer import added to pipeline. Tests: 92 post-cleaner + pipeline tests pass.
- `38fe5a4` — **Phase 3**: new `PipelineSettings.postCleanerAuditModel` field (freezed regenerated); `SidecarLlmClient.resolveConfigForAudit` (reuses cleaner resolver, swaps model); `runCharacterAudit` switched to it; UI text-field under the audit toggle; ru/en translation keys.
- `121d736` — **Phase 2**: swipe-first streaming + partial-text preservation. Pre-create empty `'cleaned'` swipe at cleaner start (snapshot cloned); `_lastStreamedText` captured in `onCleanedChunk`; finalize via `ChatRepo.updateAgentSwipeContent` / `removeAgentSwipe` (new atomic methods); abort + hard-failure paths remove the pre-created swipe; legacy `applyCleanedText` fallback when pre-create failed. Full suite 1339 tests pass.
- (this commit) — **Phase 4**: docs (ARCHITECTURE / rules/generation / INVARIANTS INV-ST4 + INV-TS5 / rules/database) updated; this execution log appended.

## Known gaps

- ~~`pipeline_settings_rows` is NOT in the backup whitelist~~ → **CLOSED** (commit below): added to `backup_exporter._knownTableNames` (bumped `_schemaVersion` to 6) and a full cloud-sync adapter (`SyncPipelineSettingsStore` + `PipelineSettingsSyncStore` wired through `SyncManifestBuilder` / `SyncEngine` / `SyncService` / `sync_provider`; new `'pipeline_settings'` case in `cloudPath()`; `SyncManifest.currentVersion` bumped to 5 so the new entity type is pushed on the next sync). The entire `PipelineSettings` object (including `postCleanerAuditModel`) now exports to `.glz` backups AND round-trips through cloud sync.
- The new `ChatRepo.updateAgentSwipeContent` / `removeAgentSwipe` methods have no dedicated unit tests (the existing `ChatRepo` tests require a full Drift harness; the post_cleaner characterization tests cover model serialization, not the repo). Verified via the full 1339-test suite (no regressions) + `flutter analyze` (0 errors).

## Follow-up commit (backup + cloud-sync gap closure)

- `(this commit)` — **Backup + cloud-sync for `pipeline_settings_rows`**:
  - `backup_exporter.dart`: `_schemaVersion` 5 → 6; `'pipeline_settings_rows'` added to `_knownTableNames()`. Importer is generic (`tables/*.jsonl` → `INSERT OR REPLACE` by column names) so the table restores automatically — no importer changes needed.
  - `pipeline_settings_repo.dart`: new raw-map API (`getAllRaw` / `getRawBySessionId` / `putRaw`) so the cloud-sync adapter exchanges `{sessionId, settings, updatedAt}` maps without coupling to the freezed `PipelineSettings` shape.
  - `sync_repo_interfaces.dart`: new `SyncPipelineSettingsStore` interface (`getAll` / `getBySessionId` / `putRaw` / `deleteBySessionId`).
  - `adapters/ext_blocks_sync_stores.dart`: new `PipelineSettingsSyncStore` adapter wrapping `PipelineSettingsRepo`.
  - `sync_models.dart`: new `'pipeline_settings'` case in `cloudPath()` (→ `/Glaze/pipeline_settings/<sessionId>.json`); `SyncManifest.currentVersion` 4 → 5 (history comment added) so the new entity type is pushed on the next sync rather than hash-skipped.
  - `sync_manifest.dart`: `SyncManifestBuilder` gained a `_pipelineSettingsStore` field + ctor param + a `buildLocalManifest` loop (after `studio_config` entries) that hashes raw entries and resolves `updatedAt` from the row's `updatedAt` when present.
  - `sync_engine.dart`: `SyncEngine` gained a `_pipelineSettingsStore` field + ctor param; `pushEntities` ensures `/Glaze/pipeline_settings`; `_readLocalEntity('pipeline_settings', id)` returns the raw entry map verbatim; `_applyCloudEntity` calls `putRaw` (with `sessionId` fallback to entry id for older pushes); `_deleteLocalEntity` calls `deleteBySessionId`.
  - `sync_service.dart`: `SyncService` gained the field + ctor param; threaded through both the `_manifestBuilder` and `_engine` getters.
  - `sync_provider.dart`: wired `PipelineSettingsSyncStore(ref.watch(pipelineSettingsRepoProvider))`.
  - Tests: added `FakePipelineSettingsStore` to both `ext_blocks_sync_test.dart` and `sync_lifecycle_test.dart`; updated their `InMemoryManifestProvider` + `SyncWorld` wirings. `flutter analyze` 0 errors; full suite 1339 passes.
