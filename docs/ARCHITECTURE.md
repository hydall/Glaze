# Architecture — Glaze

Related docs:
- Generation invariants (formal, with code refs): `docs/INVARIANTS.md`
- Generation lifecycle rules: `docs/rules/generation.md`
- Race condition rules: `docs/rules/race-conditions.md`
- Database rules: `docs/rules/database.md`

---

## 0. Architecture Overview

### Target Layer Order (dependency direction down)

```
UI (screens/widgets)
  → Providers (Riverpod AsyncNotifier / StateNotifier)
    → Services / Components (orchestrators and specialists)
      → Models (Freezed data classes)
      → Repos (Drift DB abstraction)
```

Pure/core service implementations must not import feature modules. Dependencies
that cross feature boundaries are passed as constructor values or callbacks and
wired in Riverpod composition modules. Shared core-only composition belongs in
`core/state`; composition that reads feature-owned providers belongs under the
owning feature's `providers/` directory.

Some older `core/state -> features` imports remain as composition exceptions;
do not extend that pattern. Architecture tests pin critical boundaries such as
feature-free LLM implementations, provider-free Studio DTOs, and neutral sync
ports. No circular imports.

### Key Rules

- **One class = one job.** If the class name needs "and", it is two classes.
- **Thin orchestrators, fat specialists.** Top-level service only calls specialists in order — zero business logic itself.
- **Constructor injection only.** Deps passed in, not looked up (except Riverpod `ref` at provider build time).
- **No raw DB writes outside repos.** All Drift access goes through a repo class.
- **Every sub-screen has a back button.** Use `leading: BackButton(onPressed: () => context.go('/parent'))` in AppBar because GoRouter `go()` replaces the stack.

---

## 0.1 Directory Tree

