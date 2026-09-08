# Memory Graph disabled is inactive

## Context

Memory Graph has persisted data and separate build and retrieval paths. A
disabled setting must not leave graph-derived context in generation through an
older index or an experimental read path.

## Decision

When Memory Graph is disabled, Glaze does not build graph data and does not
read graph data during generation. Existing stored graph data is ignored while
the feature remains disabled.

## Consequences

- Disabling the feature prevents graph work and graph-derived prompt context.
- Re-enabling may use data according to its own lifecycle rules; this decision
  does not require deleting stored graph data.
- SQLite runtime replacement and relational message storage are separate work.
