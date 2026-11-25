# Workflow

Git, branching, PR, and task-tracking conventions. Loaded on demand — `CLAUDE.md` links here.

## Branching

The repository has two long-lived release branches, one per build channel:

| Branch    | Channel   | Role                                    |
|-----------|-----------|-----------------------------------------|
| `nightly` | `nightly` | integration — where features land        |
| `main`    | `stable`  | public releases (default branch)         |

Work flows upward, `nightly → main`, by ordinary merges. The channel is
derived from the branch name at build time, so a commit picks up the right build
settings automatically as it is promoted — see `docs/RELEASE_CHANNELS.md`.

Each feature = a branch off `nightly`, pushed to `origin`, then a PR into
upstream `hydall/Glaze:nightly`.

- **Always base a feature branch on `nightly`** — never on `main`, and never on whatever happened to be checked out. `main` is the repository's *default* branch, so a fresh clone (and every agent session started from one) lands there: check the base before the first commit. If a branch was already cut from the wrong base, rebase it before opening the PR — `git fetch origin nightly && git rebase origin/nightly` — so the PR carries only its own commits.
- **No direct commits to `nightly` or `main`** — always use a feature branch.
- **Never PR straight into `main`** — features enter through `nightly` and are promoted.
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

Open the PR against `hydall/Glaze:nightly`, not a fork's branch. Use whatever is at hand: the `gh` CLI (`gh pr create --base nightly`), the GitHub MCP tools when they are connected, or the web UI.

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

`.github/workflows/ci.yml` runs on every PR into `nightly` or `main`:
`flutter analyze`, `flutter test`, and the WebView render suite
(`test/webview_js` — Node + Playwright, no Flutter). A red check means the PR
is not merged — no exceptions, no "it works on my machine".

Only analyzer **errors** fail the run (`--no-fatal-infos --no-fatal-warnings`);
infos and hints from the strict lint set are not build-breaking and must not be
allowed to block every PR.

The render suite loads the real `assets/chat_webview/` modules in a headless
Chromium and asserts on the DOM, the resolved CSS and what a click does. Run it
with `cd test/webview_js && npm ci && npx playwright install chromium && npm
test`; the rule that goes with it — every rendering bug becomes a corpus entry
before it is fixed — is in `docs/rules/message-rendering.md`.

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

Promotion is a merge, not a PR. A `nightly → main` diff is an aggregate of many
features that nobody reads; opening a PR for it adds ceremony without adding a
check.

**`nightly → main` is gated on a real device, not on the diff.** Promote only
after a build of `nightly` (the *Build (Branch)* workflow) has been installed and
actually used, and nothing obvious is broken. CI proves the code compiles and the
tests pass; only a build on a phone or desktop proves the app still works.
`main` means "that held up".

When a promoted build turns out to be broken, revert the squashed commit of the
offending feature on `nightly` and re-promote — that is what squash-merging buys.

### Automatic promotion

`.github/workflows/promote-main.yml` does the promotion on a schedule (Wednesdays,
12:00 Moscow / 09:00 UTC), so `main` does not fall behind when nobody remembers to merge:

- It picks the **newest `nightly` commit that is at least 72 hours old**, not the
  tip. Those days in nightly builds stand in for the device check above, and the
  pick moves forward every run, so a `nightly` that never stays quiet still gets
  promoted.
- It moves the `auto/promote-main` branch to that commit, opens a PR into
  `main` (or updates the open one), dispatches CI on it, and merges the PR with
  a merge commit once CI is green.
- A red CI, a conflict with `main`-only commits or a required review leaves the
  PR open and fails the run — fix it by hand and merge, or let the next run retry.
- **Pause** it by setting the repository variable `AUTO_PROMOTE_PAUSED` to
  `true` (Settings → Secrets and variables → Actions → Variables) — for example
  while a known-broken feature sits on `nightly`. A manual run still works and
  takes a `soak_hours` input (`0` promotes the tip of `nightly`).
- It only merges code. Publishing a release is still the manual
  *Build Release (Publish)* workflow.

Requirements: the schedule only fires once the workflow file is on `main`
(the default branch), and *Settings → Actions → General → Allow GitHub Actions
to create and approve pull requests* must be on.

Promoting by hand still works the same way:

```bash
# nightly → main (ship it)
git checkout main && git pull && git merge --no-ff nightly && git push
```

## Version numbers

Versions are `YY.M.N`: two-digit year, month without a leading zero, and the
number of the release within that month, from 1. A hotfix is just the next
release — `26.11.1`, then `26.11.2`; December starts again at `26.12.1`. Always
three numbers, because iOS accepts no more.

