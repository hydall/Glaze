# AGENTS.md — Workflow Rules

## Local Development

- **Work only on feature branches.** Do not develop on local `dev` anymore.
- `dev` remains an integration/reference branch only when explicitly needed, but it is not the default working branch.
- **Never open a PR from local `dev`.** All work must be committed, pushed, and reviewed from feature branches.

## Committing & PR Workflow

1. Start from the correct **feature branch** (e.g. `feat/vectorization-v2`).
2. Develop and test directly on that feature branch.
3. Commit changes on the feature branch.
4. Push the feature branch.
5. Open a PR targeting `upstream/dev` (never `main`).
6. If a new feature depends on an existing feature branch, create the new branch from that feature branch and keep working there.

```
# Example workflow
git checkout feat/vectorization-v2
git commit -m "feat: add Russian i18n for embedding settings"
git push origin feat/vectorization-v2
gh pr create --base dev --title "..."

# Dependent feature workflow
git checkout feat/vectorization-v2
git checkout -b feat/memorybook
git commit -m "feat: add memorybook scaffolding"
git push -u origin feat/memorybook
gh pr create --base dev --title "..."
```

## Branch Rules

- **All PRs target `upstream/dev`, never `main`.**
- PR branches are created from `upstream/dev`: `git checkout -b feat/xxx upstream/dev`.
- If PR B depends on PR A, create branch B from branch A, not from dev.
- If a branch is created from another feature branch, it automatically includes all commits already present in that parent branch.
- **Do not push local `dev`** to any remote.

## Current Branches

| Branch | Purpose | PR |
|--------|---------|----|
| `dev` (local) | Integration/reference only | No PR |
| `feat/cloud-sync` | Cloud sync (Phases 1-6) | PR #20 (open) |
| `feat/vectorization-v2` | Vector/lorebook stabilization | PR #24 (open) |
| `feat/memorybook` | Memorybook work on top of vectorization | Pending |

## Before Starting Work

- Check `git branch --show-current` — make sure you're on the right branch.
- If working on a feature, the final commit must land on the feature branch, not on `dev`.
- If starting follow-up work, create or switch to the correct feature branch before editing files.
- Run `npm run build` before committing to verify no build errors.

## Roadmap Maintenance

- `Roadmap.md` must be kept current during implementation, not updated retroactively at the very end.
- Break roadmap work into smaller concrete subtasks instead of leaving large vague items.
- For each roadmap task or subtask, explicitly record:
  - completion status: `done` / `not done`
  - testing status: `tested` / `not tested`
- When work is only partially completed, split the remaining scope into separate follow-up subtasks instead of leaving an ambiguous mixed-status item.
- Use `Roadmap.md` to explicitly point the user to what still needs manual verification, so pending test coverage is visible in the roadmap itself.
