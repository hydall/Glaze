# Refactoring follow-ups

This document records the evidence-based follow-up queue after the database and
Studio Ledger decomposition. File size alone is not a reason to refactor. Work
is prioritized when a boundary isolates business invariants, transactions,
asynchronous ownership, or a dependency fan-out that makes changes risky.

## Completed foundation

The `refactor/db-studio-dedup` work established the following boundaries:

- Historical Drift migrations, integrity repairs, Studio legacy migration code,
  preset seeds, and table domains no longer share one `app_db.dart` body.
- `StudioLedgerService` is a compatibility facade over injected prompt,
  recovery, diagnostics, canon, turn, replacement, and reconciliation
  specialists. Its transaction and stale-fence ordering remains covered by the
  existing characterization tests.
- Extension model loading and repository construction use their canonical
  implementations.
- Identical export results share `FileExportResult`, while deprecated aliases
  preserve the established public API.
- Reconciliation-state sync records accepted cloud aggregates separately from
  their normalized local representation, preventing repeated pull merges.

## 1. Automated Card Evolution

**Completed.** The decomposition preserved the public entrypoints, durable
status model, retry policy, prompts, checkpoint schema, and lease ordering.
Current ownership is:

- `AutomatedCardEvolutionService`: compatibility facade, public recovery/run
  entrypoints, enablement, and per-session in-flight deduplication.
- `ObservationResponseParser`: pure collector response parsing and typed
  actions.
- `CardEvolutionDiagnostics`: parser verdicts, model outcomes, and selection
  bail persistence.
- `DurableWriterCallRunner`: checkpointed prepare/replay/execute/complete
  protocol while preserving claim ownership and status ordering.
- `WriterContextConsolidator`: bounded immutable-history chunking and cumulative
  handoff.
- `CardEvolutionCollectorCoordinator`: collector claims, evidence validation,
  observation effects, promotion, recovery, and collector cancellation.
- `CardEvolutionWriterCoordinator`: durable writer claims, cancellation,
  card/repair/lorebook writer execution, and finalization ordering.

## 2. Chat Message Mutations

**ROI: high.**

`lib/features/chat/chat_message_service.dart` mixes pure message/swipe
transforms with destructive multi-repository transactions, causal rollback,
manifest cleanup, cache updates, and Riverpod invalidation.

Start by moving direct Drift manifest cleanup into
`LorebookUseManifestRepo`. Then extract a pure `ChatSwipeStateMachine` and
`MessageDeletionPlanner` behind the existing static/public entry points. Move
transaction orchestration only after those boundaries have characterization
coverage.

## 3. Cloud Sync Engine

**ROI: high, but split incrementally.**

`lib/features/cloud_sync/services/sync_engine.dart` combines push/pull planning,
conflict policy, manifests, queueing, entity dispatch, storage, and about two
dozen stores. The first useful boundary is a shared pure `SyncPullPlanner` for
normal and pending pulls. A later `SyncEntityRegistry` should own read, apply,
delete, and semantic comparison for each entity type so new entities do not
require synchronized edits to several switches.

The reconciliation-state acknowledgment rule is domain policy and must remain
explicit in the planner or handler rather than becoming a generic hash shortcut.

## 4. Cleaner Stage

**ROI: high after additional characterization tests.**

`lib/features/chat/services/stages/cleaner_stage.dart` combines run ownership,
input resolution, LLM/audit execution, swipe persistence and fallback, UI
refresh, ExtBlocks, and Ledger ordering. Add direct tests for cleaned,
no-change, partial, skipped, aborted, and hard-error outcomes before extracting
`CleanerSwipeSession`, `CleanerExecutionRunner`, and post-processing.

The `cleaner -> ExtBlocks -> Ledger` ordering is a behavioral contract.

## 5. Reconciliation Sync Store

**ROI: medium-high.**

`ReconciliationStateSyncStore` in
`lib/features/cloud_sync/adapters/ext_blocks_sync_stores.dart` is a merge engine,
not a simple adapter. First split the unrelated stores physically. Then extract
pure run normalization and chain-selection policy, followed by a snapshot reader
and one top-level transactional merger. The transaction must remain atomic.

## 6. Generation And Recovery Services

**ROI: medium, gated by tests.**

- `stream_generation_service.dart`: characterize ordinary and Studio success,
  timeout, error, and abort paths before separating prompt preparation and the
  two runners.
- `image_recovery_service.dart`: extract pure markup handling, then consolidate
  the duplicated retry lifecycle and filesystem lookup.
- `flutter_backup_importer.dart`: unify raw row restoration before separating
  preferences, media, and derived-state rebuilds.
- `janitor_webview_proxy.dart`: add fake browser/account lifecycle tests before
  separating browser session, account client, extraction lease, and capture
  runner. Keep the embedded document-start script atomic.

## Measure Or Decide First

- Wire `CleanerSettings.postCleanerAuditModel` through a distinct runtime model
  resolution path, or explicitly remove the setting. The UI and persisted model
  exist, but `CleanerStage` currently uses the cleaner config for both calls.
- Decide whether the remaining MemoryBook hardening work is still required:
  read-only Lucy output auditing and stronger write-time semantic duplicate
  prevention are not implemented. Visible-window exclusion and temporal
  diversity already are.
- Benchmark incremental chat-embedding manifests before adding persistent
  watermark metadata.
- Profile chat and WebView rebuild/platform-view creation counts before changing
  widget subscriptions or hierarchy.
- Decide whether disabled Memory Graph building also forbids graph reads during
  generation.
- Measure periodic extension behavior on mobile lifecycle transitions and
  long-running visual Chat WebView sessions before expanding its scope.
- Treat relational chat storage and SQLite runtime replacement as independent
  migration projects.

## Intentional Non-targets

Large declarative UI files are not decomposition targets without measured UI or
business-logic payoff. The same applies to cohesive protocol implementations
such as `image_tag_markup.dart`, `macro_engine.dart`, Studio preset seed data,
and the embedded Janitor capture script.

## Verification Gates

Every extraction stage must:

- preserve public import paths and source compatibility;
- preserve transaction, lease, checkpoint, and cancellation ordering;
- run focused characterization tests for the changed ownership boundary;
- run `dart run build_runner build --delete-conflicting-outputs` after generated
  model or Drift structural changes;
- run `dart run easy_localization:generate -S assets/translations -f keys -o locale_keys.g.dart`
  when localization keys or their generated contract can be affected;
- pass the CI analyzer command:
  `flutter analyze --no-fatal-infos --no-fatal-warnings`;
- pass focused tests first, then the full CI suite with
  `flutter test --reporter expanded`;
- leave the PR CI gate in `.github/workflows/ci.yml` green; it regenerates
  build-runner output and localization keys before analyzer and full tests;
- land as a small scoped commit that can be reviewed or reverted independently.
