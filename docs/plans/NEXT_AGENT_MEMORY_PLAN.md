# Plan For Memory Hardening

Goal: strengthen memory duplicate/noise protection after the current Studio memory-window changes.

## Branch And State

Current branch: `feat/studio-settings-presets`

Latest commits:

- `bc6dab72 fix: tune studio context defaults`
- `601cfd1c fix: split studio memory windows`
- `15f00f6f fix: tolerate no-op studio ledger output`
- `0c170b53 fix: make studio preset blocks scroll on mobile`
- `f41e267c feat: expand studio preset settings`

The working tree was clean at the end of the previous session.

## Context

Already done:

- Final generator default history is `15`.
- Pre-generation trackers default history is `5`.
- Cleaner/post-cleaner use the final-window prompt and memory cutoff.
- Studio final memory toast/status reflects final-agent injections.
- MemoryBook source-window exclusion works through `visibleMessageIds`.
- Studio builds separate prompt payload/results for tracker-window and final-window.

Important:

- Do not remove `{{memory}}`. It is a dynamic context slot.
- `LlmRequestDump.enabled` must remain `false`.
- Generated `.freezed.dart` / `.g.dart` files are gitignored.
- After changing freezed/drift models, run:
  `& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build`

## Main Findings

Existing capabilities:

- MemoryBook source-window exclusion.
- MemoryBook candidate merge by `entry.id`; keyword/vector/catalog scores do not create duplicate injections for one entry.
- MemoryBook diversity penalty by title/key/arc token overlap.
- Manual/optional auto LLM dedup through `MemoryDedupService`.
- Raw message recall chunks through `ChatMessageEmbeddingService` + `MessageRecallService`.

Gaps:

- Raw `<recalled_messages>` can return chunks from messages already visible in the active history window.
- Diversity is token/key-overlap based, not temporal-window based.
- Full Lumiverse-style consolidation is absent or not wired into the main retrieval path.
- Duplicate prevention on memory write is weaker than post-hoc dedup.

## Priority 1: Exclude Visible Window For Raw Message Recall

Task: do not inject raw `<recalled_messages>` when a recalled chunk contains `messageIds` already visible in the current agent history window.

Files:

- `lib/core/llm/message_recall_service.dart`
- `lib/core/llm/prompt_payload_builder.dart`
- `lib/features/chat/services/stream_generation_service.dart`
- Possibly `lib/core/llm/prompt_builder.dart`

Implementation notes:

- Add a parameter to `MessageRecallService.recall`: `Set<String> visibleMessageIds = const {}`.
- In the loop over recall results before adding a match, get `rawIds` and skip if they intersect `visibleMessageIds`.
- Pass visible ids from `prompt_payload_builder.dart` when known.
- Studio source-window ids are currently set after the base payload is built, so either raw recall exclusion must happen during finalization, or `PromptPayload`/finalization needs a way to remove recalled chunks by visible ids.
- Studio must use different windows:
  - tracker prompt excludes recalled chunks overlapping tracker-visible ids.
  - final prompt excludes recalled chunks overlapping final-visible ids.

Recommended minimal approach:

- Expand `PromptPayload` so raw recall matches are stored structurally, not only as a rendered string block.
- If that is too large, add a helper that rebuilds `recalledMessagesContext` from matches once the source window is known.
- Avoid a broad prompt-pipeline rewrite.

Checks:

- Normal non-Studio generation.
- Studio final prompt.
- Studio tracker prompt.

Tests:

- Unit test for `MessageRecallService` or helper: match with `messageIds = ['m10']` and `visibleMessageIds = {'m10'}` is excluded.
- Test that non-overlapping matches remain.
- Add a Studio-specific test if there is a convenient seam.

## Priority 2: Temporal Diversity For MemoryBook Selection

Task: prevent the MemoryBook injection budget from being filled by entries from the same small section of chat history.

File:

- `lib/core/llm/memory_selector.dart`

Current behavior:

- `_diversityPenaltyFor` calculates title/key/arc token overlap.
- It does not inspect `entry.messageRange`.

Implementation notes:

- Add temporal penalty/grouping to the selector.
- Use `MemoryEntry.messageRange?.end`.
- Possible window size: `10` messages for normal chats, or dynamic `max(10, currentMessageIndex ~/ 20)`.
- If a selected entry is already in the same temporal bucket, apply a penalty.
- Do not penalize `temporallyBlind` and core memory too strongly.
- Diagnostics should surface the resulting `diversityPenalty`.

