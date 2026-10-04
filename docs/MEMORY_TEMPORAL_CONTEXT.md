# Historical memory context

> Roadmap decision (2026-09-18): runtime source policing was reduced because
> historical source edits have low expected ROI. Automatic repair/maintenance,
> source-status badges, and history-browser UI are frozen. The revised planning
> document is
> `docs/untracked/TEMPORAL_MEMORY_EDITING_DESIGN.md` (local, gitignored).

Memory Books describe episodes at their source story time. Current Ledger and
Character Knowledge describe the applicable state at the generation boundary.
An NPC being alive in an earlier episode and dead later is chronology, not a
reason to rewrite the episode.

## Prompt and budget contract

- Both dedicated Memory Book blocks and memory macros contain the historical
  interpretation contract and the request's current story point.
- Each selected entry includes its existing `ledgerRange`, or an explicit
  unknown-time marker. Partial current clocks preserve only known components;
  device time and entry creation time are not substitutes.
- Raw Recall receives the same historical framing. Its text retains the
  distinction between dialogue, beliefs, and objective events.
- A shared packer measures the expanded Memory Book block, including headings
  and any summary excerpt. It repacks excerpts and removes the lowest-scoring
  remaining items until a positive memory budget fits. The legacy first-entry
  fallback cannot bypass that final cap. Null and zero budgets remain uncapped.
- Temporal headings are formatted at injection time, not written into memory
  bodies or embedding payloads.

## Regeneration boundary

When a regeneration target is supplied, the durable session determines the
ordered prefix before that target, including the selected swipe and agent swipe.

- Ledger uses the nearest committed snapshot matching a selected prefix anchor,
  with the initial game clock as the bootstrap fallback. Live manual controls
  and the present-day clock are not used as historical state.
- Card state uses the surviving session canon checkpoint and immutable character
  revision. Session lorebook revisions are resolved against that checkpoint.
  An ambiguous historical card lineage without a mappable baseline is rejected.
- Knowledge is reconstructed in memory: later reconciliation effects and
  cleanup are unwound, and facts superseded only by later sources can become
  eligible again. These reads do not modify current database state.
- Memory candidates must have nonempty source message IDs wholly inside the
  prefix. Unanchored legacy entries are omitted from historical retrieval.
- Raw Recall filters sources before ranking and compares stored text fingerprints
  with the selected source text. Missing, hidden, edited, or changed-swipe source
  text cannot reuse an old embedded excerpt.
- The unversioned session summary and entity index are omitted for historical
  generation. User configuration, extension instructions, and macro variables
  remain current configuration; this is not a snapshot of all application inputs.

## Immutable text revisions

- Entries carry an append-only list of text snapshots and an `activeRevisionId`.
  The current title, body, keys, paragraph offsets, and source-time label must
  match the final snapshot. Retrieval omits inconsistent projections.
- Old entries receive a synthetic first revision without changing their text.
  JSON export/import and chat branches preserve existing snapshots.
- Each snapshot records its source IDs/manifest, author, reason, creation time,
  and reviewer metadata where applicable. Source invalidation and swipe-index
  maintenance affect current eligibility, not the evidence stored in old snapshots.
- Manual edits use an atomic expected-entry check. A stale editor cannot replace
  newer content. Generic book saves also preserve the existing history and append
  changed text; they cannot replace an existing snapshot.
- Restoring a revision appends a new reviewed snapshot, even when its text matches
  the current body. It does not move the active pointer backwards. Restoration
  copies text only and cannot reactivate invalidated source evidence.
- The existing editor saves revisions automatically. Revision restoration is
  available through the repository/controller API; a history-browser UI remains
  separate. Explicit entry deletion retains its existing deletion semantics.

## Boundaries of this increment

The temporal increment adds framing and reads existing historical evidence.
Generated and approved summaries retain per-message source manifests, including
swipe and content fingerprints. Generation keeps cancellation and operation
ownership checks, while approval atomically verifies the expected draft; neither
path repeatedly rescans old source text. Historical regeneration validates its
bounded source prefix, and Raw Recall validates the exact stored text it reuses.

Ordinary forward retrieval does not repeatedly hash old chat messages. Before a
prepared request is sent, it only verifies that the exact selected MemoryBook
entries remain active and unchanged; this is an asynchronous ownership guard,
not historical source policing. Records already durably invalidated by message
or swipe deletion remain auditable and excluded from retrieval. Legacy entries
without a manifest retain normal non-historical compatibility behavior. A
manifest proves source identity and content, not that the summary itself is
semantically correct.

Typed occurrence ranges and character audience ACLs are still separate work.

Scene detection, automatic continuity digests, and a provider-wide request budget
manager remain separate work. The memory cap here is measured using the existing
token estimator, not provider billing tokens.

Manual consolidation is also separate planned work. One explicit run may inspect
at most 10 sequential active entries, produce a reviewable draft, and apply only
with an immutable before/after snapshot that supports rollback and branch-safe
copying. No consolidation model call or automatic trigger is part of this branch.

## Verification

Regression coverage includes partial and unknown clocks, historical beliefs,
alive-then/dead-now framing, all three packing modes, tiny budgets, memory macro
placement, Raw Recall source edits, historical card and lorebook checkpoints,
future fact supersession, reconciliation cleanup, request-prefix collection,
legacy revision migration, immutable history, stale editor rejection, and
restoration as a new revision.