```
lib/
├── core/
│   ├── constants/
│   │   └── image_gen_patterns.dart     # IMG-tag regex constants
│   ├── db/
│   │   ├── app_db.dart                 # AppDatabase composition root (56 tables, schema v130)
│   │   ├── migrations/                 # Integrity, Studio legacy, and version-range upgrades
│   │   ├── studio_preset_seed.dart     # Historical/default Studio preset seed data
│   │   ├── tables.dart                 # Barrel for seven domain table parts
│   │   ├── tables/                     # Character/chat, memory, ledger, canon/rewrite,
│   │   │                               # Studio/presets, lorebooks, and extensions
│   │   └── repositories/              # Persistence APIs and transactional aggregates
│   │       ├── api_config_repo.dart
│   │       ├── character_repo.dart
│   │       ├── character_folder_repo.dart
│   │       ├── chat_repo.dart
│   │       ├── embedding_repo.dart
│   │       ├── extension_presets_repository.dart
│   │       ├── global_variables_repo.dart
│   │       ├── info_blocks_repository.dart
│   │       ├── lorebook_repo.dart
│   │       ├── memory_book_repo.dart
│   │       ├── memory_catalog_repo.dart
│   │       ├── persona_repo.dart
│   │       ├── preset_repo.dart
│   │       └── summary_repo.dart
│   ├── glossary/
│   │   ├── glossary_models.dart
│   │   └── glossary_provider.dart
│   ├── models/                       # Freezed data classes (pure data, no logic)
│   │   ├── api_config.dart
│   │   ├── character.dart
│   │   ├── chat_message.dart
│   │   ├── gallery_entry.dart
│   │   ├── lorebook.dart
│   │   ├── memory_book.dart
│   │   ├── persona.dart
│   │   └── preset.dart
│   ├── llm/                          # LLM pipeline specialists
│   │   ├── prompt_builder.dart        # Orchestrator: block ordering, lorebook merge, trimming (re-exports prompt/)
│   │   ├── prompt_block_resolver.dart # Maps preset block ID → resolved text
│   │   ├── prompt_regex_applicator.dart # Pure: applies preset+global regex scripts to final messages
│   │   ├── prompt_inputs.dart         # Freezed value object: inputs for isolate build
│   │   ├── prompt_inputs_collector.dart # Core collector with injected feature adapters
│   │   ├── prompt_payload_assembler.dart # Pure: PromptInputs → PromptPayload (no Riverpod)
│   │   ├── prompt_payload_builder.dart # Assembles PromptPayload (vector/memory async)
│   │   ├── prompt_isolate.dart        # Spawns isolate; delegates to prompt_worker
│   │   ├── prompt_worker.dart         # Top-level entry: buildPrompt() inside isolate
│   │   ├── prompt_worker_codec.dart   # Isolate boundary JSON codec (serialize/deserialize payload+result)
│   │   ├── history_assembler.dart     # ChatMessage[] → PromptMessage[], macro application
│   │   ├── context_calculator.dart    # Token budget: trims history from oldest end
│   │   ├── fallback_prompt_builder.dart # Minimal prompt when no preset configured
│   │   ├── lorebook_scanner.dart      # Keyword scan: sticky/cooldown/probability/recursion
│   │   ├── lorebook_merger.dart       # Merges keyword + vector results, deduplicates
│   │   ├── lorebook_coverage.dart     # Diagnostic: full coverage report per entry/key
│   │   ├── lorebook_vector_search.dart # Cosine search + hybrid boost
│   │   ├── lorebook_embedding_service.dart # Indexes lorebook entries into embedding store
│   │   ├── retrieval_hints.dart       # Retrieval hint extraction from lorebook entries
│   │   ├── embedding_service.dart     # Calls embedding API, handles chunking + rate limits
│   │   ├── embedding_types.dart       # Shared embedding type definitions
│   │   ├── embedding_error_labels.dart # Error classification for embedding status
│   │   ├── memory_embedding_service.dart   # Indexes memory entries into embedding store
│   │   ├── memory_injection_service.dart   # Scores + selects memory entries for injection
│   │   ├── memory_budget.dart         # INV-PS4 token cap for memory injection
│   │   ├── glaze_matcher.dart         # Pure regex keyword matching (3 whole-word modes, ST `/pattern/flags` keys)
│   │   ├── regex_service.dart         # Applies PresetRegex scripts to a string
│   │   ├── preset_macro_attribution.dart # Preset macro source attribution (debug)
│   │   ├── sse_client.dart           # SSE + non-streaming completions via Dio
│   │   ├── stream_accumulator.dart   # Parses inline <think…> tags from stream
│   │   ├── response_normalizer.dart  # Extracts content from non-streaming response body
│   │   ├── summary_service.dart      # Reads/writes summaries, triggers LLM regeneration
│   │   ├── tokenizer.dart            # estimateTokens() with LRU cache, base64 stripping
│   │   ├── macro_engine.dart         # SillyTavern-compatible macro replacement engine
│   │   ├── memory_formatting.dart    # Shared formatMemoryItems / formatMemoryRange helpers
│   │   ├── vector_math.dart          # cosineSimilarity, findTopK, findTopKMulti, BLOB helpers
│   │   ├── aux_llm_client.dart       # Shared helper for non-streaming LLM calls (no Ref, const ctor)
│   │   ├── model_fetcher.dart        # Shared ModelFetcher.fetchModelIds() (dedup fetchModels parsing)
│   │   ├── prompt/                   # Prompt builder specialists (extracted Phases 1-3)
│   │   │   ├── runtime_prompt_block.dart    # RuntimePromptBlock data class
│   │   │   ├── recalled_message_chunk.dart  # RecalledMessageChunk data class
│   │   │   ├── prompt_payload.dart          # PromptPayload data class
│   │   │   ├── prompt_result.dart           # PromptResult data class
│   │   │   ├── resolved_block.dart          # ResolvedDepthBlock / ResolvedRelativeBlock
│   │   │   ├── lorebook_classifier.dart     # Lorebook injection specialist
│   │   │   ├── memory_block_injector.dart    # DeferredMemoryResult + memory block injection
│   │   │   ├── arc_state_builder.dart       # Arc state computation
│   │   │   ├── ledger_tracker_loader.dart   # Effective ledger tracker loading
│   │   │   ├── lorebook_vector_searcher.dart # Vector search within prompt building
│   │   │   └── studio_session_state_compiler.dart # Studio session state → prompt block
│   │   ├── cleaner/                  # POST-cleaner specialists (extracted Phase 4)
│   │   │   ├── cleaner_prompt_builder.dart  # Cleaner system prompt builder
│   │   │   ├── audit_prompt_builder.dart    # Audit prompt builder + JSON parser
│   │   │   └── cleaner_text_guard.dart      # Text rewrite protection guards
│   │   ├── studio/                   # Studio pipeline specialists (extracted Phases 5, 7-9)
│   │   │   ├── controller_phase_runner.dart # Pre-gen controller phase owner
│   │   │   ├── controller_result_mapper.dart # Controller result → brief mapper
│   │   │   ├── studio_history_limiter.dart  # History truncation for agents
│   │   │   ├── studio_brief_macro_renderer.dart # Studio brief macro rendering
│   │   │   ├── studio_runtime_block_expander.dart # Runtime block content expansion
│   │   │   ├── studio_stream_interceptor.dart # Studio stream intercept (pure static)
│   │   │   └── agent_config_resolver.dart   # Per-agent API config resolution
│   │   ├── memory/                   # Memory injection specialists (extracted Phase 6)
│   │   │   ├── memory_vector_searcher.dart  # Vector search for memory injection
│   │   │   ├── memory_catalog_matcher.dart  # Catalog/keyword matching
│   │   │   ├── memory_chunker.dart          # Text chunking + sentence splitting
│   │   │   └── excerpt_scorer.dart          # Excerpt scoring helpers
│   │   ├── ledger/                   # Studio Ledger execution and commit specialists
│   │   │   ├── ledger_canon_authority.dart  # Canon/currentness authority
│   │   │   ├── ledger_in_flight_registry.dart # Shared in-flight operation registry
│   │   │   ├── ledger_output_recovery.dart  # Parse/recovery policy
│   │   │   ├── ledger_prompt_factory.dart   # Turn prompt construction
│   │   │   ├── ledger_run_diagnostics.dart  # Attempt and outcome diagnostics
│   │   │   ├── ledger_turn_runner.dart / ledger_turn_committer.dart
│   │   │   ├── ledger_reconciliation_runner.dart / ledger_reconciliation_committer.dart
│   │   │   ├── ledger_replacement_basis_resolver.dart
│   │   │   └── ledger_op_applier.dart / ledger_provenance.dart / ledger_run_result.dart
│   │   └── shared/                   # Shared utilities across services
│   │       └── message_range_formatter.dart # Unified message range formatting
│   ├── llm/converters/               # Protocol-specific message converters (pure)
│   │   ├── claude_messages.dart      # Anthropic /v1/messages shape
│   │   ├── gemini_messages.dart      # Google Gemini shape
│   │   ├── openrouter_messages.dart  # OpenRouter (Anthropic/OpenAI passthrough)
│   │   ├── message_merger.dart       # Consecutive same-role message merging
│   │   ├── prompt_post_processing.dart # SillyTavern prompt post-processing modes (merge/semi/strict/single)
│   │   ├── attachment_encoder.dart   # Image/file → provider attachment payload
│   │   ├── cache_breakpoint_marker.dart # Anthropic/OpenRouter cache_control placement
│   │   ├── thinking_budget.dart      # Extended-thinking budget mapping per protocol
│   │   └── reasoning_effort.dart     # Effort step → per-protocol wire value
│   ├── llm/transport/                # LLM HTTP/SSE transports (one per protocol)
│   │   ├── chat_transport.dart       # Abstract ChatTransport interface
│   │   ├── chat_transport_request.dart # Shared request value object
│   │   ├── llm_protocol.dart         # Protocol enum (openai/openai_responses/anthropic/gemini/openrouter)
│   │   ├── transport_factory.dart    # ApiConfig.protocol → ChatTransport (wraps in PostProcessingChatTransport + LoggingChatTransport)
│   │   ├── llm_request_dump.dart     # Diagnostics: dump every outgoing LLM request to JSONL (off by default)
│   │   ├── post_processing_chat_transport.dart # Applies ApiConfig.promptPostProcessing before the protocol converter
│   │   ├── openai_chat_transport.dart
│   │   ├── openai_responses_transport.dart # OpenAI Responses API (`/responses`)
│   │   ├── anthropic_chat_transport.dart
│   │   ├── gemini_chat_transport.dart
│   │   └── openrouter_chat_transport.dart
│   ├── navigation/
│   │   └── router.dart               # GoRouter routes + shell (used by app.dart)
│   ├── platform/                     # Platform-specific integrations
│   │   ├── haptics.dart              # Haptic feedback helpers
│   │   ├── system_settings.dart      # OS settings (wallpaper, dark mode)
│   │   └── wallpaper.dart            # Device wallpaper fetch
│   ├── services/                     # Business logic services (no UI, no Riverpod ref)
│   │   ├── character_importer.dart   # Parses PNG/JSON/YAML V1/V2 character cards
│   │   ├── character_exporter.dart   # Exports character to PNG (tEXt chunk) or JSON
│   │   ├── character_book_converter.dart # character_book JSON ↔ Lorebook model
│   │   ├── image_storage_service.dart    # Avatars + thumbnails on disk
│   │   ├── gallery_service.dart          # Per-character image gallery CRUD
│   │   ├── api_connection_tester.dart    # API endpoint connectivity check
│   │   ├── backup_service.dart           # Top-level backup orchestrator (thin)
│   │   ├── backup/
│   │   │   ├── backup_exporter.dart      # Serializes to Glaze-native ZIP
│   │   │   ├── backup_helpers.dart       # ZIP read/write, JSON helpers
│   │   │   ├── backup_cancel.dart        # Cooperative cancel for long imports
│   │   │   ├── archive_stream.dart       # Streaming ZIP entry reader
│   │   │   ├── flutter_backup_importer.dart  # Imports Glaze-native backup
│   │   │   ├── js_backup_importer.dart       # Legacy ST ZIP import (orchestrator)
│   │   │   ├── st_backup_importer.dart       # SillyTavern ZIP import (orchestrator)
│   │   │   ├── tavo_backup_importer.dart     # Tavo/LMDB backup import (disabled — BackupService.tavoImportEnabled)
│   │   │   ├── tavo_lmdb_reader.dart         # LMDB reader for Tavo archives (disabled with the importer)
│   │   │   ├── js_character_importer.dart    # Imports ST character PNG/JSON files
│   │   │   ├── js_chat_importer.dart         # Imports ST JSONL chat files
│   │   │   ├── js_api_config_importer.dart   # Parses ST settings → ApiConfig
│   │   │   ├── js_preset_importer.dart       # Imports ST preset JSON files
│   │   │   ├── js_preset_mapper.dart         # Maps ST preset fields → Glaze Preset
│   │   │   ├── js_lorebook_importer.dart     # Imports ST lorebook JSON files
│   │   │   ├── js_lorebook_mapper.dart       # Maps ST lorebook fields → Glaze Lorebook
│   │   │   ├── js_memory_importer.dart       # Imports ST memory book data
│   │   │   ├── js_message_normalizer.dart    # Normalizes ST message format
│   │   │   ├── profile_resolver.dart         # Resolves ST service profiles → API configs
│   │   │   ├── authors_note_helper.dart      # Authors note extraction from ST data
│   │   │   ├── data_url_helpers.dart         # Data URL parsing/encoding
│   │   │   ├── type_converters.dart          # ST→Glaze type conversions
│   │   │   └── service_prefs_writer.dart     # Writes imported prefs to SharedPreferences
│   │   ├── migration_service.dart    # Migrates legacy Glaze-JS data to Drift DB
│   │   ├── card_rewriter/             # Manual rewrite + Automated Card Evolution
│   │   │   ├── automated_card_evolution_service.dart # Compatibility facade
│   │   │   ├── card_evolution_collector_coordinator.dart
│   │   │   ├── card_evolution_writer_coordinator.dart
│   │   │   ├── observation_response_parser.dart
│   │   │   ├── card_evolution_diagnostics.dart
│   │   │   ├── durable_writer_call_runner.dart
│   │   │   └── writer_context_consolidator.dart
│   │   ├── preset_defaults.dart      # Ensures mandatory blocks exist in imported presets
│   │   ├── preset_seeder.dart        # Seeds built-in "Glaze Default" preset on first launch
│   │   ├── png_text_extractor.dart   # Reads tEXt chunks from PNG byte stream
│   │   ├── chat_import_export.dart   # Import/export individual chat sessions as JSONL
│   │   ├── file_export_service.dart  # Platform-aware file export (file_selector / share)
│   │   ├── deep_link_service.dart    # Listens for OAuth deep-link URIs
│   │   ├── generation_notification_service.dart # Android foreground/background notifications
│   │   ├── memory_prompt_presets.dart           # Built-in memory prompt templates
│   │   └── onboarding_service.dart   # Completion check + showOnboarding (UI in features/onboarding/)
│   ├── import/
│   │   ├── silly_tavern_preset_parser.dart  # ST preset JSON → Glaze Preset (pure)
│   │   └── st_lorebook_importer.dart        # ST lorebook JSON → Glaze Lorebook (pure)
│   ├── utils/
│   │   ├── cast_helpers.dart         # computeHash, dataUrlToBytes, toStringList
│   │   ├── id_generator.dart         # generateId(): base-36 milliseconds
│   │   ├── platform_paths.dart       # getAppDataDir() per platform
│   │   ├── sync_deletion_tracker.dart # Appends deletion tombstones for cloud sync
│   │   ├── time_helpers.dart         # currentTimestampSeconds()
│   │   ├── think_tags.dart           # Reasoning tag parsing helpers
│   │   └── html_to_markdown.dart     # HTML → Markdown converter (ST card fields)
│   ├── events/
│   │   └── event_hub.dart            # Lightweight pub/sub bus (broadcast StreamControllers)
│   └── state/                        # Global Riverpod providers
│       ├── db_provider.dart          # AppDatabase + all repo providers
│       ├── shared_prefs_provider.dart # SharedPreferences FutureProvider
│       ├── active_selection_provider.dart # Active preset/persona/globalVars/regexes
│       ├── active_regex_provider.dart     # Active regex scripts for prompt build
│       ├── character_provider.dart   # CharactersNotifier (watchAll reactive stream)
│       ├── lorebook_embedding_provider.dart # Vector search/embedding composition
│       ├── lorebook_provider.dart    # LorebooksNotifier + settings/activations
│       ├── global_regex_provider.dart # GlobalRegexNotifier
│       ├── memory_settings_provider.dart # MemoryGlobalSettings + notifier
│       ├── memory_book_ops_provider.dart # Memory book CRUD helpers
│       ├── chat_session_ops_provider.dart # Cross-session ops (branch, delete, etc.)
│       ├── persona_resolution.dart   # Resolves active persona for a character
│       ├── preset_resolution.dart    # Resolves active preset for a character
│       └── dev_mode_provider.dart    # Developer mode flag
├── features/
│   ├── chat/
│   │   ├── chat_provider.dart        # ChatNotifier: state owner; delegates to controllers + pipeline
│   │   ├── chat_state.dart           # ChatState + StreamingState value objects
│   │   ├── editing_message_provider.dart # Tracks which message is being edited
│   │   ├── chat_screen.dart          # UI: WebView + ChatInputBar + header
│   │   ├── chat_drawer_controller.dart # Magic drawer open/close + layout state
│   │   ├── chat_generation_service.dart  # Thin facade: generate / processImageTags / processExtensions
│   │   ├── chat_session_service.dart     # Creates/finds sessions, alternate greetings
│   │   ├── chat_message_service.dart     # Message-level mutations (edit/delete/hide/reorder)
│   │   ├── chat_actions_service.dart     # Branch/clear/rename/delete session
│   │   ├── initial_message_builder.dart  # Selects greeting, runs macros, returns first msg
│   │   ├── memory_draft_generator.dart   # LLM-based memory auto-generation (called by controller)
│   │   ├── image_recovery_service.dart   # Recovers failed inline image gen results
│   │   ├── abort_handler.dart        # genId + cancel tokens + restoration snapshot
│   │   ├── controllers/              # Extracted ChatNotifier responsibilities
│   │   │   ├── chat_session_controller.dart
│   │   │   ├── chat_swipe_controller.dart
│   │   │   ├── chat_message_ops_controller.dart
│   │   │   ├── chat_message_selection_controller.dart
│   │   │   ├── chat_draft_controller.dart
│   │   │   └── chat_image_recovery_controller.dart
│   │   ├── services/
│   │   │   ├── generation_pipeline.dart  # Post-SSE: persist, rollback, image tags, extensions, sync
│   │   │   ├── saved_message_writer.dart # Pure builders for assistant/error/regen messages
│   │   │   ├── stream_generation_service.dart # SSE + prompt build + stream accumulate + save
│   │   │   ├── image_gen_processor.dart
│   │   │   ├── magic_drawer_layout_service.dart
│   │   │   └── magic_drawer_stats_service.dart
│   │   ├── bridge/                       # WebView ↔ Flutter bridge
│   │   │   ├── chat_bridge_controller.dart  # Host: shared state + iterates bridgeHandlers
│   │   │   ├── bridge_handlers.dart         # Single source of truth: 40 JS handler names
│   │   │   ├── bridge_message_commands.dart # set/append/update/remove messages, scroll
│   │   │   ├── bridge_theme_commands.dart   # applyTheme, fonts, background, performance
│   │   │   ├── bridge_identity_commands.dart # setIdentity, applyLayout, regex context
│   │   │   ├── bridge_layout_commands.dart  # padding, search, edit, selection, settings
│   │   │   ├── bridge_memory_commands.dart  # memory book data updates + state sets
│   │   │   ├── chat_message_mapper.dart     # ChatMessage → JS map conversion
│   │   │   ├── chat_webview_keep_alive.dart # Keep-alive key provider
│   │   │   └── chat_webview_settings.dart   # WebView performance/config flags
│   │   ├── models/
│   │   │   └── message_dto.dart
│   │   ├── state/
│   │   │   ├── chat_body_selectors.dart # batteryAware dual-read helper
│   │   │   ├── cached_token_breakdown.dart
│   │   │   └── token_breakdown_cache.dart
│   │   ├── utils/
│   │   │   └── message_preview.dart   # Notification preview text helper
│   │   └── widgets/                      # Chat UI widgets (sheets, header, webview, etc.)
│   ├── memory/
│   │   ├── controllers/
│   │   │   └── memory_book_controller.dart # Draft gen, cancel tokens, mutex with chat gen
│   │   └── state/
│   │       └── memory_active_drafts_provider.dart # SessionIds with active memory drafts
│   ├── extensions/                   # Info blocks + post-generation extension pipeline
│   │   ├── models/                     # extension_preset, info_block, block_config, settings
│   │   ├── providers/                  # extension_presets, info_blocks, extensions_settings
│   │   ├── screens/                    # extensions_screen, preset_editor_screen export
│   │   │   └── preset_editor/          # scaffold, sections, block editor widgets
│   │   ├── services/
│   │   │   ├── extension_post_gen_service.dart # Thin orchestrator for block chain entrypoints
│   │   │   ├── blocks/                 # BlockProcessor, handlers, status/panel/image helpers
│   │   │   ├── js_bridge/              # JsBridgeService dispatcher + capability-gated handlers
│   │   │   ├── info_block_service.dart         # LLM call for infoblock type
│   │   │   └── info_block_injector.dart        # Injects stored outputs into prompt context
│   │   └── widgets/
│   ├── chat_history/
│   │   ├── chat_history_provider.dart    # All sessions across all characters
│   │   └── chat_history_screen.dart      # Root/home screen (shell tab `/`)
│   ├── settings/
│   │   ├── api_list_provider.dart        # ApiListNotifier + activeApiConfigProvider
│   │   ├── app_settings_provider.dart    # App-level preferences
│   │   └── ...                           # api/app/theme screens + widgets
│   ├── lorebooks/                    # Lorebook UI screens + widgets
│   ├── presets/                      # Preset UI screens + widgets
│   ├── personas/                     # Persona UI screens + provider
│   ├── backup/                       # Backup UI screen + provider
│   ├── catalog/                      # Character discovery: UI + provider + API services
│   ├── character_list/               # Character list/detail/editor screens + widgets
│   ├── character_gallery/            # Gallery screen + provider
│   ├── regex/                        # Global regex list screen
│   ├── cloud_sync/                   # Cloud sync UI + provider
│   │   ├── sync_provider.dart
│   │   ├── sync_config.dart / sync_models.dart / sync_repo_interfaces.dart
│   │   ├── cloud_adapter.dart
│   │   ├── services/
│   │   │   ├── sync_service.dart       # High-level orchestrator, lock management
│   │   │   ├── sync_engine.dart        # Manifest diff, upload/download, conflicts
│   │   │   ├── sync_binary_asset_syncer.dart # Avatar/gallery push/pull (extracted from SyncEngine)
│   │   │   ├── sync_image_stripper.dart # Strips [IMG:*] tags from chat sessions before sync
│   │   │   ├── sync_controller.dart    # UI-facing sync actions
│   │   │   ├── sync_manifest.dart / sync_serialization.dart / sync_conflict.dart
│   │   │   ├── sync_queue.dart
│   │   │   ├── oauth_local_server.dart # Desktop OAuth loopback
│   │   │   ├── dropbox/                # dropbox_adapter, dropbox_auth
│   │   │   └── gdrive/                 # gdrive_adapter, gdrive_auth, gdrive_files, gdrive_folders
│   │   └── widgets/                    # sync_sheet, sync_sheet_widgets, sync_icons
│   ├── image_gen/                    # Image generation UI, provider, services
│   │   ├── image_gen_provider.dart
│   │   ├── image_gen_models.dart
│   │   ├── services/                    # image_gen_service, http, provider adapters
│   │   └── widgets/                     # sheet, rows, connection_fields, model_fields, renderer
│   ├── glossary/
│   │   └── glossary_sheet.dart         # Glossary UI (route `/menu/glossary`)
│   ├── onboarding/                   # First-run onboarding screen
│   ├── picks/                        # Featured picks grid + detail launcher
│   ├── tools/                        # Developer tools screen (tokenizer, coverage, etc.)
│   ├── dev/                          # Internal UI demos (menu group demo)
│   └── menu/                         # Sidebar menu + About overlay/screen
├── shared/
│   ├── shell/
│   │   ├── shell_screen.dart         # Bottom nav shell (GoRouter StatefulNavigationShell)
│   │   ├── nav_height_provider.dart  # navHeightProvider: nav bar height for layout
│   │   ├── shell_header_provider.dart
│   │   └── desktop/                  # Desktop (≥768px) three-column layout
│   │       ├── desktop_shell.dart    # Shell wrapper; left/center/right columns
│   │       ├── desktop_layout_provider.dart
│   │       ├── desktop_left_sidebar.dart  # Chat list + nav (replaces bottom nav)
│   │       ├── desktop_right_sidebar.dart # Tools / MagicDrawer
│   │       ├── desktop_window_view.dart
│   │       ├── desktop_floating_provider.dart
│   │       └── desktop_glossary_popup.dart
│   ├── theme/                        # ThemePreset, storage, provider, fonts, app_colors, app_theme
│   ├── utils/
│   │   └── color_utils.dart
│   └── widgets/                      # Reusable UI primitives (glaze_bottom_sheet, sheet_view, …)
├── app.dart                          # GlazeApp: wires routerProvider + boot-time init
└── main.dart                         # Entry point: orientation lock, prompt_worker init
```

