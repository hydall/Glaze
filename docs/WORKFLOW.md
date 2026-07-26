# Workflow

Git, branching, PR, and task-tracking conventions. Loaded on demand — `CLAUDE.md` links here.

## Branching

The upstream repository is `hydall/Glaze` and has three long-lived branches:

- `nightly` — active development; this replaces the old `dev` branch.
- `staging` — verified work promoted from `nightly`; release candidates are built here.
- `stable` — stable versioned releases only (`0.7.0`, `0.7.1`, etc.), promoted from `staging`.

Each feature = a branch off `nightly`, pushed to `origin`, then a PR into upstream `hydall/Glaze:nightly`.

- **No direct commits to long-lived branches** — use feature branches and promotion PRs.
- **Stack while catching up** — if a feature depends on another not-yet-merged branch, branch off that branch instead of `nightly`.
- **Run `dart run build_runner build`** after changing any freezed/drift model.

```bash
git checkout nightly && git pull
git checkout -b feat/xxx
# ... work ...
git push -u origin feat/xxx
```

Open feature PRs against `hydall/Glaze:nightly`, not a fork's default branch. Promote verified work with PRs in this order: `nightly` -> `staging` -> `stable`. Use the **GitHub MCP tools** (`mcp__plugin_github_github__create_pull_request`) or the GitHub web UI. Do **not** use the `gh` CLI — GitHub operations go through GitHub MCP (project + global convention).

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
