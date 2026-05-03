# Vue Component Rules

Rules for writing and refactoring Vue components and composables.

## Size limits

- **400-line hard limit** on `<script setup>` — if exceeded, extract a composable first
- No exceptions without documented justification in AGENTS.md

## Composable extraction

- **One concern per composable** — no "and" in composable names; split instead
  - `usePresetEditor.js` (2080 lines, god-object) → 11 composables with max 177 lines each
  - `useAppNavigation.js`, `useEditorController.js`, etc.
- **State ≠ service** — `*State.js` files contain state + CRUD only; search/embedding/orchestration goes in a service
- **No circular service delegation** — use-cases must not delegate to a service that imports back from use-cases

## Known traps

### Sheet trap
Sheets mix UI + CRUD + validation + status. Extract business logic into composables before script hits 400 lines.

### Settings trap
Settings views with multiple sub-domains (API, embedding, image gen) get composables per domain.

### Template ≠ logic
Never extract sub-components just for line count if it requires prop-drilling. Prop-drilling is worse than a long script.

## Directory conventions

```
src/composables/
  api/         — API/runtime config composables
  app/         — App-level init, event subscriptions, onboarding
  character/   — Character editor, thumbnails, import/export
  chat/        — Chat generation, context, memory, message selection, auto-sync
  lorebook/    — Lorebook vector status, embedding logic
  theme/       — Theme presets, settings, renderer
  ui/          — Header, glossary, viewer composables

src/core/states/   — Reactive state modules (state + CRUD only)
src/core/services/  — Business logic services
src/views/          — Page-level components (composable wiring)
```

## Event system

- ALL internal events use `publishAppEvent()` / `subscribeAppEvent()` — never `window.dispatchEvent`
- Cancelable events use `publishCancelableAppEvent()` with `preventDefault()` semantics
- Unsubscriptions in `onBeforeUnmount` (Vue) or app lifetime (services/utils)
- Event catalog: 56 events across 4 namespaces (`nav.*`, `domain.*`, `debug.*`, `ui.*`)

## ChatView.vue exception

ChatView.vue (~1705 script lines) is a known exception to the 400-line rule. Further extraction would cause prop-drilling due to 30+ shared dependencies. `openChat()` (~400 lines) remains due to high dependency count. This is acknowledged tech debt.

## Async operation lifecycle

**RULE: Components MUST NOT abort long-running async operations in `onUnmounted`/`onBeforeUnmount`.**

This is enforced by the `glaze/no-abort-in-unmount` ESLint rule. Violations cause a build error.

### What `onUnmounted` MAY do
- Unsubscribe from event listeners (`unsubscribeAppEvent`)
- Null out UI callback references (`state.onUIUpdate = null`)
- Clear render-only timers (debounce, scroll, animation)
- Set flags (`isMounted = false`)

### What `onUnmounted` MUST NOT do
- Call `.abort()` on any `AbortController`
- Call `clearGenerationState()` or equivalent registry cleanup
- Kill HTTP fetch connections
- Delete state that async completion handlers need

### The principle: unsubscribe ≠ abort
When a component unmounts, it **disconnects from results**, not **cancels the operation**. The operation continues in the background, writing to DB through service-layer paths. When the user returns, data is loaded from DB.

### Ownership model
- **Service layer** (`*State.js`, `*Service.js`) owns the operation lifecycle: start, progress, completion, cleanup
- **Component layer** owns the UI subscription: render, scroll, local state updates
- Component subscribes via `onUIUpdate` callback; unsubscribes by setting `onUIUpdate = null`
- Only explicit user action (stop button) triggers `.abort()` via service-layer abort function

### Mobile background note
On iOS/Android, JS is suspended 1-5 seconds after the app goes to background. This cannot be fixed architecturally. The strategy is:
1. `visibilitychange` handler saves intermediate state to DB before suspension
2. On app return, state is restored from DB and operations are checked for completion
3. In-progress operations that were suspended may need restart — this is handled by the service layer, not the component
