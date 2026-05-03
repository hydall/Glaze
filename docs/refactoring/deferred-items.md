# Deferred Refactoring Items

Known gaps and deferred work from completed phases.

## From Phase 8 — ChatView Decomposition

- `openChat()` (~400 lines) extraction — deferred due to ~30+ dependency injections. ChatView already under 2000 lines.
- Context/tokenizer sheet actions (~32 lines) — too small for dedicated composable
- `useMemorySheetUI.js` (844 lines) — ~600 lines of imperative DOM; only meaningful fix is Vue-template rewrite, out of scope

## From Phase 9 — State Ownership

- `themeState.js` (1224 lines) — mixes reactive state, DOM injection, font management, preset CRUD, DB persistence, localStorage migration. Violates State ≠ service guard rail.
- `lorebooks`, `personas`, `presets`, `activePersona`, `catalogResults` — projection state mutated directly instead of via events. Low-ROI: load-once projections, not real-time derived state.

## From Phase 11 — Hollow Entrypoints

- `generateChat.js` still delegates to `generationService.js` as middleman. `generateSummary` and `generateMemoryDraft` are now real entrypoints; `generateChat` should follow.

## Remaining Decomposition Targets

- `themeState.js` split into `themeState.js` (state) + `themePersistence.js` (preset CRUD) + `themeRenderer.js` (DOM/CSS) + `themeMigration.js` (legacy migration)
- Memory normalization dedup: three independent implementations (`db.js:normalizeChatData`, `memoryBooksService.js:ensureSessionMemoryBook`, `chatImporter.js:createEmptyMemoryCoverage`) have drifted (`vectorSearchEnabled` defaults differ)

## Dead Code Events

Five event names have listeners but no dispatches: `header-setup-generation`, `header-update-session`, `change-generation-tab`, `open-item-editor`, `open-holocards`. Not removed to avoid breaking changes if dispatches are added dynamically.

## TDZ-Sensitive Initialization

Phase 15 (harden initialization order) not started. After patchChatData migration, new callback patterns add `let` captures outside `patchChatData` callbacks — potential TDZ source if composable instantiation order changes.