### Navigation (`lib/core/navigation/router.dart`)

GoRouter lives in `router.dart`, not `app.dart`. Shell tabs and overlay routes:

| Route | Screen |
|-------|--------|
| `/` | `ChatHistoryScreen` (mobile); redirects to `/characters` on desktop (width ≥ 768, non-mobile force) |
| `/characters` | `CharacterListScreen` |
| `/tools` (+ nested `api`, `personas`, `presets`, `regex`, `lorebooks`, `lorebooks/settings`, `embeddings`) | `ToolsScreen` |
| `/menu` (+ `settings`, `themes`, `about`, `glossary`) | `MenuScreen` |
| `/chat/:charId` | `ChatScreen` (query params: `?session=`, `?new=1`, `?msg=`) |
| `/character/create`, `/character/:charId`, `…/edit`, `…/gallery` | Character CRUD overlays |
| `/sync` | `SyncSheet` |
| `/extensions`, `/extensions/preset-editor/:presetId` | Extensions screens |

---

## 1. Generation Pipeline

### Phase A — SSE stream (in call order)

| Step | File | Role |
|------|------|------|
| 1 | `chat_provider.dart` | Owns `ChatState`; starts gen, delegates to `ChatGenerationService` |
| 2 | `chat_generation_service.dart` | Thin facade → `StreamGenerationService.run()` |
| 3 | `stream_generation_service.dart` | Payload build, isolate, SSE, `SavedMessageWriter` on success/error |
| 4 | `prompt_payload_builder.dart` | Reads Riverpod state; async vector lore + memory scoring |
| 5 | `prompt_isolate.dart` + `prompt_worker.dart` | Runs `buildPrompt()` off UI thread |
| 6 | `prompt_builder.dart` | Block ordering inside isolate |
| 7 | `prompt_block_resolver.dart` | Resolves each block ID → text |
| 8 | `lorebook_vector_search.dart` | Vector scan (async, before isolate, in payload builder) |
| 9 | `lorebook_scanner.dart` | Keyword scan (sync, inside isolate) |
| 10 | `lorebook_merger.dart` | Merges keyword + vector, deduplicates |
| 11 | `memory_injection_service.dart` + `memory_budget.dart` | Scores entries, applies INV-PS4 token cap |
| 12 | `history_assembler.dart` | Assembles history blocks with depth inserts |
| 13 | `context_calculator.dart` | Trims history from oldest end |
| 14 | `regex_service.dart` | Applies regex scripts per block |
| 15 | `macro_engine.dart` | Expands `{{macro}}` tokens |
| 16 | `sse_client.dart` | Sends request, streams SSE deltas |
| 17 | `stream_accumulator.dart` | Splits text from inline `<think…>` reasoning |
| 18 | `response_normalizer.dart` | Non-streaming response extraction |

### Phase B — Post-SSE (`generation_pipeline.dart` + `stages/post_gen_coordinator.dart`)

After `StreamGenerationService` returns, `ChatNotifier._runGeneration()` runs
`GenerationPipeline.run()` for **send** and **regenerate** only. The pipeline
persists the assistant result (or follows the regen/error rollback path), then
delegates successful post-generation work to `PostGenCoordinator`.

Shared work starts with awaited cloud-sync and generation notifications. Raw
message embeddings and empty MemoryBook draft planning are then launched as
independent background tasks.

**Studio OFF:** ExtBlocks run in the background. Inline `[IMG:GEN]` processing
runs independently when image tags exist; neither task updates Studio Ledger.

**Studio ON:** `CleanerStage` owns the ordered canonicalization path:

1. Character & World audit (when POST-cleaner and prompt payload are available)
2. POST-cleaner rewrite / canonical final-cleaned-partial swipe selection
3. ExtBlocks bound to that selected `(swipeId, agentSwipeId)`
4. Studio Ledger extraction from the same canonical text
5. Inline image-tag processing after the cleaner/Ledger task, using the
   reloaded canonical message

**Continue:** `ChatNotifier.continueMessage()` runs this same pipeline with
`continueTargetId` set. The prompt gains one system turn — *"Expand your latest
message, continue."* — directly after the reply being extended, so the request
never leans on provider prefill. Once the stream ends, `_resolveContinuation()`
merges the generated block into that message, commits it as a single guarded
message write, and runs the ordinary post-gen tail against it. A failed
continuation writes nothing to the message and surfaces as the `Continue Failed`
toast. See `docs/INVARIANTS.md` INV-CM1–INV-CM6.

**Talkativeness:** `sendMessage()` may skip generation when
`character.extensions['talkativeness']` rolls above the configured threshold.

### Prompt composition boundary

`PromptInputsCollector` and `PromptPayloadBuilder` do not import feature modules
or declare Riverpod providers. Feature-owned adaptation lives in
`features/chat/providers/prompt_build_providers.dart`: API-list initialization
and active API lookup, ExtBlocks history injection, runtime prompt injection,
and vector-search diagnostics. Adapters read current state when invoked rather
than capturing it when the provider is built. Runtime injections are converted
to a detached, immutable `List<RuntimePromptBlock>` before entering core prompt
code. The two core orchestrators still receive `Ref` for core providers; this is
a dependency-direction boundary, not a claim that prompt collection is pure.

### Prompt post-processing

**Files:** `core/llm/converters/prompt_post_processing.dart`,
`core/llm/transport/post_processing_chat_transport.dart`

`ApiConfig.promptPostProcessing` reshapes the finished, OpenAI-shaped message
array *after* the prompt is built and *before* the protocol converter runs. It
is a port of SillyTavern's `postProcessPrompt` / `mergeMessages`, and it uses
ST's own mode identifiers so prompts stay portable:

| Mode | Effect |
|------|--------|
| `none` (default) | Nothing — messages go out as built |
| `merge` | Squashes consecutive same-role messages |
| `semi` | `merge` + every system message after the first becomes `user` |
| `strict` | `semi` + a filler user turn so the prompt opens on `user` |
| `single` | Collapses the whole conversation into one `user` message |
| `merge_tools` / `semi_tools` / `strict_tools` | Same, keeping tool calls and tool results instead of stripping them |

It lives on the API connection, not the prompt preset: whether an endpoint
accepts several system blocks or non-alternating roles is a property of the
endpoint. It replaces the preset-level `mergePrompts` flag, which squashed
adjacent non-assistant *blocks* at build time. DB migration v118 only adds the
column with `none`; it deliberately does not infer a connection setting from
any active preset.

**Offered for `custom_chat_completion` only.** Every first-party protocol
already normalizes what its wire format demands inside its own converter — the
Anthropic and Gemini ones lift the leading system run into the native system
field, demote mid-prompt system turns to `user`, and squash same-role
neighbours (equivalent to `semi`). A custom endpoint is the one case Glaze
cannot know the shape of. `ApiConfigDraft.normalizeValues` clears the mode for
every other protocol so a hidden control can never reshape a prompt.