Minimal implementation:

- In `_diversityPenaltyFor`, add temporal overlap in addition to token overlap.
- If candidate bucket equals picked entry bucket, add penalty.
- If ranges overlap, add `penalty * 0.5`.
- Clamp total penalty, for example up to `penalty * 2`.

Tests:

- Two high-score entries from one message bucket: the second receives a penalty.
- Entries from different buckets: no temporal penalty.
- `temporallyBlind` entry is not penalized or is penalized less.
- `excludedBySourceWindow` still works.

## Priority 3: Audit Lucy Chat

Task: read-only audit of the user's current DB, with no LLM calls and no DB writes.

DB:

- `C:\Users\Даниил\AppData\Roaming\glaze\glaze.db`

Goals:

- Understand how polluted Lucy's MemoryBook is with duplicates.
- Estimate how often entries compete with each other for injection budget.

Steps:

- Find Lucy chat/session by inspecting tables such as `characters`, `chat_sessions`, `memory_books`, or the actual current names.
- Search by character name/session title.
- For the selected session, count messages.
- Count MemoryBook entries.
- Count entries with `messageIds`.
- Count entries without provenance.
- Simulate per-turn windows:
  - tracker visible window: last `5` non-hidden messages.
  - final visible window: last `15` non-hidden messages.
- For each turn, identify entries excluded by tracker source-window.
- For each turn, identify entries excluded by final source-window.
- Identify entries that would remain candidates.
- Duplicate analysis:
  - exact normalized content duplicates.
  - near duplicates via token Jaccard or simple normalized word overlap.
  - same title/key/arc clusters.
  - same/overlapping `messageRange` clusters.
- Report:
  - top duplicate clusters.
  - how many entries likely compete for the same injection budget.
  - percent of entries from visible window.
  - examples of worst noisy entries.

Rules:

- Do not use LLM calls.
- Do not write to DB.
- If a temp script is needed, prefer `C:\Users\1678~1\AppData\Local\Temp\opencode`.
- Do not commit temp scripts unless explicitly asked.

## Priority 4: Stronger Write-Time Duplicate Prevention

Do not start this until P1/P2/P3 are completed.

Idea:

- Before writing Ledger/MemoryBook facts, search for similar existing entries.
- If same namespace/entity/key or high similarity, update/merge the existing entry instead of appending a duplicate.
- This is especially important for Studio Ledger durable facts.

Files to investigate:

- `lib/core/llm/studio_ledger_service.dart`
- `lib/core/llm/studio_ledger_export_parser.dart`
- `lib/core/db/repositories/memory_book_repo.dart`
- `lib/core/llm/memory_dedup_service.dart`
- `lib/core/llm/memory_embedding_service.dart`

## References

Marinara:

- `packages/server/src/services/memory-recall.ts`
- `readBehindMessageCount` keeps recent active messages out of durable recall chunks.
- `packages/server/src/services/agents/knowledge-router.ts`
- Merges semantic + keyword candidates via `Set`.
- Dedupes selected IDs from LLM result.

Lumiverse:

- `src/services/memory-cortex/retrieval.ts`
- `excludeMessageIds`.
- Multi-signal score fusion.
- Diversity selection by temporal window.
- `src/services/memory-cortex/consolidation.ts`
- Chunk consolidation and arc summaries.

## Commands

Use Flutter SDK path:

- Analyze: `& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze <files>`
- Tests: `& "Z:\GlazeProject\flutter\bin\flutter.bat" test <tests>`
- Format: `& "Z:\GlazeProject\flutter\bin\dart.bat" format <files>`
- Build runner if model changes: `& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build --delete-conflicting-outputs`

Do not run:

- `flutter run`
- `flutter test --watch`

## Likely Test Files

Existing useful tests:

- `test/studio_prompt_filtering_test.dart`
- `test/studio_seed_blocks_test.dart`
- `test/studio_ledger_test.dart`
- Search for memory selector tests with `test/*memory*`.

If adding tests:

- Add focused tests for `MemorySelector` temporal diversity.
- Add focused tests for raw recall visible-window exclusion.

## Caution

- Do not revert unrelated work.
- Do not touch local SQLite DB except read-only audit unless explicitly asked.
- Do not change `LlmRequestDump.enabled`.
- Keep changes minimal and composable.
- If modifying generated model fields, run build_runner.
- If modifying `assets/chat_webview/`, tell the user hot restart is needed. This task likely does not touch assets.
