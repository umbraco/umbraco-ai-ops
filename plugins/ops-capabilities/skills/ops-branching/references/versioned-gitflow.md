# Versioned gitflow (`vN/dev` + `vN/main` per major)

Use this when the repo keeps a **separate gitflow line per major version** — a `vN/dev`
integration branch and a `vN/main` release branch for each supported major `N` (e.g.
`v17/dev`+`v17/main`, `v18/dev`+`v18/main`). It's ordinary gitflow, resolved to the
**current major's** branch pair.

> The concrete names here (`vN/dev` / `vN/main`) are what `branching.base` /
> `branching.release_base` resolve to for this model. In the loops, always use the resolved
> values — never hard-code a literal major or branch name in engine logic.

## Resolving the current major

- If a repo declares its lines explicitly (via its own `ops-repo-meta`),
  use them verbatim (e.g. `base: v18/dev`, `release_base: v18/main`).
- Otherwise resolve the **highest** major from the branches:
  ```bash
  git branch -a --format='%(refname:short)' | sed 's#^origin/##' \
    | grep -E '^v[0-9]+/(dev|main)$' | sort -uV
  ```
  Take the greatest `N` that has **both** a `vN/dev` and a `vN/main`; that pair is the active
  line — `base = vN/dev`, `release_base = vN/main`.
- The repo's own `CLAUDE.md` may pin the working line (versioned repos typically document the
  in-dev major); follow it, but a repo-declared line list still wins.

## Branching, merging, releasing

Identical to two-branch gitflow (`references/gitflow.md`) with `dev`→`base` and
`main`→`release_base`:

- **Start on latest `base`** (the current `vN/dev`); dev-sync is an applied-repo
  responsibility (see gitflow.md / `branching.release_skill`).
- Branch off `base`; name by the repo's convention (a versioned repo often enforces
  `branching.branch_naming`, e.g. `v{major}/{type}/{desc}`, via a git hook).
- **Squash-merge** normal PRs into `base`.
- **Cut a release** off `base` and PR into `release_base`; **merge-commit (not squash)** so
  the version-bump commit survives for tagging + back-merge.
- **Back-merge `release_base` → `base`** after release — applied-repo responsibility.

## New major

When a new major `N+1` line is created (`v{N+1}/dev` + `v{N+1}/main`), `base`/`release_base`
resolution shifts to it automatically (highest major). If the repo owns cutting a new line,
that belongs to its **`branching.release_skill`** — the engine doesn't create major lines.

## Post-merge cleanup

Same as gitflow: local branch cleanup / worktree+DB teardown is the applied repo's job (its
`branching.release_skill` or `/cleanup` flow), not engine mechanics.
