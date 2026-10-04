# Bug-triage agent

A daily, **read-only** agent that keeps the Trello board in sync with the Discord
bug-report forum and drops an AI audit on each open bug. It **never** changes
code or opens PRs — it only creates Trello cards and posts comments for a human
to act on.

Screenshots are part of the report now: reports that carry pictures are audited
by DeepSeek's multimodal model (`deepseek-v4-flash-vision-exp`), which reads
error dialogs, stack traces and UI state straight off the image. Text-only
reports stay on the cheaper text model.

The Discord forum is still the primary queue, but it is no longer the only one.
After the forum is mirrored and audited, the board itself is swept twice: for
cards whose earlier audit gave up on a screenshot, and for cards nobody mirrored
from Discord at all.

## What it does (once per day)

1. Fetches Discord forum posts (active + archived-public threads) via the REST
   API — no persistent gateway connection. **Closed posts are skipped**: locked
   threads, archived (closed) threads, and posts carrying an ignored forum tag.
   Note Discord also auto-archives inactive posts, so a quiet-but-open report is
   dropped too; set `DISCORD_SKIP_ARCHIVED=false` to triage those as well.
   Image attachments and image embeds are collected as links; the bytes are
   downloaded later and only for the reports that actually reach an audit.
2. Fetches the Trello cards once and indexes them by their
   `discord-thread:<id>` marker.
3. For any Discord post **not yet linked to a card**, checks whether the board
   already tracks that same bug: one DeepSeek call compares the thread against
   the existing cards — both the ones a human typed in and the ones earlier
   forum threads produced, including cards created moments ago in the same run.
   On a match it appends the hidden marker + Discord back-link to that card
   (the existing text is never overwritten) and **creates no duplicate**;
   otherwise it creates a card in the "new bugs" list. Candidates are shown to
   the model oldest first and it is told to pick the smallest matching number,
   so a second report always joins **the card that reported the bug first**.
   The matcher is deliberately conservative: below 0.7 confidence it answers
   "no match", because a missed link only costs a duplicate a human can merge,
   while a wrong link hangs a thread on an unrelated card. This step is
   text-only — it compares wording, not pictures. Set
   `MATCH_EXISTING_CARDS=false` to skip the check entirely.
4. If none of the three audit passes below has anything to do, **exits before
   calling the LLM** (no token spend).
5. **Pass 1 — the forum.** For each open thread whose card lacks the `audited`
   label, runs a DeepSeek agent over that ONE report — title, original post,
   replies and attached images, read live from Discord — that greps / reads the
   source, then posts a structured audit as a comment on the thread's card and
   applies the label. A card that collected several duplicate threads is
   audited once, on the first of them.
6. **Pass 2 — the image backlog.** Walks the audit lists for cards whose recorded
   verdict was "could not judge this, it's a screenshot" and audits them again
   with the pictures attached. This is what drains the reports the text-only era
   could only answer with NEED MORE INFO. The pass retires itself per card: once
   a vision verdict exists, that card is never re-opened by it again, so a
   report that is genuinely missing information is asked once, not daily.
7. **Pass 3 — the rest of the audit lists.** Cards with no `discord-thread:`
   marker and no `audited` label — the ones a human typed straight onto the
   board — are audited from their title, description, comments and attached
   images, then labelled. Cards already carrying an audit comment are left
   alone.

Both board passes are **scoped to `TRELLO_AUDIT_LIST_IDS`** — the new-bug list
unless that variable is set. A card in any other column (Ideas, Feature
requests, Done, Released…) is read as an index entry and nothing more: it can
link a Discord thread and it can win a duplicate lookup, but the passes never
audit it, comment on it or label it. `TRELLO_SKIP_LIST_IDS` is the subtractive
filter on top, only useful when the allowlist spans several columns. Pass 1 is
driven by the forum, not by the board, so a thread's own card is audited
wherever on the board it sits.

A report with no readable text **and** no readable picture still skips the LLM
entirely and gets a NEED MORE INFO comment naming what to ask.

De-dup has no external database: each card that tracks a thread carries a hidden
`discord-thread:<id>` marker in its description, and that's the source of truth.
A card can carry **several** markers — that is what a duplicate looks like on the
board. Cards written by hand get their first marker when the matcher recognises
their bug in the forum, and behave like mirrored ones from then on.

Every comment the agent posts ends with a second hidden marker recording how
that audit went:

```
glaze-triage:v2 mode=vision images=3 blocked=no
```

`mode` is the model that judged it (`text` / `vision` / `none`), `images` is how
many pictures reached it, and `blocked=yes` means "this is a request for
information, not a verdict". That line is what pass 2 reads to find its work.
Comments written before the marker existed are recognised by their headline, so
the existing backlog is picked up too.

**The audited source is always `nightly`.** The workflow checks the triage code
out from the branch the run was started on, and `nightly` separately into
`audit-src/`, which is what the agent greps and reads (`AUDIT_REPO_ROOT`).
Scheduled runs fire only from the default branch (`stable`), which trails
nightly by hundreds of commits — auditing that tree would judge reports against
code the fix has long since left.

## Architecture

Two steps are agentic (both DeepSeek, via Pydantic AI): the **audit**
(`search_code`/`read_file` tools over the checked-out repo) and the
**duplicate check** (no tools — it only compares text, and only for threads
that have no card yet). Polling, card creation, image fetching and marker-based
de-dup are plain deterministic code — cheaper and more reliable than handing
those to the model.