The picker shows one row per **family** (`none` / `merge` / `semi` / `strict` /
`single`) and stores `PromptPostProcessing.withTools(...)`, so a prompt that
starts carrying tool traffic keeps it rather than silently losing every call.
Glaze sends no tool definitions today — the agentic-memory service, the only
consumer, is disabled — which is why both halves of a pair are currently
indistinguishable. The no-tools halves stay implemented and reachable for
values imported from ST; `PromptPostProcessing.baseOf(...)` maps either half
back to its family for labels and the picker's checkmark.

`pickChatTransport` wraps every transport in `PostProcessingChatTransport`, so
the pass runs exactly once, for every caller, before any provider-specific
rewrite. `previousMessages` gets the same pass so cache-breakpoint hashes still
match. Every mode is idempotent, and the rewritten request carries
`promptPostProcessing: 'none'` so it can never be applied twice. The prompt
preview builds bodies without a transport, so it calls
`PostProcessingChatTransport.applyTo` itself.

`single` would otherwise erase who spoke each chat turn when all roles become
one `user` message. Chat-aware callers therefore attach effective `charName`
and `userName` as request-only metadata. The post-processing decorator prefixes
assistant and user text with those labels for both `messages` and
`previousMessages`; the names are not stored in `ApiConfig`, serialized as a
wire field, or added globally as `message.name`.

The Prompt Inspector shows the same reshaped conversation in its **formatted**
view, not just in the raw JSON:
`features/chat/services/prompt_preview_post_processor.dart` replays the pass
over the built `PromptMessage` list and returns one `PreviewMessage` per
outgoing message, each carrying the blocks that were folded into it (so a
merged card can show the union of their section flags, their joined block
names, every attachment, and a badge with the block count). It never
re-implements the rules: it runs the real `postProcessPrompt` over placeholder
content — one unique token per built message — and reads the tokens back out of
the result to recover which blocks landed where.

### Request Types

| Type | State owner | Streaming | Abort |
|------|-------------|-----------|-------|
| Chat | `ChatState.isGenerating` per `charId` | Yes (SSE) | `AbortHandler`: `CancelToken` + `_activeGenId` |
| Image gen | `ChatState.isGeneratingImage` + `_imgGenCancelToken` | No (one-shot) | `_imgGenCancelToken` in `ChatNotifier` |
| Summary (manual) | Widget-local in `summary_tab.dart` | No | Not abortable (INV-S2) |
| Summary (auto) | `AutoSummaryStage`, from `PostGenCoordinator` | No | Not abortable (INV-S2) |
| Memory draft | `MemoryDraftGenerationController` (delegated by `MemoryBookController`) | No | Per-draft `CancelToken`; mutex via `memory_active_drafts_provider` |

### Reasoning / Thinking

`ApiConfig.requestReasoning` controls whether Glaze asks the provider for
provider-native reasoning. `ApiConfig.omitReasoning` suppresses app-side
reasoning request fields such as OpenAI `reasoning_effort`, Anthropic/Gemini
thinking configs, and Studio final-agent reasoning persistence. It does **not**
guarantee that a provider/model disables its internal thinking.

Gemini 3.x models can think by default. For example, Gemini 3.1 Pro exposes
thinking levels (`low` / `medium` / `high`) rather than a documented full off
switch. Custom OpenAI-compatible proxies such as rout.my may still report or
bill thought tokens even when Glaze omits reasoning request fields. Do not add
provider-specific `reasoning: { exclude: true }` or similar body fields unless
the target provider documents the exact field and we intentionally support that
contract.

Studio Mode follows the same policy for its final agent: trackers force
reasoning off/omitted; the final generator inherits the resolved `ApiConfig`
reasoning settings. Studio also strips prompt-level hidden-reasoning directives
from final-generator instructions when reasoning is disabled/omitted, but
cannot disable model-internal thinking if the upstream model always performs
it.

### Studio Mode Pipeline

Studio Mode separates analysis, prose generation, and post-generation editing.
Pre-generation trackers create compact briefs; one FINAL agent writes the
visible reply. Optional `StudioAgent.phase == 'post_processing'` agents then run
sequentially after FINAL and may replace the current response. These agents are
part of the Studio cycle and are distinct from the later POST-cleaner.

Studio has two separate persisted layers:

- `studio_config_rows` stores per-session Studio activation (`enabled` flag);
- `studio_preset_rows` stores user-owned prompt presets as JSON block lists,
  per-controller toggles, an explicit `executionMode`, and nested
  `StudioRuntimeSettings` (agent/cleaner/ledger tuning and broadcast blocks).

The active Studio preset is a global selection (`activeStudioPresetId` in
SharedPreferences, synced via `local_storage`). Session rows carry only the
on/off toggle — they do not bind to a specific preset.

Studio prompt presets are imported, copied, edited, and exported by the user.
The application does not expose a public default-seed reset and does not ship
the maintainer's working Loom presets as repository assets. Updating the app
therefore cannot silently replace a user's calibrated preset. Old seed block
data remains private to historical DB migrations only, so upgrades from older
schemas continue to work.

At the start of a normal generation,
`StudioTurnConfigResolver.resolve(sessionId)` captures one immutable
`StudioTurnConfigSnapshot`: topology-gated agents, the selected Studio preset,
pipeline settings, an immutable API-config list, and the active API fallback.
The same snapshot is passed through prompt construction, tracker/final-agent
execution, POST-cleaner, and Ledger. Changes made while a turn is running apply
to later turns only. A separate manual action may resolve a fresh snapshot.

#### Agent topology

Studio no longer has Direct, Assisted, or Legacy execution modes. The active
preset's agent toggles are the sole topology control. `StudioActivationGate`
splits enabled agents into pre-generation controllers, the required Main
Writer, and post-processing agents; declared dependencies are applied before a
turn starts. Main Writer is locked on, while Meta-Weaver / OOC Policy is off by
default.

At generation time `MemoryStudioService` delegates the shared pre-generation
controller phase to `ControllerPhaseRunner`, which runs:

1. **Cache probe** (`_probeCache`): each due tracker is checked against
   `_briefCache` keyed by refresh policy (`turn` / `scene` / `static`).
   Cache hits are excluded from the LLM round-trip.
2. **Batching** (`ControllerBatcher.groupAgents`): trackers with the same
   `(provider, model, phase)` are packed into one LLM request
   via `<agents><agent_task>` XML with a single system prompt that orders shared
   context first (`<role>` + `<lore>` = static + dynamic + trimmed history) and
   per-agent instructions last (`<agents>`) — a prompt-cache-friendly layout
   (Phase 6.1). Heavy trackers whose names match `expression`, `illustrator`, or
   `lorebook` are pulled out of the batch and run as their own request.
3. **Run phase** (`ControllerBatcher.runPhase`, concurrency limit 4): batch groups
   + individual agents fire in parallel, subject to the concurrency cap. Each
   batch is one LLM call → `parseBatchResponse` (`<result agent="id">` with
   missing-close-tag tolerance + `<result_ID>` legacy fallback).
4. **Batch retry**: if any agent in the batch comes back failed or missing,
   re-request the whole batch twice. If it still cannot be parsed, Studio
   returns a hard error asking the user to restart generation.
5. **Final generator** (`_runFinalGenerator`): runs after all pre-generation
    trackers settle, using a stable history window with
    `maxFinalHistoryMessages` (default 50) and a 70K-token high-water mark;
    trackers receive their own `contextSize` (default 5, hard-cap 200) via
    `StudioHistoryLimiter.limitTrackerHistory`
   (head 40% + tail 60%) + `stripHtmlTags`.
6. **Studio post-processing agents:** agents run in `order` every turn. Each
   receives the current `mainResponse`; a non-empty result replaces it before
   the cycle returns. Historical per-agent cadence and keyword gates no longer
   live on `StudioAgent`.

`ControllerPhaseRunner` owns the tracker phase and converts exhausted failures
into a hard Studio result. `StudioBatchCoordinator` and `StudioAgentExecutor`
own the initial attempt plus two retries for batched and individual trackers,
respectively. Studio aborts before the final generator instead of running with
partial tracker output. The generator's own failure aborts the turn.

Per-controller model and parameter resolution comes from its immutable
`StudioControllerSpec`, the Studio slot settings, and the chat connection
fallback; those settings no longer live on `StudioAgent`. Concurrency cap:
`_maxConcurrentGroups = 4` (Phase 5.7.2, conservative default for desktop).

Per-slot parameter overrides (Agents tab → *Parameter overrides*) are gated on
`<field>Override` booleans in `StudioAgentSettings` / `CleanerSettings`. A flag
that is off makes `AgentConfigResolver` pass `null` for that parameter, so
`copyWithSampling` / `copyWithReasoning` keep whatever the slot's `ApiConfig`
resolved to — that is what the sheet shows as the inherited value. Temperature,
max tokens and the idle timeout carry no flag: they already encode "not
overridden" as a sentinel (negative / `0`) and fall back to the **per-agent
spec**, not to the API preset, which is why the sheet labels those as the agent
default. All flags default to `true` so an upgrade keeps applying the values it
applied before they existed.

POST-processing (Phase 1.3) stays separate from the tracker pipeline: the
POST-cleaner runs after the full reply and writes a blue `'cleaned'` agent
sub-swipe (`post_cleaner_service.dart`, `generation_pipeline.dart`),
preserving the original `'final'` as the parent. Hold mode (Marinara) is not
implemented. See INV-ST4.

Beauty is cleaner-owned rather than a separate pre-generation controller.
`CleanerStage` can derive styling guidance during its audit and passes it to the
cleaner together with the persisted `glaze_beauty_state` session variable. The
POST-cleaner enable switch controls automatic cleaner/audit calls, not the
independent Studio agent topology.

#### POST-cleaner swipe lifecycle (UX phase, "swipe-first streaming")

Every automatic or manual cleaner run first acquires a `CleanerRunLease` from
`CleanerRunRegistry`, keyed by `(sessionId, messageId)`. A newer same-key run
cancels the previous lease and waits for its cleanup before it may mutate the
message; superseded queued runs do not start. Different keys may run
concurrently. Only the globally latest lease may publish shared cleaner UI,
streaming, and cancel-token state.

The cleaned swipe is **pre-created at cleaner start** (empty content, tracker
snapshot cloned from the parent `'final'`) so the blue sub-swipe switcher is
visible immediately while the rewrite streams into the chat bubble for live
preview (`CleanerStage`). The cleaner's `onCleanedChunk` callback tracks the
latest accumulated chunk in `CleanerStage._lastStreamedText` —
`SidecarCallOutcome.text` is null on failure, so partial text the user saw live
is only reachable via the callback.

