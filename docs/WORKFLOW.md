# Workflow

Git, branching, PR, and task-tracking conventions. Loaded on demand — `CLAUDE.md` links here.

## Branching

The repository has three long-lived release branches, one per build channel:

| Branch    | Channel   | Role                                    |
|-----------|-----------|-----------------------------------------|
| `nightly` | `nightly` | integration — where features land        |
| `staging` | `staging` | release candidates / QA                  |
| `stable`  | `stable`  | public releases (default branch)         |

Work flows upward, `nightly → staging → stable`, by ordinary merges. The channel
is derived from the branch name at build time, so a commit picks up the right
build settings automatically as it is promoted — see `docs/RELEASE_CHANNELS.md`.

Each feature = a branch off `nightly`, pushed to `origin`, then a PR into
upstream `hydall/Glaze:nightly`.

- **Always base a feature branch on `nightly`** — never on `stable` or `staging`, and never on whatever happened to be checked out. `stable` is the repository's *default* branch, so a fresh clone (and every agent session started from one) lands there: check the base before the first commit. If a branch was already cut from the wrong base, rebase it before opening the PR — `git fetch origin nightly && git rebase origin/nightly` — so the PR carries only its own commits.
- **No direct commits to `nightly`, `staging` or `stable`** — always use a feature branch.
- **Never PR straight into `staging` or `stable`** — features enter through `nightly` and are promoted.
- **Squash-merge every PR** — one feature = one commit on `nightly`, so a regression found later is a single `git revert <sha>` instead of untangling a range.
- **CI must be green before merge** — see below.
- **Stack while catching up** — if a feature depends on another not-yet-merged branch, branch off that branch instead of `nightly`.
- **Run `dart run build_runner build`** after changing any freezed/drift model.

```bash
git checkout nightly && git pull
git checkout -b feat/xxx
# ... work ...
git push -u origin feat/xxx
```

Open the PR against `hydall/Glaze:nightly`, not a fork's branch. Use the **GitHub MCP tools** (`mcp__plugin_github_github__create_pull_request`) or the GitHub web UI. Do **not** use the `gh` CLI — GitHub operations go through GitHub MCP (project + global convention).

## PR title and body

- **English only** — title and body. The repository is public and AGPL-3.0; the
  PR is the permanent record of *why* a change landed, and it has to stay
  readable for contributors who do not read Russian. (Chat with the maintainer
  happens in whatever language is convenient — this rule is about what gets
  written to GitHub.)
- **Describe the changes as a bullet list** — one bullet per change, not a wall
  of prose. Group with `##` headings when a PR carries several independent
  fixes, and keep one list under each.
- **Say what changed and why**, referencing the concrete symbol / file when it
  helps a reviewer find it (`HistoryAssembler.assemble`, not "the prompt code").
- **Title = the squash commit subject** — imperative mood, conventional-commit
  prefix and scope, e.g. `fix(chat): keep the error flag when a regen is
  cancelled`. Keep it under ~72 characters.
- **Close with how it was verified** — tests added, what was run, and what could
  *not* be run (e.g. an agent with no Flutter SDK relying on CI). Never imply a
  check passed when it was never executed.
- **Nothing secret** — no keys, tokens, `.env` values or internal hostnames,
  even when a template asks for them.

## CI gate

`.github/workflows/ci.yml` runs on every PR into `nightly`, `staging` or
`stable` and does two things: `flutter analyze` and `flutter test`. A red check
means the PR is not merged — no exceptions, no "it works on my machine".

Only analyzer **errors** fail the run (`--no-fatal-infos --no-fatal-warnings`);
infos and hints from the strict lint set are not build-breaking and must not be
allowed to block every PR.

Running `flutter analyze` locally before opening the PR is still useful — it is
faster feedback — but it is not the gate. The gate is CI, because it cannot be
skipped or forgotten.

## Before starting work

1. `git branch --show-current` — confirm the branch.
2. `git checkout nightly && git pull` — sync.
3. `git checkout -b feat/xxx` — create the feature branch.
4. `flutter analyze` — lint + typecheck.
5. `flutter test` — run the test suite (one-shot, non-watch mode).

## Cleanup after merge

- Delete local branch: `git branch -D feat/xxx`
- Delete remote branch: `git push origin --delete feat/xxx`
- Sync nightly: `git checkout nightly && git pull`

## Promoting a release

Promotion is a merge, not a PR. A `nightly → staging` diff is an aggregate of
many features that nobody reads; opening a PR for it adds ceremony without
adding a check.

