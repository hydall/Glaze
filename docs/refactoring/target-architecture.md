# Target Architecture

## Purpose

Make the codebase:
- hard to break during refactors
- easier to extend without editing core files every time
- less dependent on god-objects
- suitable for experimental feature work without turning the app into a pile of special cases

## Target Model

```text
UI
  -> Use Cases
    -> Ordered Pipelines
      -> Transport

Side effects / observers
  <- Event Hub <- Use Cases / Pipelines
```

- **UI** gathers user intent and renders state
- **Use Cases** own actions (chat generation, summary, memory draft)
- **Ordered Pipelines** preserve correctness-critical ordering
- **Event Hub** carries domain facts, does not replace orchestration
- **Reactive State Modules** store read models for UI
- **Plugins/Extensions** react only through declared extension points

Short version: use cases decide, pipelines guarantee order, events broadcast facts, stores expose read models, plugins attach at controlled boundaries.

## Hybrid, Not Pure EDA

Do not move to pure event-driven architecture. The correct split:

- **EDA for** extensions, side effects, UI coordination, notifications, sync refresh, plugins
- **Ordered pipelines for** prompt block ordering, request ownership, abort rules, macro/regex/lore/vector/memory insertion order, transport completion, lifecycle cleanup

## Event Rules

1. **Separate categories**: `ui.*`, `nav.*`, `domain.generation.*`, `domain.memory.*`, `domain.sync.*`, `infra.request.*`, `debug.*`
2. **Define contracts**: event name constants, creator helpers, JSDoc typedefs
3. **Keep the bus dumb**: publish/subscribe/unsubscribe only. No business logic, no reordering, no hidden mutations
4. **`window` as compatibility bridge only**: internal events use `publishAppEvent`/`subscribeAppEvent`

## Pipeline Rules

1. **Explicit context objects**: each flow has a single `GenerationContext` tracking all state
2. **One job per step**: small, named after what they decide or enrich
3. **Named extension points**: `beforePromptBuild`, `afterPromptBuild`, `beforeRequestAssembly`, `beforeRequestSend`, `afterResponseNormalize`, `afterGenerationCommit`

## Database Rules

1. **`patchChatData` for all read-mutate-write** — never `getChatData` + `saveChat` (race condition)
2. **`patchChatDataBatch` for multiple fields** — single read, multiple mutations, single write
3. **`queueDbWrite` serializes all writes** — prevents concurrent IDB writes from interleaving
4. **`saveChat` only for full replacement** — creating new data, reset, sync, import

## Safety Rules

1. One responsibility move per PR
2. Every structural PR proves parity (tests, build, manual checklist)
3. Keep compatibility adapters during migration
4. Do not move unstable domains too early (MemoryBooks, vectorization)

## Success Criteria

- Adding a feature does not require editing the main chat view and one giant service file
- Request ownership and abort behavior are explicit and race-safe
- Prompt assembly remains deterministic and documented
- Event usage is structured and contract-based
- Debug and preview state are scoped, not singleton-global
- Plugins/extensions can be added at declared hooks
- Transport, prompt, UI, and state concerns each have a clear home
