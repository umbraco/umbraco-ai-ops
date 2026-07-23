---
name: sync-dev
description: The CONTRACT for dev-sync / back-merge / post-merge cleanup — getting the integration base up to date after a merge or release. The engine does NOT ship bash for this; the mechanics belong to the applied repo (its `branching.release_skill`, or its own cleanup flow). Use when the user says "move/go back to dev", "sync dev", "get latest on the base", or after a release, to know WHO performs the sync and what the generic fallback is.
---

# sync-dev — the dev-sync / back-merge contract

Keeping the integration base (`branching.base` — `dev`, `main`, or `vN/dev`) up to date after
a merge or release used to be an engine script. It no longer is: **dev-sync, the
`release_base` → `base` back-merge, and post-merge local cleanup are applied-repo
responsibilities**, because they are destructive, environment-specific (a Claude web routine
has no local clone or worktree), and often entangled with the repo's worktrees and databases.
Shipping one product's bash as if it were generic was the anti-pattern this seam removes.

## Who performs it

- **If the repo sets `branching.release_skill`** (in `.claude/ai-ops.yml`), **that skill owns
  the contract** — dev-sync, back-merge, and cleanup. Invoke it; don't reimplement here.
- **If not**, use the generic fallback below (local, single-clone) or the repo's own
  `CLAUDE.md` / `/cleanup` flow for anything worktree- or database-specific.

## The three pieces of the contract

1. **Dev-sync** — get the main worktree onto an up-to-date integration base. Generic fallback:
   resolve the main worktree (first entry of `git worktree list`), `git checkout <base>`,
   `git pull`. `<base>` is the resolved `branching.base`, never a hard-coded `dev`.
2. **Back-merge after a release** — merge the resolved `release_base` back into `base` so the
   base carries the version bump + any release fixes. **Never skip this** — an un-synced base
   is the classic release mistake. Mechanism is the repo's (its `release_skill`, or the
   `release-and-branching` `assets/sync-main-to-dev.yml` example workflow, or a documented
   manual merge).
3. **Post-merge local cleanup** — fast-forward the base, prune stale remote-tracking refs,
   delete local branches whose PR is confirmed merged. Destructive and repo-specific; the
   engine ships no bash for it. Worktree + DB teardown always belongs to the repo's own flow.

## Relationship to `release-and-branching` and `auto-release-loop`

- `release-and-branching` resolves the model and the base/release-base and points here for the
  sync/cleanup contract.
- `auto-release-loop` **delegates** the back-merge/dev-sync to `branching.release_skill` when
  set, and only orchestrates + gates; the fallback (no `release_skill`) is the generic
  back-merge described above.
