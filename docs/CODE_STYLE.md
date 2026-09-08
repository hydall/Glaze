# Code Style

Rules for code organization and decomposition.

## No God Objects — Parallel Decomposition

Every class/file must have a **single responsibility**. When a class grows beyond ~200-250 lines or takes on more than one logical role, consider splitting.

### Rules

1. **One class = one job.** If the class name needs "and" to describe it (`CharacterImportAndNormalization`), it's two classes.
2. **Thin orchestrator, fat specialists.** The top-level class (e.g. `PromptBuilder`) only calls other classes in order — it contains zero business logic itself. All logic lives in focused components below.
3. **Split when it hurts.** When adding a new feature to an existing file, check: does it belong there, or does it need its own file? If the file is already >250 lines **and** the new logic is clearly separable, extract. Don't split just to hit an arbitrary line count.
4. **No circular dependencies.** Lower layers never import from higher layers. Direction: `UI → Providers → Services/Repos → Models/DB`. Data flows down, events flow up.
5. **Extract during implementation, not after.** If while writing a method you realize "this chunk could be its own class," extract it immediately. Don't leave a TODO to refactor later.
6. **Constructor injection only.** Dependencies are passed in, not looked up. This keeps classes testable and boundaries visible.

### Architecture Layers (Dependency Direction ↓)

```
UI (screens/widgets)
  → Providers (Riverpod state + actions)
    → Services (orchestrators: PromptBuilder, CharacterImporter)
      → Components (specialists: MacroEngine, TokenEstimator, HistoryAssembler)
        → Models (Freezed data classes)
        → Repos (Drift abstraction)
```

A component may only import from layers at its level or below. Never upward.

## UI Files — Only Extract Logic

Large UI files are acceptable. A 800-line screen with private widgets (`_HeroSection`, `_TabsRow`, etc.) is fine — these widgets share context and are read as a whole.

**What to extract from UI files:**
- Business logic (LLM calls, repo access, file I/O, data transformation) → move to a service or provider
- State that belongs in a provider (computed stats, persisted preferences) → move to a Riverpod provider

**When splitting UI into separate files IS justified:**
- The widget is reused across multiple screens → move to `shared/widgets/`
- The section is a distinct sub-screen with its own state and navigation (e.g. a complex dialog or sheet)

**What NOT to extract:**
- Private helper widgets — they belong with their screen
- Layout helpers, color constants, text styles — these are UI concerns
- Callback handlers that only call `ref.read(someProvider.notifier).action()` — these are already thin

Rule of thumb: if removing the business logic leaves a file with only `build()` methods and `Widget` returns, it's done. Don't split further.

## Refactor Patterns

Use these concrete patterns when a file crosses the line from cohesive to hard to
review:

| Problem | Preferred shape | Example |
|---|---|---|
| Public service accumulated many private helpers | Keep a thin public orchestrator; move domain steps into injected specialists | `ExtensionPostGenService` delegates block order, status, image rendering, JS fallback, and rerun flows to `services/blocks/` |
| Bridge dispatcher grew one method per capability | Keep one dispatcher and group handlers by domain, not by tiny method | `js_bridge/js_bridge_service.dart` dispatches to `handlers/variables_handler.dart`, `generation_handler.dart`, etc. |
| Widget owns lifecycle plus bridge callbacks/listeners | Keep lifecycle in the widget; extract callback/listener/sync objects with explicit dependencies | `chat_webview_widget.dart` delegates init, build listeners, sync dispatch, panel refresh, and callback wiring |
| Screen has independent sections/dialogs | Move distinct sections and complex dialogs under a feature subdirectory; keep old import path as an export only when needed | `preset_editor_screen.dart` exports `screens/preset_editor/preset_editor_screen.dart`, sections live under `screens/preset_editor/sections/` |
| WebView script became a god-file | Use ES module entrypoints that expose the same `window.*` compatibility surface | `bridge/index.js`, `renderer/index.js`, and `formatter/index.js` import focused modules and assign `window.Bridge` / `window.Renderer` / `window.Formatter` |
| Service mixes orchestration with pure text transforms | Extract the pure transforms to a static helper class; the service delegates | `image_gen_service.dart` delegates `[IMG:*]` tag parsing/rewriting to `image_tag_markup.dart` (`ImageTagMarkup`) |
| Giant function does assembly + side-effect passes | Extract each pass to a named top-level function or specialist; the orchestrator calls them in order | `prompt_builder.dart` `_assembleMessages` delegates regex application to `prompt_regex_applicator.dart` and memory finalization to `_finalizeDeferredMemory()` |
| God-object service accumulates multiple domains | Extract cohesive domain clusters into separate classes; inject them via constructor | `sync_engine.dart` delegates binary asset sync to `sync_binary_asset_syncer.dart` and image stripping to `sync_image_stripper.dart` |
| Component depends on Riverpod `Ref` (upward dependency) | Inject the needed value/callback via constructor; wire from the provider layer | `MemoryInjectionService` takes `MemoryGlobalSettings Function()` instead of `Ref`; `AuxLlmClient` is `const AuxLlmClient()` with no `Ref` at all |
| God-file service mixes multiple domains | Extract cohesive domain clusters into `subdir/` specialists; keep the original file as a thin orchestrator + re-export barrel | `prompt_builder.dart` delegates to `prompt/lorebook_classifier.dart`, `prompt/memory_block_injector.dart`, etc.; `post_cleaner_service.dart` delegates to `cleaner/cleaner_prompt_builder.dart`, `cleaner/audit_prompt_builder.dart` |
| Duplicate Result classes with identical shapes | Merge into the canonical class; delete the duplicate | `StudioFinalRunResult` (3 fields: text/reasoning/rawResponseJson) merged into the identical `AgentRunResult` |
| Duplicate utility logic across services | Extract to a shared static helper in `shared/` or a `ModelFetcher`-style class | `message_range_formatter.dart` unifies `_formatMessageRange`; `ModelFetcher.fetchModelIds()` deduplicates `fetchModels` + sort + fallback logic |
| UI file mixes business logic with widget code | Extract business logic to controller/service; extract distinct sub-screens/dialogs to separate files; keep private widgets inline | `agentic_operations_log_dialog.dart` delegates tabs to `agentic_operations_tab.dart` etc.; `MemoryBookController.runDedup()` encapsulates dedup logic from `memory_books_sheet.dart` |

Avoid creating one class per tiny function. Prefer a few domain files with clear
ownership over many shallow wrappers.

## Code Rules

Key patterns to follow when editing:

- **Generation:** always use a `genId` (or `CancelToken`) to guard against stale completions writing to state after abort/regen. Check that the active generation ID still matches before applying any async result to state.
- **Race conditions:** verify state identity before async operations complete, especially after user actions that invalidate pending work.
- **Database:** go through Drift repos; never write raw SQL outside of repo classes.
- **Riverpod:** prefer `ref.watch` in build, `ref.read` in callbacks; never call `ref.read` at provider build time for side effects.
