# Periodic extensions use the active chat

## Context

Periodic extensions need an authority boundary before a scheduler can run.
Executing against a background, previously selected, or global chat could make
user-visible state change unexpectedly.

## Decision

Periodic extensions are authorized only for the chat currently visible to the
user. They must not run for inactive chats.

## Consequences

- The scheduler must resolve and verify the active user-visible chat before
  extension execution.
- Switching away from a chat removes periodic-extension authority for that
  chat.
- SQLite runtime replacement and relational message storage are separate work.
