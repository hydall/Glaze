# Refactoring follow-ups

The correctness and mechanical refactoring work from the audit is complete.
The following items require evidence or a product/architecture decision before
implementation.

## Measure first

- Benchmark incremental chat-embedding manifests against the current bulk hash
  reconciliation before adding persistent watermark metadata.
- Capture long-history and large-lorebook prompt benchmarks before merging
  lorebook scans, reducing isolate payloads, or changing coverage computation.
- Profile chat and WebView rebuild/platform-view creation counts on Windows and
  mobile before narrowing subscriptions or splitting the widget tree.
- Keep the streaming parser's exhaustive split-boundary tests; add a 100k input
  benchmark when the repository establishes a benchmark harness.

## Decide first

- Memory Graph: decide whether disabled graph building also forbids graph reads
  during generation, or whether reads remain an experimental compatibility path.
- Periodic extensions: choose active-chat, explicitly configured chat, or
  global-only authority before enabling the scheduler.
- Chat storage: evaluate relational messages as a separate migration and sync
  compatibility project, not as part of incremental indexing work.
- SQLite runtime: evaluate replacement of the EOL dependency independently from
  repository refactoring and schema changes.
- JS bridge ports: decide supported bridge profiles before making every currently
  nullable service dependency constructor-required.

Each follow-up should begin with a focused decision record or baseline
measurement and land independently from behavioral fixes.
