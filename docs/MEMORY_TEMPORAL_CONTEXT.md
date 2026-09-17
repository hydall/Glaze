# Historical memory context

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

## Boundaries of this increment

This increment adds framing and reads existing historical evidence. It does not
introduce typed occurrence ranges, immutable Memory Book revisions, a complete
per-message version manifest for approved summaries, or character audience ACLs.
Source-ID containment for a summary does not prove that its prose still matches
every selected swipe. Those checks belong to the next source-integrity phase.

Scene detection, automatic continuity digests, and a provider-wide request budget
manager remain separate work. The memory cap here is measured using the existing
token estimator, not provider billing tokens.

## Verification

Regression coverage includes partial and unknown clocks, historical beliefs,
alive-then/dead-now framing, all three packing modes, tiny budgets, memory macro
placement, Raw Recall source edits, historical card and lorebook checkpoints,
future fact supersession, reconciliation cleanup, and request-prefix collection.