```
triage.py         orchestrator: fetch, mirror, early-exit, run the three passes
config.py         env-var loading (fails fast on missing secrets)
discord_client.py read-only forum access (REST) + image links
trello_client.py  cards / comments / attachments / labels (source of truth)
images.py         image refs + download, format sniffing, size and count caps
subjects.py       one shape for "the report under audit", card or thread
mirror.py         Discord -> Trello: link to an existing card, or create one
matcher.py        "is this bug already a card?" — DeepSeek, no tools
auditor.py        Pydantic AI agents (text + vision) + structured BugAudit
runner.py         audits one subject: load images, pick the model, fall back
audit_pass.py     the three passes and their shared commit path
audit_comment.py  what gets written on a card, and how a later run reads it back
test_triage.py    unit tests (stdlib unittest, no network) — run in CI
```

### Which model judges what

| Report | Model | Why |
|--------|-------|-----|
| Text, no pictures | `DEEPSEEK_MODEL` | Cheaper; there is nothing to look at. |
| Any readable picture | `DEEPSEEK_VISION_MODEL` | Images are attached to the message as base64 parts. |
| Vision call fails | `DEEPSEEK_MODEL` | One retry without the images — a bad day on an experimental endpoint costs a weaker audit, not a lost report. |
| No text and no readable picture | none | NEED MORE INFO, no tokens spent. |

Each image costs up to 384 tokens, so `MAX_IMAGES_PER_AUDIT` (default 4) caps
how many of a report's pictures are shown. Only JPEG, PNG, GIF and WebP are
sent, and the format is sniffed from the bytes rather than trusted from the file
name.

## Secrets & variables (GitHub → Settings)

**Secrets** (`Settings → Secrets and variables → Actions → Secrets`):

| Name | What |
|------|------|
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `TRELLO_KEY` / `TRELLO_TOKEN` | Trello API key + token |
| `DISCORD_BOT_TOKEN` | Bot token (scope `bot`, perms: Read Messages, Read Message History) |

**Variables** (`… → Variables`) — non-secret IDs:

| Name | What | Default |
|------|------|---------|
| `DEEPSEEK_MODEL` | model id for text-only reports | `deepseek-chat` |
| `DEEPSEEK_VISION_MODEL` | model id for reports with pictures | `deepseek-v4-flash-vision-exp` |
| `TRELLO_BOARD_ID` | main board id | — |
| `TRELLO_NEW_BUG_LIST_ID` | list where new bugs land | — |
| `TRELLO_AUDITED_LABEL_ID` | label id meaning "AI audited" | — |
| `TRELLO_AUDIT_LIST_IDS` | the only lists passes 2 and 3 audit (comma-separated) | the new-bug list |
| `TRELLO_SKIP_LIST_IDS` | lists dropped from that scope (comma-separated) | empty |
| `DISCORD_GUILD_ID` | your server id | — |
| `DISCORD_FORUM_CHANNEL_ID` | the bug-report forum channel id | — |
| `DISCORD_IGNORED_TAG_IDS` | forum tag ids meaning closed (comma-separated) | empty |
| `DISCORD_SKIP_ARCHIVED` | treat archived threads as closed | `true` |
| `MATCH_EXISTING_CARDS` | ask the model whether a hand-written card already tracks the bug | `true` |
| `MAX_MATCH_CANDIDATES` | cards shown to the model per duplicate check | `20` |
| `MAX_NEW_CARDS_PER_RUN` | cap on cards created per run (0 = unlimited) | `25` |
| `MAX_AUDITS_PER_RUN` | cap on Discord audits per run (0 = unlimited) | `15` |
| `VISION_ENABLED` | read images at all; off = the pre-vision behaviour | `true` |
| `MAX_IMAGES_PER_AUDIT` | pictures shown to the model per report | `4` |
| `MAX_IMAGE_BYTES` | images larger than this are skipped | `8000000` |
| `REAUDIT_IMAGE_BLOCKED` | pass 2 — re-audit cards blocked on a screenshot | `true` |
| `MAX_REAUDITS_PER_RUN` | cap on pass 2 (0 = unlimited) | `10` |
| `AUDIT_BOARD_CARDS` | pass 3 — audit cards that never came from Discord | `true` |
| `MAX_BOARD_AUDITS_PER_RUN` | cap on pass 3 (0 = unlimited) | `10` |

The connection check prints the forum's tag names with their ids, so run it
once and copy the closed/solved tag id into `DISCORD_IGNORED_TAG_IDS`. It also
prints how many cards each board pass would pick up, which is worth reading once
before the first run with passes 2 and 3 enabled — on a board that has never
been swept, that backlog can be large. Cap it with `MAX_BOARD_AUDITS_PER_RUN`
and let it drain over a few days.

Finding IDs:
- Trello: append `.json` to a board URL, or hit
  `https://api.trello.com/1/members/me/boards?key=…&token=…`. List ids come from
  the same JSON (`lists[].id`), which is where `TRELLO_AUDIT_LIST_IDS` and
  `TRELLO_SKIP_LIST_IDS` come from.
- Discord: enable Developer Mode → right-click → "Copy ID".

## Running locally

```bash
pip install -r requirements.txt
# export all the env vars above, then:
DRY_RUN=true python triage.py   # dry-run: fetches + logs, no writes
python check_connections.py     # read-only: credentials, ids, pass previews
python -m unittest discover -p 'test_*.py'
```

`DRY_RUN=true` still downloads images and still calls the models — it is a
"what would it say" run. Only the writes to Trello are suppressed.

## Schedule

Daily at 18:00 UTC (`.github/workflows/bug-triage.yml`). Trigger manually from
the Actions tab ("Run workflow"), optionally with **dry run** checked.

> **Scheduled runs only fire from the repository's default branch** (`stable`).
> On `nightly` or a feature branch the cron is inert — only `workflow_dispatch`
> works there. The daily 18:00 UTC run starts once this file reaches `stable`
> through the normal `nightly` → `staging` → `stable` promotion.