On cleaner completion (`stages/cleaner_stage.dart`):
- `wasCleaned==true` → `ChatRepo.updateAgentSwipeContent` fills the pre-created
  swipe with the cleaned text + per-swipe `genTime` (cleaner's own elapsed)
  + `tokens` (estimateTokens of the cleaned text) — keeps the badge visible on
  the blue sub-swipe.
- `wasCleaned==false` AND partial text was streamed → keep the complete latest
  streamed partial in the swipe so the user doesn't lose what they saw live
  (ops log summary marks `partialSaved (N chars)`).
- `wasCleaned==false` AND nothing streamed → `ChatRepo.removeAgentSwipe`
  deletes the pre-created empty swipe and reverts active to the parent
  `'final'`.
- Abort mid-cleaner → remove the pre-created empty swipe (no partial save on
  abort by default).
- Hard pipeline failure → preserve the latest streamed partial when non-empty;
  otherwise best-effort remove the empty swipe and revert in the catch block.
- Pre-create failed earlier → fall back to the legacy
  `applyCleanedText` (append) path so the user still gets a `'cleaned'` swipe.

`ChatRepo.updateAgentSwipeContent` / `removeAgentSwipe` are the atomic
(transaction-wrapped) methods for in-place swipe edits; `appendAgentSwipe`
remains the legacy append path. `PipelineSettings.cleaner.postCleanerAuditModel` exists,
but the current `CleanerStage` passes the resolved cleaner config to both the
character/world audit and rewrite; a separate audit-model override is not yet
wired into this runtime path.

The manual rerun action is available for the settled last character message
whenever it has an agent swipe, including when automatic POST-cleaner is off.
Both WebView render paths must enforce this invariant: the full footer builder
in `message_renderer.js` and incremental `_syncMessageControls` in
`chat_bridge_controller.js` create `.msg-rerun-cleaner` under the same
`isChar && isLast && !isGenerating && !isEditing && agentSwipeTotal >= 1`
condition. Otherwise the button appears only after reopening the session and
forcing a full render.

### Studio agents and block routing

Studio agents are defined directly in `StudioPreset.agents`, each with an
explicit `controllerId` (continuity / agency / narrative / dialogue / guard /
world / meta / beauty / final). The last enabled pre-generation agent is the
generator; all earlier agents are trackers. `StudioMessageBuilder` routes
preset blocks to agents by `targetAgentId` and expands chat-time macros
(`{{char}}`, `{{user}}`, `{{studio_*_brief}}`). Broadcast rules for the
POST-cleaner live in `StudioPreset.runtime.broadcastBlocks`.

Manual editing: `studio_settings_sheet.dart` exposes a "Edit Preset Blocks"
button (opens `StudioPresetEditorSheet`), and a per-slot settings dialog
for model parameters (temperature, topP, reasoning, etc.). Studio
agent/cleaner/ledger settings are written to the active preset's
`StudioRuntimeSettings`, not to global `PipelineSettings`.

### Nested swipes (agentSwipes)

`ChatMessage.agentSwipes` holds blue sub-swipes (`AgentSwipe` with `kind`:
`'final'` | `'cleaned'`, `parentSwipeId` linking a cleaned swipe to its
parent final). `ChatMessageService.setSwipe` saves/loads agentSwipes through
`swipesMeta[swipeId]` so green-swipe round-trips preserve them;
`setAgentSwipe` / `changeAgentSwipe` navigate blue sub-swipes. The WebView
renders an `agent-switcher` (blue) control when `agentSwipes.length > 1`,
dispatching `agent-swipe-left/right` → `onAgentSwipe`. A full regeneration
resets `agentSwipes` to a single fresh `'final'`.

Tracker snapshots (Phase 1, INV-TS4) are anchored at the same per-agent-swipe
granularity `(messageId, swipeId, agentSwipeId)` — so swiping between blue
sub-swipes also restores the matching tracker state (the read path returns
the snapshot for the current anchor).

### Live Studio status card (Phase 11)

While the Studio tracker-cycle runs, a floating `StudioStatusCard` appears
at the top of the chat (below the POST-cleaner status card — they never
overlap in time: Studio runs during generation, POST-cleaner after). It is
driven by `studioCycleStateProvider` through phases:

  idle → running → writingFinal → done | error

`StreamGenerationService` sets `running` when Studio intercepts, transitions
to `writingFinal` on the first `onFinalResponseUpdate` callback (trackers
done, final generator now streaming), and the terminal phase after
`runTrackerCycle` returns. The card auto-dismisses 2.5s after the cycle
finishes.

### Prompt Ordering (invariant — do not reorder)

1. Vector lorebook scan (async, in `PromptPayloadBuilder`, before isolate)
2. Keyword lorebook scan (synchronous in `PromptBuilder`, inside isolate)
3. Merge: keyword + vector, deduplicate vector against keyword
4. Memory injection (with optional token budget — see INV-PS4)
5. Context cutoff — trims oldest messages first

---

## 2. Macro Engine

**File:** `lib/core/llm/macro_engine.dart`

### Supported Macros

**Character/User:**
- `{{char}}` — character name
- `{{user}}` — user/persona name
- `{{description}}`, `{{personality}}`, `{{scenario}}`, `{{mesExamples}}` — character card fields
- `{{persona}}` — user persona prompt

**Variables (SillyTavern-compatible):**
- `{{setvar::name::value}}` — session variable (per `charId+sessionId`, stored in `MacroContext.sessionVars`)
- `{{getvar::name}}` — get session variable
- `{{setglobalvar::name::value}}` — global variable (cross-session, `globalVarsProvider`)
- `{{getglobalvar::name}}` — get global variable

**Utility:**
- `{{random::a::b::c}}` — random choice
- `{{pick::a::b::c}}` — deterministic pick (hash-stable per session)
- `{{roll::1d20}}` — dice roll
- `{{trim}}` — trim whitespace
- `{{date}}`, `{{time}}`, `{{weekday}}`

**Reasoning:**
- `{{reasoningPrefix}}`, `{{reasoningSuffix}}` — inline reasoning tag config

**Dynamic content:**
- `{{summary}}` — current chat summary (user-authored only)
- `{{memory}}` — triggered memory book entries. Memory can enter the prompt three ways: a dedicated `memory` ("Memory Book") preset block (addable from the editor, resolves like the macro), the `{{memory}}` macro, or — with `injectionTarget='hard_block'` (default) — an auto-injected "Memory Book" system message. With `injectionTarget='macro'` and no `{{memory}}` macro or `memory` block present, memory is dropped and `memoryMacroMissing` is flagged. See INV-PS5.
- `{{lorebooks}}` — triggered lorebook content
- `{{guidance}}` — guided swipe instruction

**Comments:**
- `{{// comment}}` — single-line comment (removed)
- `{{ // }}...{{ /// }}` — multi-line scoped comment (removed)

**Escaping:** `\{\{` → `{{`, `\}\}` → `}}`

### Resolution Order (fixed, matches code)

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

### Session variables on abort/error

`pendingSessionVars` from the isolate reach the DB **only** on a successful
commit. `SavedMessageWriter` carries the generated values;
`GenerationPipeline._commitGenerationResult` applies their delta to the latest
durable session through `ChatRepo.mutateSession`. Continuation uses the same
delta rule. Abort and error paths do not apply it. See `docs/INVARIANTS.md`
INV-C5.

---

## 3. Lorebook System

### Files
- `lorebook_scanner.dart` — keyword scan: sticky/cooldown/probability/character-filter/recursion
- `lorebook_merger.dart` — merges keyword + vector results, deduplicates by entry ID
- `core/state/lorebook_embedding_provider.dart` — Riverpod composition for vector search and embedding
- `lorebook_coverage.dart` — diagnostic full coverage report
- `lorebook_vector_search.dart` — cosine similarity, hybrid boost (name/key/hint overlap)
- `lorebook_embedding_service.dart` — indexes lorebook entries (hash-based dirty check)
- `retrieval_hints.dart` — extracts retrieval hints from lorebook entries
- `embedding_service.dart` — calls embedding API, auto-chunking, rate-limit handling
- `embedding_types.dart` — shared embedding type definitions
- `embedding_error_labels.dart` — error classification for embedding status UI
- `vector_math.dart` — `cosineSimilarity`, `findTopK`, `findTopKMulti` (MaxSim)
- `lorebook_provider.dart` — CRUD + activations + settings (SharedPreferences)

### Search Type System
- `searchType`: `'keys'` | `'vector'` | `'both'`
- `'keys'` — keyword-only (default)
- `'vector'` — vector-only semantic search
- `'both'` — combined (keyword results deduplicated from vector budget)

### Recursive Scan Bounds
- Max iterations: 5 when `recursiveScan == true`, else 1
- Prevents infinite loops from circular lorebook references

---

## 4. Memory Books

### Files
- `features/memory/controllers/memory_book_controller.dart` — UI-facing draft gen, cancel, mutex
- `features/memory/state/memory_active_drafts_provider.dart` — cross-feature mutex with chat gen
- `memory_draft_generator.dart` — LLM-based draft generation, batching, progress
- `memory_injection_service.dart` + `memory_budget.dart` + `memory_excerpt_selector.dart` — scoring, packing, INV-PS4 token cap
- `memory_embedding_service.dart` — indexes/reindexes memory entries
- `memory_book_repo.dart` — DB persistence for `MemoryBook` rows
- `core/state/memory_settings_provider.dart` — global settings (SharedPreferences)

### Data Model (key fields)
```dart
MemoryBook {
  entries: List<MemoryEntry>
  pendingDrafts: List<MemoryDraft>
  settings: MemoryBookSettings  // includes maxInjectionBudgetPercent (default 0.35)
}

MemoryEntry {
  id, title, content, keys
  vectorSearch: bool
  messageIds: List<String>
  messageRange: { start, end }
  status: 'active' | 'needs_rebuild' | 'stale'
  source: String // provenance, e.g. scan_chat / auto_create
  importance, arc, locked, temporallyBlind
}

MemoryDraft {
  id, title, content, keys, messageIds, messageRange
  status: 'pending_generation' | 'needs_regeneration' | 'pending_approval'
  source: String // scan_chat / auto_create
}
```

`messageRange` is provenance metadata and must survive draft approval:
`MemoryDraft.messageRange` is copied to `MemoryEntry.messageRange`. Older
generated entries whose title is a plain range like `91-105` are read with a
compatibility backfill into `messageRange`.

### Draft lifecycle

`MemoryDraftPlanner` scans stable user/assistant messages, leaves a configurable
recent-message lag, and creates only complete fixed-size ranges. The post-turn
`MemoryDraftStage` and manual **Scan Chat** action create empty drafts without an
LLM call. Draft text is generated later through
`MemoryDraftGenerationController` + `memory_draft_generator.dart`, then remains
`pending_approval` until the user accepts it. Approval copies content, keys,
message provenance, and range into an active `MemoryEntry`; vector indexing is
best-effort when enabled.

The `autoGenerateEnabled` setting exists in model/UI, but the current automatic
post-turn stage does not invoke LLM draft generation. Automatic draft creation
is not automatic memory population or approval.

### Retrieval and injection rule

The retrieval query is assembled from current input, optional assistant text,
and recent turns. `MemorySelector` combines keyword, vector, catalog, recency,
importance, entity, emotion, and diversity signals depending on mode/settings.
Selection is bounded by entry count and token budget, then
`MemoryExcerptSelector` packs full entries or excerpts.

When v2 `sourceWindowExclusion` is enabled, an entry is excluded if **any** of
its linked `messageIds` overlaps the visible history window. Legacy selection
and explicit exclusion-disable paths bypass this rule. Deferred macro injection
rechecks against the final context cutoff to avoid a gap between trimmed history
and recalled memory.

### Token budget (INV-PS4)
`MemoryInjectionBudget.maxInjectionTokens()` caps injected memory at
`contextBudgetTokens * maxInjectionBudgetPercent` (default 35%).
See `docs/INVARIANTS.md` INV-PS4.

### Packing modes (`memoryPackingMode`)

After `MemorySelector` scores candidates, `MemoryExcerptSelector` decides
**what text** from each entry is injected. Settings live in
`MemoryBookSettings` / `MemoryGlobalSettings` (UI: *Memory → Advanced
selector → Packing mode*).

| Mode | Behaviour |
|------|-----------|
| `full` | Inject whole entry bodies when they fit the budget. |
| `hybrid` | Prefer full entries; when the budget is tight, fall back to per-entry excerpts (top chunks inside each entry). |
| `chunk_first` | Always pack **chunks** globally by relevance × token cost, not full entries. |

**Chunking** (`memory_excerpt_selector.dart`): entry content is split on blank
lines (`\n\n`) into paragraph blocks up to
`memoryExcerptTokensPerChunk` tokens; oversized blocks are split further by
sentence/word windows.

**`chunk_first` two-phase packing** (`selectChunkFirstGlobal`):

1. **Floor pass** — top `chunkFirstTopEntries` entries by entry score (recency,
   vector, keywords, importance) each receive up to `chunkFirstTopChunks` of
   their best chunks. This keeps fresh or vector-implied memories from losing
   entirely to keyword-heavy older arcs. Set `chunkFirstTopEntries` to `0` to
   disable the floor pass.
2. **Global pass** — remaining budget is filled with globally ranked chunks
   until `memoryExcerptChunksPerEntry` per entry or the token budget is
   exhausted.

Chunk relevance blends keyword overlap, vector chunk hints, and entry-level
signals (recency / vector / importance). Entry-level score shown in the
Injected Memory UI is **not** identical to per-chunk relevance in
`chunk_first` mode.

**Deferred `{{memory}}`**: when `injectionTarget='macro'` and a preset block
contains `{{memory}}` (e.g. inside `<summary>` on the last user message),
`PromptBuilder` finalizes memory **after** the context cutoff is known,
replacing `[[GLAZE_DEFERRED_MEMORY_CONTEXT]]` with the excerpt-packed macro
content. `PromptPayload.memorySelection` must be populated (no shadowed local)
for this path to run.

**Diagnostics** (`memory_diagnostics.dart`, `memory_activity_card.dart`):
per-candidate reasons include `chunk_rank_trimmed` / `chunk_budget_trimmed`;
expanded rows show `N из M` chunks and chunk indexes. Labels like `121-135` are
**chat message ranges** (`messageRange`), not chunk indices.

**LLM request dump** (`core/llm/transport/llm_request_dump.dart`): a debug-only
diagnostics aid for inspecting every outgoing LLM request made while answering a
single chat turn — studio shards, the main model, the post-cleaner audit +
cleaner passes, and the agentic-memory writer. `transport_factory.dart` wraps
every transport from `pickChatTransport` in a `LoggingChatTransport` decorator
(itself wrapped in `PostProcessingChatTransport`, so the dump records the
post-processed conversation that actually goes out);
when enabled it appends one JSON object per line (JSONL) to a temp file
(`glaze_llm_dump.jsonl`, overwritten on app start) before delegating to the
inner transport. **Off by default** (`LlmRequestDump.enabled = false`): when
off, the decorator delegates with zero overhead. Flip `enabled = true` to
capture full prompts for debugging; it is NOT a production logging facility (the
dump contains full prompt text). `LlmRequestDump.filePath` overrides the output
location.

### Raw recall and canonical state

Raw recall is independent from MemoryBook. `ChatMessageEmbeddingService`
indexes source-message chunks after a turn; `MessageRecallService` performs
single-session semantic retrieval and injects selected source text through
`<recalled_messages>`. It uses the same any-overlap source-window exclusion and
requires a configured embedding endpoint. Embedding/search failures degrade to
an empty best-effort result rather than failing chat generation.

MemoryBook, Raw Recall, character knowledge, and Studio Ledger are separate
continuity layers:

1. MemoryBook: user-approved episodic summaries.
2. Raw Recall: near-verbatim source-message chunks.
3. Character knowledge facts: scoped, provenance-backed character state and
   epistemic facts.
4. Studio Ledger: compact current scene/world/relationship/arc canon.

Prompt continuity blocks are ordered MemoryBook → Raw Recall → current
character state → current Studio session state. Studio OFF stops new Ledger
writes but does not suppress previously committed Ledger/fact projections.

`MemoryPostTurnService.runPostTurn()` is currently a no-op except for cadence
bookkeeping. Heuristic graph, salience, and consolidation writes remain disabled
because the extractor is unreliable for non-English roleplay. Their tables
remain for forward compatibility; Studio Ledger is the sole automatic writer of
canonical tracker state.

`StudioLedgerService` is the compatibility facade over the specialists in
`core/llm/ledger/`: canon authority, in-flight registry, output recovery,
prompt factory, diagnostics, turn runner/committer, reconciliation
runner/committer, replacement-basis resolver, operation applier, provenance,
and run-result contracts. Durable writes belong to the two committers; the
facade preserves the established entrypoints and dependency wiring.

### Automated Card Evolution

`AutomatedCardEvolutionService` is likewise a compatibility facade. It owns
public entrypoints and per-session in-flight deduplication, while
`CardEvolutionCollectorCoordinator` owns collector claims, observation state,
evidence validation, effects, and promotion, and
`CardEvolutionWriterCoordinator` owns writer claims, cancellation, card/repair/
lorebook execution, and finalization. Supporting ownership is split among
`ObservationResponseParser` (typed collector parsing),
`CardEvolutionDiagnostics` (parser/model/selection outcomes),
`DurableWriterCallRunner` (checkpointed prepare/replay/execute/complete), and
`WriterContextConsolidator` (bounded history chunks and cumulative handoff).

---

## 5. Database Layer

`AppDatabase` is at schema **v130** and registers **56 tables**. The current
source of truth is the `@DriftDatabase(tables: [...])` list in
`lib/core/db/app_db.dart`; generated `app_db.g.dart` reflects that declaration.
Do not maintain a hand-copied table-by-table inventory here.

`app_db.dart` is the composition root. Its implementation is split into
`migrations/database_integrity.dart`, `migrations/studio_legacy.dart`,
`migrations/upgrade_v2_v50.dart`, `migrations/upgrade_v51_v100.dart`,
`migrations/upgrade_v101_v130.dart`, and `studio_preset_seed.dart`. The versioned
files preserve historical upgrades; current schema declarations live behind the
`tables.dart` barrel in seven domain parts:

| Domain part | Ownership |
|---|---|
| `tables/characters_and_chat.dart` | Characters, folders, chats, and personas |
| `tables/studio_and_presets.dart` | Studio activation/presets, prompt presets/folders, and API configs |
| `tables/lorebooks.dart` | Lorebooks, session evolution overlays, immutable use manifests, and acceptance evidence |
| `tables/memory.dart` | MemoryBook/catalog/legacy graph state, embeddings, and summaries |
| `tables/ledger.dart` | Live/snapshot Ledger state, reconciliation lifecycle, character knowledge, and LLM diagnostics |
| `tables/canon_and_rewrite.dart` | Character revisions, canon checkpoints, rewrite review/audit, and Card Evolution durability |
| `tables/extensions.dart` | Extension presets and InfoBlock results |

Repositories under `lib/core/db/repositories/` are the behavioral source of
truth for reads, writes, transactions, and lifecycle cleanup. Not every table
maps one-to-one to a repository; transactional aggregates intentionally span
related tables. Historical milestones such as v20 ExtBlocks, v35 Memory Graph,
v45 Ledger rows, v50 snapshots, and the v101 Studio activation rebuild remain
relevant migration context, not descriptions of the complete current schema.

### Write Rule
**Never** commit a mutation with `getChat -> copyWith -> put`. Use the narrowest
transactional repository mutation API. Publish only the durable session returned
by that API to cache/state; on conflict or failure, reload before publication.
See `docs/rules/database.md`.

---

## 6. Cloud Sync

All service implementations live under `lib/features/cloud_sync/services/`.

### Files
- `sync_service.dart` — high-level orchestrator, lock management
- `sync_engine.dart` — manifest diff, upload/download, conflict detection
- `sync_controller.dart` — UI-facing sync actions
- `sync_manifest.dart` — reads/writes cloud JSON manifest (ETags + timestamps)
- `sync_serialization.dart` — entity → JSON envelope
- `sync_conflict.dart` — winner = newer `updatedAt`
- `sync_queue.dart` — serial queue preventing duplicate uploads
- `sync_config.dart` / `sync_models.dart` — configuration and data models
- `sync_provider.dart` — Riverpod composition root for sync state and stores
- `core/application/sync_repo_interfaces.dart` — neutral core-entity store ports
- `core/application/*_deletion_store.dart` — neutral lifecycle deletion ports
- `shared/application/sync_theme_store.dart` — neutral theme store port
- `features/cloud_sync/sync_repo_interfaces.dart` — feature-owned extension and manifest ports
- `cloud_adapter.dart` — abstract adapter interface for cloud providers
- `dropbox/dropbox_adapter.dart` + `dropbox_auth.dart` — OAuth2 PKCE + API v2
- `gdrive/gdrive_adapter.dart` + `gdrive_auth.dart` + `gdrive_files.dart` + `gdrive_folders.dart`
- `oauth_local_server.dart` — desktop OAuth loopback (local HTTP server)
- `core/services/deep_link_service.dart` — mobile OAuth deep-link receiver
- `widgets/sync_sheet.dart` — Sync UI sheet

### What Is Synced
Characters, sessions, personas, presets, API configs, lorebooks, MemoryBooks,
themes, extension presets/settings, InfoBlocks, Studio configs and presets,
summaries, character folders, tracker snapshots, live tracker values, character
knowledge, compatible Memory Graph collections, selected global local-storage
settings, and supported binary assets. **Not synced:** embedding vectors,
generation state, transient UI state, and debug traces.

Core repositories implement the neutral ports and must not import
`features/cloud_sync`; `sync_provider.dart` supplies those repositories and the
feature-local adapters to `SyncService`.

---

## 7. Theme System

### Files
- `shared/theme/theme_preset.dart` — Freezed `ThemePreset` model
- `shared/theme/theme_preset_storage.dart` — `ThemePresetStorage`: load/save/import presets (SharedPreferences)
- `shared/theme/theme_provider.dart` — `ThemeNotifier`: loads active preset, generates `ThemeData`
- `shared/theme/theme_font_provider.dart` — `ThemeFontNotifier`: loads Google Fonts async at startup
- `shared/theme/app_colors.dart` — `AppColors.fromPreset()`: all palette slots with defaults
- `shared/theme/app_theme.dart` — `AppTheme` builder: generates `ThemeData` + `ColorScheme` from preset

### `updatePreset(ThemePreset preset)` flow
1. `ThemeNotifier.updatePreset()` updates preview state immediately.
2. Persistence is debounced and serialized; rapid edits coalesce to the latest
   preset list, and `flushPersistence()` provides an explicit durable barrier.
3. `ThemeFontNotifier` detects font change and reloads the font family.

---

## 8. Image Generation

### Files
- `image_gen_service.dart` — orchestrates: builds the prompt, collects references, saves images
- `image_gen_dispatcher.dart` — routes a prepared request to the provider adapter of the active API type
- `image_prompt_builder.dart` — `[STYLE: …]` block, reference descriptions, reference instruction
- `reference_matcher.dart` — alias / word-boundary matching of the reference library against a prompt
- `image_reference_collector.dart` — avatars + matched references + context images, clipped per model
- `image_tag_markup.dart` — pure image-block text transforms (extracted from ImageGenService): the stored `<img data-iig-…>` element of a finished block (INV-IG9), the `[IMG:GEN]`/`[IMG:ERROR]` tags of one that has no picture yet, the `[IMG:RESULT]` of older messages, and `ImageBlockPayload`: the images one block carries, which of them is visible, and the instruction that produced them (INV-IG8)
- `image_gen_provider.dart` — manages settings + generation state
- `image_gen_models.dart` — Freezed data models for image generation
- `image_gen_constants.dart` — per-provider model / ratio / resolution tables (re-exported by the models file)
- `image_gen_capabilities.dart` — model classification: reference limits, allowed ratios and sizes, quality spelling
- `image_gen_settings_codec.dart` — settings JSON + migration off the per-provider reference lists
- `image_style_io.dart` — style-library JSON export / import
- `image_gen_http.dart` — HTTP client for image generation APIs
- Provider adapters: `routmy_image_provider.dart`, `openai_image_provider.dart` (also serves Electron Hub),
  `gemini_image_provider.dart`, `naistera_image_provider.dart`, `openrouter_image_provider.dart`,
  `a1111_image_provider.dart`
- UI: `widgets/image_gen_sheet.dart`, `widgets/image_content_renderer.dart`

### Image variants

Regenerating a picture appends to its block instead of replacing it: the block
keeps every image it has produced and the message shows one of them. The chat
formatter renders a small translucent `‹ n/N ›` switcher on the picture once a
block holds a second image; paging swaps the `<img>` in the page (every variant
is resolved to a servable URL up front) and reports the choice back through
`onImgVariant`, which rewrites the active swipe in place — no message swipe is
created for it (INV-IG7, INV-IG8).

### Reference handling

One reference library (`ImageGenSettings.references`) is shared by every
provider. Per request the collector takes the character avatar, the persona
avatar, the entries whose aliases match the prompt (or that are set to
`always`), then the recent generated images used as context — and clips the
result to what the active model accepts (`providerMaxReferences`). Providers
that cannot take references at all (AUTOMATIC1111, `dall-e-3`, Naistera
`novelai` / `grok-pro`) report 0 and the reference UI is hidden.

Protocol and capability tables are ported from
[sillyimages](https://github.com/0xl0cal/sillyimages).

---

## 9. Extensions (Info Blocks + JS Bridge SDK)

The extensions feature supports the Chat WebView bridge and sandboxed panels
that relay through it. Each visual chat owns its fully wired `JsBridgeService`:

1. **Post-generation block chain** — preset-driven infoblock / imageGen /
   jsRunner / interactive blocks that run after the assistant message
   is saved on the normal/regen path.
2. **JS Bridge SDK** (`window.glaze`) — extension authors can call
   `glaze.*` from the Chat WebView or sandboxed interactive panels.

Formal invariants: `docs/INVARIANTS.md` INV-EG1–INV-EG8 and
INV-JS1–INV-JS6.

### Block chain (post-generation)

Blocks within a preset are executed in `order` (ascending). Execution is **parallel by
default**; a block with `dependsOnPrevious = true` waits for the preceding block to
finish and receives its output as context (see INV-EG6).

| `dependsOnPrevious` | Behaviour |
|---|---|
| `false` (default) | Launched as a `Future`, not awaited — runs in parallel with adjacent blocks |
| `true` | `await`-ed; preceding block's `content` passed as `previousOutput` |

Each block result is stored as an `InfoBlock` row with its own primary-key `id`.
`(sessionId, messageId, swipeId, agentSwipeId)` are indexed coordinates used to
select the results for the visible message variant.
`BlockRunStatus` (`pending → running → done / error / stopped`) is updated atomically
per block via `InfoBlocksRepository.updateStatus()`.

### Block types

| `BlockType` | Handler | Notes |
|---|---|---|
| `infoblock` | `blocks/infoblock_handler.dart` | Calls `InfoBlockService`; injects last N results into prompt context |
| `imageGen` | `blocks/image_gen_block_handler.dart` | Reads `[img gen:…]` tag, calls `ImageGenService`, saves via `ImageStorageService`; result stored as an `<img data-iig-…>` element whose `src` is relative to the data root (INV-IG9) |
| `jsRunner` | `blocks/js_runner_block_handler.dart` | Runs JS through the Chat WebView via `JsBlockExecutor`; absent bridges produce a bounded unavailable error. |
| `interactive` | `blocks/interactive_block_handler.dart` | LLM → strip code-fence → sandboxed iframe island under the assistant message. JS inside the panel has access to `window.glaze.*` |

### Block triggers

| `BlockTrigger` | When it runs | What it can do |
|---|---|---|
| `afterAssistant` | `PostGenCoordinator`: background when Studio is off; `CleanerStage` after canonical swipe selection when Studio is on | all block types |
| `afterUser` | `ChatNotifier.sendMessage` (fire-and-forget `unawaited(_dispatchAfterUserBlocks(...))`) | all block types |
| `periodic` | `PeriodicTriggerScheduler` (`Timer.periodic(block.periodicIntervalSeconds)`) | `jsRunner` only — no supported bridge runtime is available without the Chat WebView |

The chain filter is enforced by `BlockProcessor` and `SingleBlockRunner`, with
`ExtensionPostGenService` kept as the public entrypoint. The same chain is reused
for `afterAssistant` (`runBlocksForMessage`) and `afterUser`
(`runAfterUserBlocks`). The periodic scheduler calls `runJsBlock()` directly —
no chain, no `InfoBlock` row, just a side-effect tick.

`afterUser` is fire-and-forget and races the main reply; that reply does not
await or consume its result. Under Studio, `afterAssistant` runs after
final/cleaned/partial selection and before Ledger, so persisted block rows bind
to the canonical `(swipeId, agentSwipeId)`.

### Periodic scheduler

`SessionLifecycleTracker` bootstraps `periodicTriggerSchedulerProvider` whenever
a visual chat is active. `PeriodicTriggerScheduler` watches
`extensionPresetsProvider` and `extensionsSettingsProvider`, and obtains the
real `charId` and `sessionId` from
`GenerationNotificationService.activeChatContext` for every tick. Execution is
authorized only while that same active-chat context remains current.

Periodic scripts require the active visual Chat WebView and its registered
bridge. If no active chat context or bridge exists, the tick is skipped; there
is no headless execution or headless fallback. Lifecycle pause/resume cancels
and recreates timers without catch-up ticks (INV-JS6).

### Cancellation

`ExtensionPostGenService` owns a `Set<CancelToken>` because `afterUser` and
`afterAssistant` chains may overlap. `cancelBlocks()` cancels every active
chain; `SingleBlockRunner` and each concrete handler check their token before
and after async work. Cancelled blocks are marked `stopped`. These tokens are
independent of the chat text-generation token (INV-EG5).

### Key configuration fields (`BlockConfig`)

| Field | Default | Meaning |
|---|---|---|
| `order` | 0 | Execution order (ascending) |
| `dependsOnPrevious` | false | Serial/parallel mode |
| `injectLastN` | 1 | Number of recent assistant messages eligible for injection; explicit 0 disables it |
| `inject` | false | Append stored block output to eligible assistant-message content in future prompts |
| `trigger` | `afterAssistant` | `afterAssistant` / `afterUser` / `periodic` |
| `periodicIntervalSeconds` | 60 | Tick interval when `trigger == periodic` |

### Capability permissions

Each extension preset carries a `PresetPermissions` freezed model with
19 capability toggles (default-deny except `showToast`). The immutable
`JsBridgeMethodRegistry` is the canonical public method set and records each
method's capability resolver plus Chat WebView host availability.
`JsBridgeService.dispatch` rejects unregistered methods, enforces the registered
capability through the injected `PermissionCheck`, and then selects the
registered operation. Supported-profile tests consume the registry's host sets. Production
wiring in `ChatWebViewWidget` reads `activePresetPermissionsProvider`.

| Capability | Bridge method |
|---|---|
| `read_chat_vars` / `write_chat_vars` / `delete_chat_vars` | `glaze.getVariables / setVariables / deleteVariable` (`scope: 'chat'`) |
| `read_character_vars` / `write_character_vars` / `delete_character_vars` | same (`scope: 'character'`) |
| `read_global_vars` / `write_global_vars` / `delete_global_vars` | same (`scope: 'global'`) |
| `read_message_vars` / `write_message_vars` / `delete_message_vars` | same (`scope: 'message'`) |
| `generate_text` | `glaze.generateText(prompt, { preset })` |
| `trigger_generation` | `glaze.triggerGeneration({ mode })` |
| `inject_prompt` / `uninject_prompt` | `glaze.injectPrompt / uninjectPrompt` |
| `play_audio` | `glaze.playAudio(source, options)` |
| `execute_command` | `glaze.executeCommand(command, args)` |
| `show_toast` (default ALLOW) | `glaze.showToast(message, { severity })` |

### Connection profiles

`ExtensionPreset.connectionProfiles` is a freezed record with three
`apiConfigId` slots: `big` / `medium` / `small`. `glaze.generateText({
preset })` reads the matching slot and resolves it via
`ConnectionProfileResolver` (falls through to the active API config
when the slot is empty or stale). The UI picker in
`preset_editor_screen.dart` lists every `ApiConfig` plus an
"Использовать основной" default.

### Prompt injection and swipe scope

Stored-output injection is opt-in (`inject=false` by default). When enabled,
`InfoBlockInjector` appends output to the content of the last N eligible
assistant messages; it does not create a separate system message. Selection is
aware of top-level `swipeId` but not `agentSwipeId`, so it is less strict than
the visible panel lookup when multiple Studio sub-swipes have stored outputs.

`glaze.injectPrompt` is separate: it creates an in-memory
`RuntimePromptBlock` with role/depth and capability checks. Runtime injections
are not persisted and disappear on restart.

### Variable scopes

JS variables use four scopes, each persisted or in-memory:

| Scope | Storage | Atomic repo |
|---|---|---|
| `chat` | `ChatSession.sessionVars['__glaze_variables']` (JSON string) | `ChatRepo.updateSessionVarsJson` |
| `character` | `Character.extensions['glaze_variables']` (Map) | `CharacterRepo.updateExtensionsJson` |
| `global` | `SharedPreferences['glaze.global_variables']` (JSON) | `GlobalVariablesRepo` (64 KiB cap, serialized writes) |
| `message` | in-memory `MessageVariablesNotifier` (per `sessionId` + `messageId`) | n/a |

JSON payload is validated (`_validateJsonValue` in `JsBridgeService`)
for type compatibility and ≤ 64 KiB total.

### Real audio backend

`AudioBridgeService` routes `glaze.playAudio(source, options)` to:

* `click` / `alert` / `haptic` — `SystemSound` / `HapticFeedback`
  (built-in cues; no audio player)
* `file://` / `http(s)://` URLs / absolute paths / `data:audio/…;base64,…` —
  `audioplayers` with the matching `Source` subclass
* `volume` (clamped 0..1) and `loop` options map to the player

`routeSource(source)` is a `@visibleForTesting` static helper that
returns the `Source` subclass (or `null` for built-in cues).

### JS execution

User-authored JS runs in a `<iframe sandbox="allow-scripts">` (without
`allow-same-origin`) — null origin, no access to `window.parent`,
`window.flutter_inappwebview`, or any API keys. The supported execution path is:

* **Visual WebView** — `ChatBridgeController.runJsBlock()` is used
  when the chat is open; the script is forwarded into the chat
  WebView's `assets/chat_webview/bridge/chat_bridge_controller.js`
  `runSandboxedScript()` path.
The retained headless engine assets are not a supported bridge profile or
fallback runtime. JS block runners never retry a script in another runtime;
when the Chat WebView is absent they return an explicit unavailable outcome.

### Dart files

* `extension_post_gen_service.dart` — public orchestrator entrypoint; owns the active cancel-token set; exposes `runBlocksForMessage`, `runAfterUserBlocks`, `runJsBlock`, `rerunBlock`, `rerunImageOnly`
* `blocks/block_processor.dart` — order/filter/`dependsOnPrevious` orchestration
* `blocks/single_block_runner.dart` — placeholder prep, context construction, handler dispatch, per-block error wrapping
* `blocks/block_status_tracker.dart` — placeholder/status/error/dedupe lifecycle
* `blocks/block_panel_updater.dart` — shared panel update/throttling plumbing
* `blocks/image_pixel_renderer.dart` — image bytes → persisted file/result token
* `blocks/js_block_executor.dart` — message-bound `jsRunner` execution through the Chat WebView
* `blocks/periodic_js_block_runner.dart` — active-chat-authorized periodic JS execution through the visual bridge
* `blocks/image_only_rerunner.dart` — manual image-only rerun validation/status update flow
* `blocks/*_block_handler.dart` — concrete `infoblock`, `imageGen`, `jsRunner`, `interactive` handlers
* `info_block_service.dart` — LLM call + prompt assembly for `infoblock` type
* `info_block_injector.dart` — inserts stored `InfoBlock` outputs into the prompt context
* `js_bridge_service.dart` — compatibility export for `js_bridge/js_bridge_service.dart`
* `js_bridge/js_bridge_service.dart` — pure dispatcher: `{ method, params, context }` → `{ ok, result/error }`; no Riverpod
* `js_bridge/js_bridge_method_registry.dart` — immutable canonical method set with operation, capability resolver, and supported-host metadata
* `js_bridge/handlers/*_handler.dart` — variables, generation, prompt injection, audio, commands, toast
* `js_bridge/capability_resolver.dart` + `permission_gate.dart` — method/scope capability mapping and default-deny enforcement
* `js_engine_service.dart` — retained unused headless-engine compatibility implementation
* `panel_host_service.dart` — singleton panel registry + resize/event broadcast streams
* `audio_bridge_service.dart` — `SystemSound` + `audioplayers` routing
* `command_registry.dart` — `/trigger` / `/getvar` / `/setvar` / `/inject` / `/toast` registry; `buildWiredCommandRegistry(WiredCommandDeps)` is the production default
* `js_bridge_toast_controller.dart` — severity-aware toast surface
* `periodic_trigger_scheduler.dart` — `WidgetsBindingObserver` + `Timer.periodic` for periodic blocks
* `connection_profile_resolver.dart` — `big` / `medium` / `small` → `ApiConfig` mapping
* `runtime_prompt_injection_service.dart` — session-scoped depth blocks separate from `InfoBlock`
* `state/message_variables_notifier.dart` — in-memory per-message variables
* `models/block_config.dart` — `BlockType` (`infoblock`/`imageGen`/`jsRunner`/`interactive`), `BlockTrigger` (`afterUser`/`afterAssistant`/`periodic`)
* `models/extension_preset.dart` — `blocks`, `permissions`, `connectionProfiles`
* `models/preset_permissions.dart` — `PresetPermissions` + `GlazeCapability` (19 values)
* `models/connection_profiles.dart` — `big` / `medium` / `small` mapping
* `models/trigger_mode.dart` — `continueGeneration` / `regenerate` / `auto`
* `models/trigger_result.dart` — sealed `TriggerResult`
* `core/db/repositories/global_variables_repo.dart` — SharedPreferences-backed
* DB: `ExtensionPresets`, `InfoBlocks` tables (v20; v22 adds `status` + `order` columns)

### WebView asset modules

Active chat WebView JS is loaded as ES modules from `assets/chat_webview/index.html`:

* `assets/chat_webview/glaze_sdk.js` — `window.glaze` SDK loaded before bridge bootstrap
* `assets/chat_webview/formatter/index.js` — exports/exposes `Formatter`; implementation in `formatter/formatter.js`, marker rendering in `formatter/text_format.js`
* `assets/chat_webview/renderer/index.js` — exports/exposes `Renderer`; message DOM in `renderer/message_renderer.js`, Shadow DOM CSS in `renderer/shadow_style.js`
* `assets/chat_webview/renderer/css_diagnostics.js` — reads the `<style>` blocks a settled message carries and appends a short `CSS ERROR` report (unclosed brace, unterminated comment/string, rules the engine ignored). Read-only: the CSS itself is still inserted verbatim
* `assets/chat_webview/bridge/index.js` — imports `Formatter` and `Renderer`, creates `window.bridge`, registers scaled wheel handling and `onWebViewReady`
* `assets/chat_webview/bridge/chat_bridge_controller.js` — main JS bridge facade, Flutter transport, message list API, ext-block panel, sandbox runner
* `assets/chat_webview/bridge/panel_host.js` — sandboxed interactive iframe lifecycle and `glaze:*` relay
* `assets/chat_webview/bridge/html_sanitizer.js` — two policies: message HTML is filtered for *code* only (`<script>`/`<iframe>`/`<object>`/`<embed>`, `on…=`, `srcdoc`, `javascript:` and non-image `data:` URLs) while its markup and CSS reach the shadow root verbatim, so a card renders the same with message scripts on and off; ExtBlock HTML keeps the strict element/attribute policy
* `assets/chat_webview/bridge/css_sanitizer.js` — CSS policy for **ExtBlock** HTML only (message CSS is never rewritten): `<style>` blocks and `style="…"` keep working, minus `url()`/`@import`/`expression()`/`position: fixed`; ExtBlock rules are scoped to `.ext-block-content` because they land in the light DOM, message rules are already scoped by the per-message shadow root
* `assets/chat_webview/headless.html` — retained unused headless-engine asset

Legacy single-file paths (`bridge.js`, `renderer.js`, `formatter.js`) are
compatibility markers only; `bridge.legacy.js` is the retained pre-module bridge
snapshot.

### Bridge integration

`ChatBridgeController` exposes:
- `updateBlockStatus(messageId, status?)` — pushes `⬡` badge update to WebView
- `showExtBlocksPanel(messageId, blocks)` — renders/removes inline block panel
- `runJsBlock(...)` — runs a user script in the sandboxed iframe
- `openInteractivePanel / closeInteractivePanel / postToInteractivePanel` — `BlockType.interactive` panel lifecycle
- Callbacks: `onExtBlocksClick`, `onExtBlockStop`, `onExtBlockRegen`, `onExtBlockRegenImage`, `onExtBlockEdit`, `onExtBlockDelete`, `onPanelResize`, `onPanelEvent`

`ChatMessageMapper` adds `blockStatus` (`'running' | 'done' | 'error' | null`) from
`ChatMessageMapperContext.blockStatusByMessageId`; the WebView renders a `⬡` badge in
the message header.

---

## 10. Known Design Issues

Open issues:

1. **`onboarding_service.dart`** — UI lives in `features/onboarding/onboarding_screen.dart`, but the service still imports `package:flutter/material.dart` for `BuildContext` and pushes via `rootNavigatorKey.currentState.push()`.

2. **Memory Graph (entity extraction + salience) — DISABLED.**
   `MemoryPostTurnService.runPostTurn` is a no-op: only the cadence counter
   is incremented; the entity graph + salience rebuild is commented out.
   The heuristic `MemoryEntityExtractor` relies on `[A-Z][a-z]` proper-noun
   detection which does not work for Cyrillic (Russian RP) — it produces
   garbage like "Encryption", "Non", "The" as character entities. The
   stoplist (~25 words) and preposition guards are insufficient compared
   to Lumiverse's ~150-word stoplist + adjective-follower filter + sentence
   -start position index + preposition attachment guard.
   Studio Ledger (LLM-based, writes `npc:Name.field`, `world:location`,
   etc. into `tracker_rows`) covers the same use case with much higher
   quality and is the canonical entity tracker going forward.
   The 4 graph tables (`memory_entity_rows`, `memory_salience_rows`,
   `memory_cadence_rows`, `memory_consolidation_rows`) remain in the DB
   for forward compatibility.
   **Reference for a future LLM-based rewrite:**
   [Lumiverse Memory Cortex](https://github.com/prolix-oc/Lumiverse/tree/main/src/services/memory-cortex)
   — heuristic Tier 1 + LLM sidecar Tier 2 with arbitration & grading.

Resolved (kept for history; details in git / PR notes):

- **magic_drawer_stats_service** — moved to `features/chat/services/`.
- **prompt_payload_builder split** — `prompt_inputs_collector` + `prompt_payload_assembler`.
- **chat_provider decomposition** — controllers + `generation_pipeline` + `saved_message_writer` (~420 lines; further splits possible).
- **lorebook_vector_search providers** — moved to `core/state/lorebook_embedding_provider.dart`.
- **Chat ↔ memory draft mutex** — `memory_active_drafts_provider` + `MemoryBookController` (INV-M3/INV-M4).
- **Session vars on abort/error** — only a successful guarded commit applies the
  isolate variable delta (INV-C5).
- **Memory injection token budget** — `memory_budget.dart` + INV-PS4.
- **JS extensions MVP** — `window.glaze` SDK, Chat WebView bridge, capability permissions, periodic/afterUser triggers, interactive panels, audioplayers-backed audio, big/medium/small connection profiles, wired `CommandRegistry`, lifecycle-paused periodic scheduler. Current module boundaries are documented in § 9.
- **`sync_engine.dart` decomposition** — `SyncBinaryAssetSyncer` (avatar/gallery push/pull) + `sync_image_stripper.dart` extracted; `saveLorebookActivations` injected as callback (removed provider-layer import from service).
- **`prompt_builder.dart` decomposition** — regex application extracted to `prompt_regex_applicator.dart`; deferred-memory finalization extracted to `_finalizeDeferredMemory()`.
- **`image_gen_service.dart` decomposition** — `[IMG:*]` tag-markup text transforms extracted to `image_tag_markup.dart` (`ImageTagMarkup`).
- **`memory_injection_service.dart` arch fix** — removed `Ref` dependency; `MemoryGlobalSettings` injected via callback.
- **`prompt_worker.dart` decomposition** — isolate-boundary JSON codec extracted to `prompt_worker_codec.dart`.
- **Triplicated memory formatting helpers** — `_formatMemoryItems` / `_formatMemoryRange` deduplicated to `memory_formatting.dart`.
- **Studio decomposition (Phases 1-11)** — data classes and specialists were
  extracted from the large Studio/chat services into `prompt/`, `cleaner/`,
  `studio/`, `memory/`, `ledger/`, and `shared/` subdirectories. `AgentRunner`,
  `ControllerBatcher`, summary, embedding rebuild, and turn-config composition now
  live behind state/provider boundaries. `MemoryStudioService`,
  `PromptInputsCollector`, and `PromptPayloadBuilder` still receive `Ref` for
  core provider access, while feature adapters are injected. `AuxLlmClient` has
  a `const` constructor, and `StudioFinalRunResult` was merged into
  `AgentRunResult`. UI decomposition follows `CODE_STYLE.md`: extract business
  logic and distinct screens, not arbitrary private widgets.
