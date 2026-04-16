# AGENTS.md — Workflow Rules

## Repository Structure

- **`origin`** = `danvitv/Glaze` (your fork) — all development happens here
- **`upstream`** = `hydall/Glaze` (upstream project) — PRs are merged here
- **`origin/dev`** mirrors `upstream/dev` — this is the **base for all feature branches**
- **`upstream/dev`** = integration branch where all PRs are targeted

## Local Development

- **Work only on feature branches.** Never develop on local `dev`.
- **All feature branches are created from `origin/dev`**: `git checkout -b feat/xxx origin/dev`
- **Keep `origin/dev` in sync** with upstream: `git fetch upstream && git push origin upstream/dev:refs/heads/dev`

## Committing & PR Workflow

1. Start from the correct **feature branch** (e.g. `feat/vectorization-v2`).
2. Develop and test directly on that feature branch.
3. Commit changes on the feature branch.
4. Push the feature branch to `origin`.
5. Open a PR targeting `upstream/dev` (never `main`).
6. If a new feature depends on an existing feature branch, create the new branch from that feature branch.

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
- **All feature branches are created from `origin/dev`**: `git checkout -b feat/xxx origin/dev`
- If PR B depends on PR A, create branch B from branch A, not from dev.
- If a branch is created from another feature branch, it automatically includes all commits already present in that parent branch.
- **Do not push local `dev`** to any remote. Only update `origin/dev` via `git push origin upstream/dev:refs/heads/dev`.

## Current Branches

| Branch | Purpose | PR |
|--------|---------|----|
| `origin/dev` | Local mirror of upstream integration branch | No PR |
| `fast-fixes` | Mobile testing bug fixes batch | Not yet |

### Historical (merged & deleted)
- `feat/cloud-sync` → merged via PR #20
- `feat/vectorization-v2` → merged via PR #24  
- `feat/memorybook` → merged via PR #27
- `archive/feat/summary` → deleted
- `archive/feat/tokenizer` → deleted

## Before Starting Work

- Check `git branch --show-current` — make sure you're on the right branch.
- Sync `origin/dev` with upstream: `git fetch upstream && git push origin upstream/dev:refs/heads/dev`
- Create feature branch from `origin/dev`: `git checkout -b feat/xxx origin/dev`
- Run `npm run build` before committing to verify no build errors.

## Roadmap Maintenance

- `Roadmap.md` must be kept current during implementation, not updated retroactively at the very end.
- Break roadmap work into smaller concrete subtasks instead of leaving large vague items.
- For each roadmap task or subtask, explicitly record:
  - completion status: `done` / `not done`
  - testing status: `tested` / `not tested`
- When work is only partially completed, split the remaining scope into separate follow-up subtasks instead of leaving an ambiguous mixed-status item.
- Use `Roadmap.md` to explicitly point the user to what still needs manual verification, so pending test coverage is visible in the roadmap itself.

## Conflict Avoidance Strategy

### The Problem
When feature branches accumulate unmerged changes, they diverge and create merge conflicts when upstream accepts other PRs.

### The Solution: Strict Branch Hygiene
1. **One feature per branch** — Never combine unrelated work in a single branch
2. **Always branch from `origin/dev`** (or previous feature if dependent)
3. **Never branch from local `dev`** that has unmerged feature commits
4. **Delete merged branches immediately** — both local and remote
5. **Keep `origin/dev` in sync** with upstream before creating new branches

### Visual Workflow
```
# CORRECT: Isolated feature branches from origin/dev
origin/dev ─┬─► feat/fix-ui-crash ─► PR #1 (merged) ─► deleted
             ├─► feat/add-novelai ─► PR #2 (merged) ─► deleted
             └─► feat/vector-v3 ──► PR #3 (merged) ─► deleted

# WRONG: Compound branch with multiple features
origin/dev ─► dev (local, has feat/A) ─► feat/A+B ─► conflicts!
```

### Dependency Handling
If feature B depends on feature A:
```bash
git checkout feat/A
git checkout -b feat/B

# When A merges to upstream/dev, sync and rebase B:
git fetch upstream
git push origin upstream/dev:refs/heads/dev
git checkout feat/B
git rebase origin/dev
```

### Cleanup Checklist After Merge
- [ ] Delete local branch: `git branch -D feat/xxx`
- [ ] Delete remote branch: `git push origin --delete feat/xxx`
- [ ] Sync `origin/dev`: `git fetch upstream && git push origin upstream/dev:refs/heads/dev`
- [ ] Verify no stale references: `git branch -a`
