# The `sync` contract — what `ops-release · sync` has to do

**This is guidance for whoever writes a repo's `ops-release`, not an engine implementation.**
`ops-release` has no framework default: version sources, publish targets and back-merge
mechanics are product facts, so the repo owns all four of its actions. This file exists so
`sync` is not reinvented from nothing, because it is the action people get wrong.

It replaces the old `sync-dev` skill. Nothing about the contract changed; it stopped being a
skill of its own because it is one action of one capability.

## Why it is a capability action and not engine bash

Getting the integration branch up to date after a release is **destructive**,
**environment-specific** and often **entangled with the repo's worktrees and databases**. A
cloud routine has no local clone or worktree at all. Shipping one product's bash as if it were
generic was the anti-pattern the capability model removes — so the engine ships the
*requirement*, and the repo ships the *mechanism*.

## The three pieces

1. **Get the integration branch current.** Whatever "up to date" means in this repo, do it
   there — a local run may fast-forward a worktree; a cloud run has no worktree and works
   through the forge. Never hard-code a branch name: the line comes from the `plan`, and the
   branch for that line is `ops-branching`'s private business.

2. **Back-merge the release into the integration branch**, so it carries the version bump and
   any fixes made on the release branch. **Never skip this.** An un-synced integration branch
   is the classic release mistake: the next change starts from code that predates the release,
   and the bump gets reverted by the following merge.

   Under **main-only** there is no separate release base, so there is nothing to back-merge —
   `sync` is a no-op and should return `{ ok: true }` saying so, not an error.

   `ops-branching`'s `assets/sync-main-to-dev.yml` is a worked example workflow if the repo
   would rather the forge did it.

3. **Clean up what the release created** — prune stale remote-tracking refs, delete local
   branches whose PR is confirmed merged. Destructive and repo-specific. Worktree and database
   teardown is **`ops-workspace · teardown`**, not this action.

## Idempotency

`sync` **MUST** be safe to call twice. A second call on an already-synced line returns
`{ ok: true, pr_number: null }` — not a second back-merge PR, and not an error. The release
loop can be re-fired, and a human may run it by hand after a partial failure.

## What `sync` must not do

- **Never force-push**, and never reset an integration branch to a release base. If the
  back-merge conflicts, open a PR and report it — a conflict here is a human's problem.
- **Never publish anything.** That is `publish`, and it already ran.
- **Never touch a line other than the one in the `plan`.** Porting to other lines is
  `ops-change`'s job, per PR, with its own verify and CI.
