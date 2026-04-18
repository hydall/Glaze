# AGENTS.md — Workflow Rules

## Repository Structure

- **`origin`** = `danvitv/Glaze` (your fork) — all development happens here
- **`upstream`** = `hydall/Glaze` (upstream project) — PRs are merged here
- **`origin/dev`** mirrors `upstream/dev` — this is the **base for the first feature branch**
- **`upstream/dev`** = integration branch where all PRs are targeted

## Local Development

- **Work only on feature branches.** Never develop on local `dev`.
- **Use linear chain workflow:** Each new feature branches from the previous feature, not from `origin/dev`.
- **Keep `origin/dev` in sync** with upstream: `git fetch upstream && git push origin upstream/dev:refs/heads/dev`

## Linear Chain Workflow

Development follows a **linear chain** of feature branches:

```
origin/dev ─► feat/A ─► feat/B ─► feat/C ─► feat/D
```

### Why Linear Chain?

1. **Preserves context:** Each feature builds on the previous work
2. **Simplifies testing:** You always test with all previous features included
3. **Reduces conflicts:** No need to constantly rebase on diverging dev
4. **Natural dependencies:** Features that depend on each other are already in sequence

### Creating the Chain

```bash
# Start the chain from origin/dev
git checkout -b feat/batch3-fixes origin/dev
# ... work on batch3 fixes ...
git commit -m "fix: batch3 mobile bugs"
git push -u origin feat/batch3-fixes

# Continue from previous feature
git checkout -b feat/multi-vector feat/batch3-fixes
# ... work on multi-vector ...
git commit -m "feat: multi-vector retrieval"
git push -u origin feat/multi-vector

# Next feature continues the chain
git checkout -b feat/memorybook-ui feat/multi-vector
# ... work on memorybook UI ...
```

### Committing & PR Workflow

1. **Work on current branch** in the chain
2. **Commit changes** with descriptive messages
3. **Push to origin:** `git push origin <current-branch>`
4. **Create PR** targeting `upstream/dev` (always dev, never main)
5. **When ready for next feature:** `git checkout -b feat/next-thing <current-branch>`

### Important Rules

- **All PRs target `upstream/dev`**, never `main`
- **Never branch from `origin/dev`** unless starting a new chain
- **Each branch includes all previous commits** in the chain
- **Do not push local `dev`** to any remote. Only update `origin/dev` via `git push origin upstream/dev:refs/heads/dev`

## Current Branches

| Branch | Purpose | PR |
|--------|---------|----|
| `origin/dev` | Local mirror of upstream integration branch | No PR |
| `feat/fast-fixes-batch3` | Mobile testing batch3 bug fixes | Not yet |
| `feat/multi-vector-retrieval` | Multi-vector retrieval with MaxSim | Not yet |

### Historical (merged & deleted)
- `feat/cloud-sync` → merged via PR #20
- `feat/vectorization-v2` → merged via PR #24  
- `feat/memorybook` → merged via PR #27
- `fast-fixes` → merged via PR (batch1-2)
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

## Pattern Recognition — Cowl's actual use of influence
Over the months she has been able to trace where the leverage Cowl extracts through her actually lands. Access to the training wing evening slots — previously occupied by default by the wealthy faction — was redistributed. An exam schedule that structurally penalised students working campus shifts was revised. A lab allocation complaint that had sat unprocessed for a semester moved through the Council and was resolved. None of these came from her initiative. All of them passed through her signature. She has mapped the pattern. The influence does not accumulate with him. She does not know whether this makes what he does better or simply more complicated. She has not found a frame that contains both facts without contradiction, and she has stopped looking for one.
