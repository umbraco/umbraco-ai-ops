---
name: release-and-branching
description: Branching, merge, and release workflow for any repo. Reads the repo's branching model from its `.claude/ai-ops.yml` (gitflow, main-only, versioned-gitflow, or custom) and follows the matching conventions for branch naming, squash vs merge-commit, cutting a release, and tagging; falls back to branch detection when there's no config. Use whenever creating a branch to do work, opening or merging a PR, cutting a release, merging a release into the release base, or setting up release-tag automation. Trigger on intents like "start a branch", "merge this PR", "cut/do a release", "release X", "merge to main".
---

# Branching & release workflow

This skill works in **any** repo. The branch model, integration base, and release base
are **config-driven** — read them from the consumer's `.claude/ai-ops.yml`. Only fall back
to branch detection when the repo ships no config. Never assume the literal names
`dev`/`main`; resolve them from `branching.base` / `branching.release_base`.

## Step 1 — resolve the model (config first, detection as fallback)

**A. If `.claude/ai-ops.yml` exists** (shape: `ai-ops.schema.json`), it is authoritative.
Read `branching.model` and the resolved base branches:

| `branching.model` | Integration base (`branching.base`) | Release base (`branching.release_base`) | Reference |
|-------------------|--------------------------------------|-----------------------------------------|-----------|
| `gitflow` | `dev` | `main` | `references/gitflow.md` |
| `main-only` | `main` | *(none — releases squash into `main`)* | `references/main-only.md` |
| `versioned-gitflow` | current major's `vN/dev` | current major's `vN/main` | `references/versioned-gitflow.md` |
| `custom` | — | — | **defer entirely to `branching.release_skill`** (see below) |

- Where `branching.base` / `branching.release_base` are given explicitly, use them verbatim.
- For **`versioned-gitflow`** with no explicit `base`, resolve the **current major**: list
  branches, find the highest `vN/dev` (and matching `vN/main`) — that pair is the active
  line. See `references/versioned-gitflow.md`.
- For **`custom`**, this skill does **not** decide anything: hand off to the applied-repo
  skill named in **`branching.release_skill`** (which is REQUIRED for `custom`). That skill
  owns branch naming, merge style, cutting, tagging, and back-merge.

**B. If there is no `.claude/ai-ops.yml`**, detect the model from the branches:

```bash
git branch -a --format='%(refname:short)' | sed 's#^origin/##' | sort -u
```

- Both a `vN/dev` **and** a `vN/main` (for some major N) → **versioned-gitflow**; resolve the
  highest `N`. Read `references/versioned-gitflow.md`.
- Both a `dev` branch **and** a `main` branch → **two-branch gitflow**. Read
  `references/gitflow.md`.
- **Only** `main`, no `dev` → **main-only**. Read `references/main-only.md`.
- Neither / mixed / genuinely unclear → **ask the user which model to follow** before doing
  anything. Never invent a `dev` branch.

If the repo's own `CLAUDE.md`/`README` documents a branching model, that wins over
detection — but `.claude/ai-ops.yml` (step A) wins over everything.

## Delegating to a repo's release skill

Whenever `branching.release_skill` is set (any model, and **required** for `custom`), the
mechanics of cutting/bumping/tagging/back-merge belong to **that** skill, not to this one or
to `auto-release-loop`. This skill/loop only orchestrates and gates; the named skill performs
the repo-specific steps. The engine's built-in gitflow / main-only / versioned-gitflow flows
below are the **fallback default** used only when no `release_skill` is set.

## Rules common to all models

- **Never commit directly to a protected branch** (the resolved `release_base`, and the
  resolved `base` where it differs). Always work on a branch.
- Name branches by type: `feature/…`, `fix/…`, `chore/…` (also `docs/…`, `refactor/…`,
  `test/…`).
- Open a PR; merge only after review + green CI.
- **When CI fails, reproduce it locally before deciding anything.** Never dismiss a red check
  as "flaky" from the dashboard, and never merge past a reproducible failure. If it passes
  locally, treat as flaky (rerun the job to green); if it fails locally, it's real — fix it or
  hold. The exact build/test commands are repo-specific — get them from the repo's `CLAUDE.md`
  or `README`.
- **Repo-specific details live in the repo, not here.** Version-bump file lists, test/build
  commands, and worktree/DB cleanup belong in the repo's `CLAUDE.md` — follow those, don't
  duplicate them in this skill.
- **Dev-sync / back-merge / local branch cleanup are the applied repo's responsibility.**
  The engine ships **no** bash for these (they are repo- and environment-specific — e.g. web
  routines have no local clone). When a repo needs them, they are performed by its
  **`branching.release_skill`**; the fallback contract when no skill is set is described in
  the model reference files (`references/*.md`).

## Release tagging (all models)

A release finishes by tagging `v<version>` and creating a GitHub Release. **If the repo has no
automation for this, add it:** copy `assets/release-tag.yml` into `.github/workflows/` and
adjust the trigger branch + the version-source step for the repo's stack. The example is
idempotent — it only fires when the version actually changes (it skips if the tag exists).
The reference file for each model says exactly where tagging fits.