Nobody bumps the version by hand. `.github/scripts/calver.sh` derives it from
the release tags (`v26.11.1`, …):

- *Build Release (Publish)* takes the next free number of the current month and
  tags the release with it. A tag typed into the `tag_name` input wins.
- *Build (Branch)* carries the newest released version; the watermark's date,
  branch and commit tell those builds apart.
- Each build job writes the version into `pubspec.yaml` for that build only
  (`.github/scripts/stamp_version.sh`), so `flutter build`, the Linux packages and
  the Windows installer all pick it up. The `version:` in the committed
  `pubspec.yaml` is a placeholder that only local builds show.

Every published release takes a number, a nightly pre-release included, so the
numbers seen on `main` can skip.

The old `0.x` tags do not match the scheme and are ignored; `26.11.1` compares
as newer than `0.10.1`, so existing installs see it as an update.

## Build distribution

Two manual workflows produce installable builds. Both are started from the
Actions tab, and both take the branch from GitHub's native "Use workflow from"
selector.

| Workflow | File | Produces |
|----------|------|----------|
| *Build (Branch)* | `.github/workflows/build-branch.yml` | Dev build of any branch — APK, Windows ZIP, IPA, Linux pacman package + `.tar.zst` as run artifacts |
| *Build Release (Publish)* | `.github/workflows/build-release.yml` | The same set, plus a tagged GitHub Release carrying them as assets |

**Platform selection.** Each workflow has an *Android (APK)* / *Windows (ZIP)* /
*iOS (IPA)* / *Linux (pacman + tar.zst)* checkbox, all on by default. An unchecked
platform does not build at all, so it costs no runner time and is absent from the
release and the Telegram post. Unchecking every platform leaves nothing to do and
the run stops after the metadata job.

The Linux job runs in an `archlinux:latest` container, because the
`flutter_inappwebview` Linux backend needs WPE WebKit at build time and Arch is
where it is packaged (Ubuntu does not ship it). It produces two packages from
`scripts/build_linux_packages.sh`: an Arch/CachyOS `.pkg.tar.zst` (makepkg) that
depends on `wpewebkit`, and a portable `.tar.zst` of the bundle for other rolling
distros with WPE WebKit installed. DEB and AppImage are not built: a binary built
against Arch's glibc does not start on Ubuntu/Debian LTS, and neither ships WPE
WebKit. A format whose tooling is missing is skipped with a warning rather than
failing the job; the run only fails when neither package comes out.

**Telegram delivery.** `post_to_telegram` announces the build in the public
group and replies to that announcement with each selected file;
`dm_developers` sends the same set to the developers' private chats. Both go
through `.github/scripts/telegram_post.sh`, which is also where the 50 MB Bot
API upload limit is handled — a file over the limit is replaced by a reply
linking to the workflow run instead of failing the post. The Windows ZIP and the
Linux packages are the artifacts that can realistically cross that limit, so
check the run log if one of them does not show up in the group.

Secrets used by the delivery step:

| Secret | Meaning |
|--------|---------|
| `TG_BOT_TOKEN` | Bot token |
| `TG_CHAT_ID` | Chat id of the public group builds are announced in. A numeric `-100…` id, or `@username` for a group that has one |
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

## Release article

Once *Build Release (Publish)* finishes on `main`,
`.github/workflows/release-article.yml` announces the release:

- `.github/scripts/release_article.py` collects the PRs since the previous
  stable release (with their descriptions) and has the DeepSeek model the
  bug-triage bot uses write the article in Russian and English, in the style of
  the previous one. It writes `site/articles/<version>.{ru,en}.md`, the
  link-preview page with its cover (`og.png`, rendered by headless Chrome from
  `.github/scripts/release_cover.html`), the roadmap entry and the download
  fallback in `site/assets/data.js`.
- The article is committed straight to `main` — the site only lives there — and
  the Pages deploy is dispatched and awaited.
- The link then goes to the Telegram group of the build posts and to the
  Discord channel behind the `DISCORD_RELEASE_WEBHOOK` secret. The variable
  `RELEASE_POST_LANG` picks the language of the posts: `ru` (default), `en`
  or `both`.
- It runs once per release. Pre-releases get nothing. To fix an article, edit
  the files on `main`; to post the link again, run the workflow by hand with the
  release tag.

The text is the model's: read the article after a release and correct it on
`main` if it got something wrong.

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