**`nightly → staging` is gated on a real device, not on the diff.** Promote only
after a build of `nightly` (the *Build (Branch)* workflow) has been installed and
actually used, and nothing obvious is broken. CI proves the code compiles and the
tests pass; only a build on a phone or desktop proves the app still works.
`staging` therefore means "someone held this in their hands", and `stable` means
"that held up".

When a promoted build turns out to be broken, revert the squashed commit of the
offending feature on `nightly` and re-promote — that is what squash-merging buys.

```bash
# nightly → staging (cut a release candidate)
git checkout staging && git pull && git merge --no-ff nightly && git push

# staging → stable (ship it)
git checkout stable && git pull && git merge --no-ff staging && git push
```

## Build distribution

Two manual workflows produce installable builds. Both are started from the
Actions tab, and both take the branch from GitHub's native "Use workflow from"
selector.

| Workflow | File | Produces |
|----------|------|----------|
| *Build (Branch)* | `.github/workflows/build-branch.yml` | Dev build of any branch — APK, Windows ZIP, IPA as run artifacts |
| *Build Release (Publish)* | `.github/workflows/build-release.yml` | The same three, plus a tagged GitHub Release carrying them as assets |

**Platform selection.** Each workflow has an *Android (APK)* / *Windows (ZIP)* /
*iOS (IPA)* checkbox, all on by default. An unchecked platform does not build at
all, so it costs no runner time and is absent from the release and the Telegram
post. Unchecking all three leaves nothing to do and the run stops after the
metadata job.

**Telegram delivery.** `post_to_telegram` announces the build in the public
group and replies to that announcement with each selected file;
`dm_developers` sends the same set to the developers' private chats. Both go
through `.github/scripts/telegram_post.sh`, which is also where the 50 MB Bot
API upload limit is handled — a file over the limit is replaced by a reply
linking to the workflow run instead of failing the post. Because the Windows ZIP
is the one artifact that can realistically cross that limit, check the run log
after a Windows build if the ZIP does not show up in the group.

Secrets used by the delivery step:

| Secret | Meaning |
|--------|---------|
| `TG_BOT_TOKEN` | Bot token |
| `TG_CHAT_ID` | Chat id of the public group builds are announced in |
| `TG_TOPIC_ID` | Message thread id of the topic inside that group. Leave unset for a group without topics — the post then goes to the chat itself |
| `TG_MENTIONS` | Text posted in a spoiler when `notify_people` is on |
| `TG_DEV_CHAT_IDS` | Numeric private chat ids for `dm_developers`, comma- or whitespace-separated |

The bot has to be a member of the group, and an administrator with
*Pin messages* for the announcement pin to work — a failed pin is a warning, not
a failed run. To read a topic's thread id, open the topic in Telegram Web: it is
the last number in the URL (`.../#-1001234567890_25` → topic `25`).

A successful group post moves the `build/last` tag to the built commit, which is
the baseline for the "commits since last build" list in the next announcement.
The developer DMs deliberately do not move it — an internal share is not an
announcement.

## Trello board

- **Board URL:** https://trello.com/b/jRUaax0b/glazeflutter
- **Board ID:** `6a08b1a3055cd731743d9c2b`
- **API credentials** live in `.trello` (gitignored, not shipped in builds) — read with `source .trello` or parse manually.
- Use the Trello REST API (`https://api.trello.com/1/...?key=...&token=...`) to read/update cards.

### Lists

| Name | ID |
|---|---|
| features | `6a08b1a3055cd731743d9c1c` |
| Known Bugs | `6a08b1a3055cd731743d9c29` |
| In Progress | `6a0991fb6005f1f92f73cf44` |
| Done, not tested | `6a08b1a3055cd731743d9c2a` |
| Fixed | `6a08b6a98f657e17b6c33a23` |
| later | `6a08b1a3055cd731743d9c23` |
| ios | `6a08b1a3055cd731743d9c24` |
| chat modes | `6a08b1a3055cd731743d9c20` |
| CD-ROM | `6a08b1a3055cd731743d9c21` |

### Card workflow

1. **Before any fix/feat** — search the board for an existing card. If found, move it to **In Progress**; if not, create one in **In Progress** with a clear description.
2. **After implementation** — move the card to **Done, not tested**.
3. **After the user tests** — move the card to **Fixed**.
4. New features with no card yet → create in **features**, then move to **In Progress** when work starts.
