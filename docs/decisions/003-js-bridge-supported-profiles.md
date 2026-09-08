# JS bridge supports Chat WebView and sandboxed panel profiles

## Context

The JS bridge has different execution profiles with different host services.
Making every optional service dependency required before deciding which profiles
are supported would port dependencies for runtimes Glaze does not support.

## Decision

The supported JS bridge profiles are Chat WebView and sandboxed panel. The
headless engine is not a supported profile. Required dependency ports are
guided by the services needed by the two supported profiles.

## Consequences

- Bridge dependency ports must support Chat WebView and sandboxed-panel calls.
- The headless engine does not define required bridge dependencies or
compatibility behavior.
- SQLite runtime replacement and relational message storage are separate work.
