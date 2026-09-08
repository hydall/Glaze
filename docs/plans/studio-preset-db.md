# Studio UI Overhaul + Memory Dedup — Master Plan

> **Historical note (2026-07):** This plan documents the original Studio
> write-loop design. The generic tracker write-loop, its prompt section, and
> agentic MemoryBook writer have since been retired. Studio Ledger is the only
> automatic canonical tracker writer. References below are retained as history,
> not current architecture.

> Extracted from opencode session DB (`ses_0e4610f29ffeS9YaIGKnmkeArR`), updated through commit `4b4ad0e5`.

## Goal
- Studio UI overhaul (unify pipeline into one window, 3 model slots, all hardcoded prompts → DB) + agent memory deduplication (cosine + LLM batch)
- LLM agent memory cadence: write short-term memory every 5 turns (5 U-A chunks), analyzing all 5 chunks concisely — not a detailed MemoryBook, but the same short-term memory as now, just less frequently

## Constraints & Preferences
- AGPL-3.0 license preserved; hydall credited as original Glaze author
- PRs target `hydall/GlazeFlutter:master` (upstream) via fork `danvitv/GlazeFlutter`
- `origin` = `https://github.com/danvitv/GlazeFlutter.git`; `upstream` = `https://github.com/hydall/GlazeFlutter.git`
- Studio preset blocks: 8 fields (id, name, kind, role, content, enabled, order, section)
- Slot blocks use macro templates (`{{description}}`, `{{persona}}`, `{{memory}}`) — editable by user
- Tracker batching: keep single-batch approach (all trackers in one LLM call via TrackerBatcher XML protocol)
- All ~15 hardcoded prompts migrate to DB (runtime + build-time)
- Studio unbound from user presets: decomposition service, block router, shard synthesizer, beauty extractor, cleaner rules extractor all DELETED
- `studio_block_classifier.dart` RESTORED — still needed by `studio_context_bucketizer` for `isReasoningBlock`
- Ledger + the then-active write-loop used the cheap model (same as trackers; retired)
- Agentic ops log kept as-is
- StudioPreset added to cloud sync engine
- Memory dedup: cosine > 0.85 → group candidates → one batch LLM call decides merge/drop/keep
- Memory dedup UI: button in memory book UI + auto-cadence toggle
- ALL PRs (#3-#6) collapsed into ONE PR on branch `feat/studio-preset-db`

## Progress
### Done
- **PR #209 MERGED** to `hydall/GlazeFlutter:master` — Studio memory hidden-window fix
- All remotes synced: local master = origin/master = upstream/master = `74e64d2f`
- **Foundation commit** (`0dce8d6a`): Drift v54 migration + StudioPresetRows table + seed data
  - `StudioPresetRows` table added to `tables.dart` (presetId, name, blocksJson, updatedAt)
  - Registered in `@DriftDatabase` in `app_db.dart`; `schemaVersion` bumped 53→54
  - v54 migration: CREATE table + INSERT default preset with ~50 seed blocks across 7 sections
  - `_studioPresetSeedBlocks()` function in `app_db.dart` — all hardcoded prompts migrated to seed JSON
  - `_studioPresetSlotBlocks(section, startOrder)` generates slot blocks (_card, scenario, etc.) for pregen + final sections
  - `StudioPreset` + `StudioPresetBlock` freezed models in `studio_config.dart` — `StudioPresetBlock` gained `section` field
  - `StudioPresetRepo` in `lib/core/db/repositories/studio_preset_repo.dart` (getById/getDefault/getAll/upsert/deleteById)
  - `studioPresetRepoProvider` + `studioPresetProvider` in `db_provider.dart`
  - `StudioPromptResolver` in `lib/core/llm/studio_prompt_resolver.dart` — DB-first lookup with hardcoded fallback to `studioRequestPresets`
  - `studioPromptResolverProvider` provider
  - `build_runner` succeeded; `flutter analyze` clean on foundation files
- **Unbind commit** (`4b4ad0e5`): Studio unbound from user presets — decomposition pipeline deleted
  - DELETED 5 files: `studio_decomposition_service.dart`, `studio_block_router.dart`, `studio_shard_synthesizer.dart`, `studio_beauty_extractor.dart`, `studio_cleaner_rules_extractor.dart`
  - DELETED 4 test files: `studio_beauty_extractor_test.dart`, `studio_block_router_test.dart`, `studio_cleaner_rules_extractor_test.dart`, `studio_verbatim_routing_test.dart`
  - `studio_block_classifier.dart` RESTORED (needed by `studio_context_bucketizer.dart`)
  - `studio_build_provider.dart` REWRITTEN — agents from `StudioControllerOntology.specs` directly (no LLM decomposition, no preset dependency)
  - `studio_menu_dialog.dart` — removed `regenerateAgentInstruction` UI (IconButton + `onRegenerate`/`regenerating` params stripped from `_TrackerRow`, `_TrackersSection`, `_FinalizerSection`)
  - `studio_menu_controller.dart` — removed `regeneratingAgentIds` state
  - `memory_agent_providers.dart` — removed `studioDecompositionServiceProvider` + `studioCleanerRulesExtractorProvider` + dead imports
  - Fixed v54 migration bug: `_studioPresetSeedBlocks` tear-off stored instead of called (`jsonEncode` failed on Closure)
  - Fixed pre-existing test regressions: db_migration_test schema version 53→54; agent_operations_log_test label 'Studio agent'→'Studio tracker'
  - `flutter analyze`: clean. `flutter test`: 1451 passed, 0 failed.
- **v55 migration commit** (`3907877d`): Drift v55 migration — 3 API Config slots replace per-agent model overrides
  - `studio_config_rows` schema: ADD `studioPresetId`, `expensiveApiConfigId`, `cheapApiConfigId`, `cleanerApiConfigId`; DROP 11 old columns
  - `StudioConfig` model: new 3 slot fields, removed old fields
  - `StudioAgent` model: removed `promptShard`, `modelSource`, `model`, `modelOverride`
  - `StudioPresetOverride` class DELETED
  - `studio_message_builder.dart`: accepts `StudioPreset` param
  - `studio_agent_executor + batch_coordinator`: pass `StudioPreset` through
  - `memory_studio_service`: resolves `StudioPreset` from DB
  - `studio_api_config_resolver`: simplified
  - `studio_brief_cache`: cache key v2
  - v42 migration fix: `source_preset_id` → `profile_id` (deleted column reference)
  - Tests: db_migration_test v54→v55, stage5_agentic_toggle, tracker_batcher_test
  - `flutter analyze`: clean. `flutter test`: 1450 passed.
- **3-config model resolution commit** (`d7a2f5ad`): trackers→cheap, final→expensive, cleaner→cleaner
  - `AgentRunner.resolveAgentConfig` accepts optional `apiConfigId` parameter
  - `TrackerBatcher.groupAgents` accepts `apiConfigId`, forwards to `resolveAgentConfig`
  - `StudioAgentExecutor`: all 4 methods accept and forward `apiConfigId`
  - `StudioBatchCoordinator.runBatchGroup + retryFailedIndividually`: same
  - `memory_studio_service`: passes appropriate slot config id to each call site
  - Test: `_FakeAgentRunner.resolveAgentConfig` updated
  - `flutter analyze`: clean. `flutter test`: 1450 passed.
- **New UI screens commit** (`7beb6dc8`): studio_settings + preset editor + block editor
  - `studio_settings_screen.dart`: enable toggle, 3 API Config dropdowns, build button, tracker list
  - `studio_preset_editor_screen.dart`: section-tabbed block editor with add/edit/delete/toggle
  - `studio_block_editor_dialog.dart`: single block editor (title, role, content, kind, section, order, enabled)
  - Routes: `/studio/:charId/:sessionId` + `/studio/preset/:presetId`
  - `studioPresetSeedBlocks()` made public
  - `flutter analyze`: clean. `flutter test`: 1450 passed.
- **Navigation wiring commit** (`3edeedcb`): replace StudioMenuDialog with screen
  - `magic_drawer.dart`: `_showStudioMenu` navigates to `/studio/:charId/:sessionId`
  - Removed unused `studio_menu_dialog` import from magic_drawer
  - `studio_seed_blocks.dart`: public re-export wrapper for seed blocks function
  - `flutter analyze`: clean. `flutter test`: 1450 passed.

## Key Decisions
- Studio preset structure: flat merged list per section (layout slots + instructions combined), NOT separate request_preset + content blocks
- 3 API Config dropdowns (expensive/cheap/cleaner) replace per-agent model overrides
- `StudioPresetRows` Drift table with `blocksJson` blob, seeded via Drift v54 migration INSERT
- Slot blocks have macro template content (e.g. `{{description}}`) — user edits template, runtime resolves
- `broadcastBlocks` concept dropped after user-preset unbind — user writes rules directly in cleaner_system block
- `cleaner_rules` block holds `{{bannedWords}}`/`{{avoidInstructions}}`/`{{styleInstructions}}` template
- PipelineSettings `postCleanerBannedWords`/`AvoidInstructions`/`StyleInstructions` stay in PipelineSettings (values for cleaner_rules block)
- Memory dedup: cosine pre-filter + LLM batch (not cosine-only, not LLM-only)
- LLM agent memory cadence: every 5 U-A turns (not every turn) — analyze 5 chunks concisely, write short-term memory
- All PRs #3-#6 collapsed into ONE PR on `feat/studio-preset-db` branch
- `studio_build_provider.dart` rewritten to use `StudioControllerOntology.specs` directly — agents created from fixed controller list, prompt shards = spec fallback prompts

## Next Steps
1. ~~Drift v55 migration~~ ✅ DONE
2. ~~StudioAgent → remove promptShard/modelSource/model/modelOverride~~ ✅ DONE
3. ~~tracker_batcher.dart → group by API Config id~~ ✅ DONE
4. ~~stream_generation_service.dart → 3-config model resolution~~ ✅ DONE
5. ~~New UI: studio_settings_screen + studio_preset_editor_screen + studio_block_editor_dialog~~ ✅ DONE
6. ~~Replace old dialogs with new screen + wire up navigation~~ ✅ DONE
7. Remove fallback constants from all prompt classes (DB-only via resolver)
8. Unit + widget tests
9. `flutter analyze` + `flutter test` clean
10. Cloud sync: StudioPreset in sync engine
11. Push + PR to `hydall/GlazeFlutter`
12. Then **PR #7** `feat/memory-dedup`: MemoryDedupService, cosine pre-filter + LLM batch, UI, tests
13. **Memory cadence change**: LLM agent memory writes every 5 U-A turns (analyzing 5 chunks concisely) instead of every turn — short-term memory, not detailed MemoryBook, just less frequent

## Critical Context
- Branch: `feat/studio-preset-db` (created from master `74e64d2f`)
- Drift schema: v55
- Current commit: `3edeedcb` on `feat/studio-preset-db` (navigation wiring)
- Commits on branch: `0dce8d6a` → `4b4ad0e5` → `3907877d` → `d7a2f5ad` → `7beb6dc8` → `3edeedcb`
- `studio_request_preset.dart` has `defaultAgentStudioPresetId` / `defaultFinalStudioPresetId` constants — referenced by resolver fallback
- `studio_controller_ontology.dart` STILL EXISTS — 9 controller specs with `fallbackPrompt` per tracker; now used by rewritten `studio_build_provider.dart` to create agents directly
- `studio_block_expander.dart` — still exists, was referenced by decomposition (deleted); check if anything else uses it
- `reasoning_stripper.dart` — still exists, was used by shard synthesizer (deleted); check if anything else uses it
- `studio_build_llm_client.dart` — still exists, was used by decomposition + cleaner rules extractor (both deleted); check if anything else uses it
- `beauty_shard_instruction.dart` — still exists, has `beautyShardTrackerFallbackPrompt` const; now seeded in DB
- Flutter SDK at `Z:\GlazeProject\flutter\bin\flutter.bat`
- `build_runner` command: `& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build --delete-conflicting-outputs`

## Relevant Files
- `lib/core/db/tables.dart`: `StudioPresetRows` table added (line ~390)
- `lib/core/db/app_db.dart`: v54 migration + `_studioPresetSeedBlocks()` + `_studioPresetSlotBlocks()` — all seed data
- `lib/core/models/studio_config.dart`: `StudioPreset` + `StudioPresetBlock` (with `section` field) freezed models
- `lib/core/db/repositories/studio_preset_repo.dart`: NEW — StudioPresetRepo
- `lib/core/llm/studio_prompt_resolver.dart`: NEW — DB-first lookup with fallback
- `lib/core/state/db_provider.dart`: `studioPresetRepoProvider` + `studioPresetProvider` added
- `lib/core/state/studio_build_provider.dart`: REWRITTEN — no decomposition, agents from ontology
- `lib/core/state/memory_agent_providers.dart`: cleaned — removed decomposition/cleaner rules providers
- `lib/features/chat/controllers/studio_menu_controller.dart`: cleaned — removed `regenerateAgentInstruction`, `effectivePreset`, `regeneratingAgentIds`
- `lib/features/chat/widgets/studio_menu_dialog.dart`: cleaned — removed regenerate UI
- `lib/core/models/agent_operation_record.dart`: fixed studioTracker label → 'Studio tracker'
- DELETED: `studio_decomposition_service.dart`, `studio_block_router.dart`, `studio_shard_synthesizer.dart`, `studio_beauty_extractor.dart`, `studio_cleaner_rules_extractor.dart`
- DELETED tests: `studio_beauty_extractor_test.dart`, `studio_block_router_test.dart`, `studio_cleaner_rules_extractor_test.dart`, `studio_verbatim_routing_test.dart`
- `lib/core/llm/studio_block_classifier.dart`: RESTORED (needed by bucketizer)
- `lib/core/llm/studio_controller_ontology.dart`: still exists — 9 specs, used by build provider
- `lib/core/llm/studio_request_preset.dart`: still exists — fallback for resolver
- `lib/core/llm/studio_prompt_text.dart`: still exists — `intermediateRuntimeEnvelope`, `finalBriefUsageNote`, `finalHardStyleContract`
- `lib/core/llm/tracker_batcher.dart`: needs update — group by API Config id
- `lib/features/chat/services/stream_generation_service.dart`: needs 3-config model resolution
- `lib/core/llm/studio_message_builder.dart`: builds per-agent/final/batch message lists
- `lib/core/llm/post_cleaner_service.dart`: cleaner system prompt + audit (seeded in DB now)
- `lib/core/llm/studio_ledger_prompt.dart`: ledger system prompt (seeded in DB now)
- **DELETED:** `lib/core/llm/agentic_write_request_parser.dart`: former
  write-loop prompt source; removed when the generic writer was retired
- `lib/core/llm/studio_ledger_service.dart`: still exists — ledger service
- `lib/core/llm/memory_studio_service.dart`: still exists — Studio pipeline orchestration
- `lib/core/llm/macro_engine.dart`: `MacroContext` + `replaceMacros` — 30+ macros, reuse for studio preset resolution
