# Two-branch gitflow (`dev` + `main`)

Use this when the repo has both a `dev` branch **and** a `main` branch. The branches are
always `dev` and `main`.

> Here `dev`/`main` are the concrete branches for **this** model. In the loops they are the
> resolved `branching.base` / `branching.release_base` — never hard-code the names in engine
> logic; this reference just spells the gitflow case out.

## Branching (all work)
- **Start on latest `dev`.** Before creating a branch, get the main worktree onto an
  up-to-date integration base (`dev`) and pull. This dev-sync is an **applied-repo
  responsibility**: if the repo sets `branching.release_skill`, that skill owns it; the
  generic fallback is simply — resolve the main worktree, `git checkout` the base, `git pull`.
- **Never commit directly to `dev` or `main`** — both are protected. Always work on a branch.
- Name the branch by type: **`feature/…`**, **`fix/…`**, **`chore/…`** (also `docs/…`,
  `refactor/…`, `test/…`).
- Branch off **`dev`**.

## Merging a normal PR → `dev`
- Open the PR against **`dev`**.
- After review + green CI, **always squash-merge** into `dev` (one tidy commit per PR).
- Delete the branch after merge (`gh pr merge --squash --delete-branch` removes the remote
  branch).
- **Post-merge local cleanup** (fast-forward the base, prune stale remote-tracking refs,
  delete local branches whose PR is confirmed merged) is an **applied-repo responsibility**,
  not engine mechanics — it is destructive, environment-specific (web routines have no local
  clone), and often entangled with worktrees/databases. The engine ships no bash for it:
  - If the repo sets **`branching.release_skill`**, that skill owns the cleanup contract.
  - Otherwise the repo's own `CLAUDE.md` / `/cleanup` flow handles it (worktree + DB teardown
    is always repo-specific and must not live in the engine).

## Cutting a release
1. **Always create a release branch off `dev`:** `release/<version>` (e.g.
   `release/1.0.0-beta.30`).
2. Bump the version across **all** manifests + lockfile, and verify no stale version strings.
   The exact file list and verify command are repo-specific — follow the repo's `CLAUDE.md`
   (e.g. its *Releases → Release process* section); don't duplicate them here.
3. Open a PR from the release branch into **`main`**.
4. After green CI (release PRs often run extra suites — evals, E2E, etc.), **always use a merge
   commit — NOT squash —** when merging the release branch into `main`. The real
   merge/version-bump commit on `main` is what the tagging + sync automation keys off. Squashing
   it away would break both.

## When a CI check fails (tests or evals)
- **Never dismiss a red CI check as "flaky" from the dashboard alone, and never merge past it on
  a hunch.** Reproduce it locally first, using the *same* failing test/suite (commands live in
  the repo's `CLAUDE.md`/`README`).
- **Passes locally →** treat as flaky: note it, rerun the CI job to get green, then proceed.
- **Fails locally too →** it's real: fix it (or hold the release) before merging.
- LLM-driven suites (evals) are non-deterministic, so a single red eval is often flaky — but
  confirm it, don't assume it.

## After the release reaches `main`
Tagging and the back-merge to `dev` must both happen. **Who performs them depends on the repo:**
- **Tag + Release** creates the `v<version>` tag + GitHub Release. If the repo owns this via
  `branching.release_skill`, that skill does it; otherwise add the engine's example workflow
  (`assets/release-tag.yml`) — it's idempotent (skips if the tag exists).
- **Back-merge `main` → `dev`** (the dev-sync) so `dev` picks up the version bump and any
  release fixes. This is an **applied-repo responsibility**:
  - If `branching.release_skill` is set, that skill owns the back-merge + dev-sync contract.
  - Otherwise the repo may adopt the engine's example workflow `assets/sync-main-to-dev.yml`
    (opens a `chore/merge-main-to-dev` PR into `dev`), or do the merge-back by hand per its
    own `CLAUDE.md`.
- **Never skip the back-merge** — an un-synced `dev` is the classic release mistake — but the
  *mechanism* is the repo's, not the engine's.

## Why two merge styles
- **Squash → `dev`** keeps day-to-day history to one commit per feature.
- **Merge commit → `main`** preserves the release branch's version-bump commit, which the tag
  automation and the `main`→`dev` sync rely on. Squashing a release into `main` would break
  that.
