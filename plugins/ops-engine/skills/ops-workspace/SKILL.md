---
name: ops-workspace
description: >-
  An isolated place to build and test one change — worktree, database, ports, dependencies —
  and the teardown that removes everything it created. Prepared and torn down by
  `ops-change`, never by a loop, so how isolation is provisioned stays a product fact. The
  framework default uses a plain git worktree; a repo needing a seeded database or a free
  port ships its own. Called by name with (action, context-json). NOT for direct use — never select it from a description match.
---

# ops-workspace

One change, one clean place to build it.

**Visibility: supporting primitive.** Only **`ops-change`** calls it. A framework loop must
not — the loop does not know whether this repo needs a worktree, a container, a seeded
database, or nothing at all, and the moment a loop decides that, the engine has learned a
product fact.

## Invocation

```
ops-workspace <action> '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `prepare` | `{ branch }` | `{ ok, path, reused, fidelity, notes }` |
| `teardown` | `{ path }` | `{ ok }` |

An absent context is `{}`. **Reject any other action.**

## Action: `prepare`

Create an isolated workspace for that branch and leave it **ready to build** — not merely
checked out. Whatever this repo needs before its build command works (dependencies restored, a
database seeded, a port claimed, credentials in place) happens here, because the alternative is
`ops-change · implement` discovering it halfway through.

**Idempotent.** An existing workspace for that branch **MUST** be reused and returned with
`reused: true`, never duplicated. Two worktrees on one branch is a corruption, not a
convenience, and a re-fired routine will ask twice.

**Framework default:** a git worktree off the branch, and nothing else. That is enough for a
repo whose build needs only a checkout, and honestly insufficient for one that needs a
database — which is why those repos override.

**In a cloud routine there is often nothing to do.** The session already has its own isolated
checkout and no sibling work to collide with. Return that checkout's path with
`reused: true` rather than nesting a worktree inside it. A workspace capability that insists on
creating something is worse than one that recognises it already has what it needs.

### Find out what the environment already provides, before provisioning anything

A cloud environment is **built once and reused**, and its build step may already have installed
the SDK, cached a container image, or started a service. A `prepare` that probes blindly or
reinstalls wastes minutes of every run and can end up with two versions of the same thing.

So **read first, provision second**. If the environment records what it provides — a manifest
file its setup script writes is the usual shape — read that and treat it as authoritative. If
there is no manifest, say so and fall back to the repo's own documented setup rather than
guessing. Report the difference in `notes`: what was already there, and what you had to create.

"Available but not running" is not "unavailable". A cached container image with a stopped
daemon means **startable** — start it. Reinstalling because a service was not already running
is the most expensive way to get this wrong.

### Say how faithful the workspace is: `fidelity`

Where a repo has more than one possible test target — the one CI uses, and a lighter, faster
stand-in — `prepare` **MUST** say which one it produced:

| `fidelity` | Means |
|---|---|
| `ci-parity` | this workspace tests against what CI tests against. A pass here predicts a pass there |
| `reduced` | a faster stand-in: a different database engine, a stubbed dependency, a smaller fixture set |

**Default to `ci-parity`.** A `reduced` target is a last resort — for a quick smoke of one
focused change, or when the parity target genuinely is not available here — because a different
engine produces both false failures *and* false passes.

**A `reduced` pass is not evidence CI will pass**, and `ops-change · verify` must carry that
through to whatever it reports. Silently downgrading the test target and reporting a clean pass
is worse than not testing: it spends the loop's trust on a result that did not earn it.

A repo with exactly one test target reports `ci-parity` and never thinks about this again.

## Action: `teardown`

Remove the workspace **and everything `prepare` created** — the worktree, the database, the
container, the claimed port. A teardown that leaves the database behind is why the tenth run
fails on a name collision.

**MUST succeed when there is nothing to remove.** Teardown is reached from failure paths, and
a teardown that errors because the thing was already gone turns one failure into two.

**Never remove anything you did not create.** Not the main checkout, not a branch that has not
landed, not a sibling workspace. A `teardown` that guesses is a data-loss bug with a routine
running it unattended.

## Rules

- **Never called by a loop.** If a loop is preparing a workspace, `ops-change` has been
  bypassed.
- **`prepare` leaves it buildable**, or reports why it could not.
- **Both actions are idempotent**, and `teardown` is safe on an absent workspace.
- **Teardown destroys only what prepare made.**
- **One workspace per change.** Never two changes in one tree — the whole point is that a
  failing build belongs to exactly one change.
