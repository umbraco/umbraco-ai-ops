---
name: ops-merge-loop
description: >-
  Sweeps the PRs a maintainer has labelled for landing and hands each to `ops-integrate ·
  land`, then reports what came back. It owns scheduling only — the sweep, the CI poll
  cadence and its 15-minute cap, the cap of 10 PRs per run, and the comment on each PR.
  Every merge gate, the release-base skip and the merge itself belong to `ops-integrate`;
  this loop never resolves a base branch or a merge strategy and never calls
  `ops-branching`. Repo-agnostic; runs locally or as a scheduled cloud routine. Trigger on
  "land the ready PRs", "run the merge loop".
---

# ops-merge-loop

The loop that removes the manual PR merge — the step where mistakes happen (merging red CI,
merging before approval, merging into the wrong base, forgetting the branch).

**It decides nothing about merging.** A maintainer labels a PR; this loop finds it, hands it
to **`ops-integrate · land`**, and says what happened. Every gate, the release-base skip and
the strategy live in that service.

**Policy in the service, scheduling in the loop.** That line is the whole design:

| This loop owns | `ops-integrate` owns |
|---|---|
| finding the labelled PRs | the landing-label gate |
| the CI poll cadence + its 15-minute cap | whether CI is green |
| the cap of 10 PRs per run | whether the PR is mergeable |
| commenting the outcome on each PR | whether the base is legitimate |
| when to stop | the merge itself, and the strategy |

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| **`ops-integrate · land`** | the command this loop exists to issue | service |
| **`ops-change · close-issue`** | after a merge only — the issue behind the PR closes when its last line lands | service |
| `ops-ci · status` | poll before handing over, so a pending PR costs one cheap read instead of a full gate run | cross-cutting (read) |
| `ops-repo-meta · identity` | the landing label, **by purpose** (`labels.land`) — never a hard-coded name | cross-cutting (read) |
| `ops-repo-meta · topology` | which repo holds the code, so the sweep looks in the right place | cross-cutting (read) |
| `ops-notify · send` | only when a human is blocking something | cross-cutting (infra) |

**It never calls `ops-branching`.** If this loop knows a branch name, the design has failed.
All GitHub reads and the comments go through **`github-ops`** by operation name.

## The `/goal`

```
/goal Every PR labelled <labels.land> on <code repo> is either merged with its branch deleted, or carries a comment naming the specific blocker. No PR left silently unhandled.
```

`/goal` is what makes "done" unambiguous — every candidate reaches one of those two states,
and there are no half-done merges.

## Step 1 — sweep

Resolve `labels.land` (`ops-repo-meta · identity`) and the `code` repo
(`ops-repo-meta · topology`). **List open PRs with that label** (`github-ops` → *List PRs by
label / state*).

No candidates → report "nothing to land" and stop. That is a normal outcome, not a problem.

**Cap: 10 PRs per run.** More than that, take the oldest ten and **log how many were
deferred** — never silently drop the tail. The next run picks them up.

## Step 2 — poll CI, then hand over

For each candidate, in order:

1. **`ops-ci · status`.** If `pending`, wait and re-read on a sane cadence, up to a
   **15-minute cap for the whole run**. Still pending at the cap → leave it for the next run.
   This poll is an **optimisation, not a gate**: it stops the loop paying for a full gate run
   on a PR whose CI has not finished.
2. **`ops-integrate · land`** with `{ pr: { repo, number } }`.

That is the entire decision. Do not pre-check the label, the base, the mergeability or the
reviews — the service checks all four, and a second opinion here is how the two drift apart.

## Step 3 — report the outcome

Read `outcome` and act:

| `outcome` | Do |
|---|---|
| `merged` | Comment confirming the merge, then **`ops-change · close-issue`** with the landed PR (see below). |
| `skipped:release-base` | **Say nothing.** The release path owns it; a comment here is noise on someone else's PR. |
| `blocked:ci` | Comment `detail` — the specific failing check. Leave the label on. |
| `blocked:conflict` | Comment `detail`. **Remove the label** — a conflict needs a human, and re-poking it every run is noise. Say in the comment that you removed it, and why. |
| `blocked:changes-requested` | Comment `detail`. **Remove the label** — a human said no. |
| `blocked:wrong-base` | Comment `detail`. **Remove the label** — retargeting is a human decision. |
| `blocked:no-label` | Say nothing; the label went away between the sweep and the gate. Not an error. |

**Leave the label on for anything that will clear by itself** (CI, a pending run) so the next
run re-checks. **Remove it for anything needing a human**, and always say which you did.

### Closing the issue behind a merge

After a `merged` outcome, call **`ops-change · close-issue`** with
`{ landed: { repo, pr_number, line } }`.

**Pass the PR, not an issue.** This loop does not know which issue the PR was for, and must not
guess: how a PR references its issue is a repo convention (a `Closes #N`, a full cross-repo URL),
and which lines are targets for that change is a repo fact. `ops-change` created the PR, so it
knows both.

It returns `closed: false` with `waiting_on` when other lines are still outstanding — **that is
the normal case on a multi-line repo, not a failure.** One logical change lands N times at N
moments, and the issue closes when the last one does. Report what it says and move on; do not
retry, and never close an issue yourself.

This is the only service this loop commands besides `ops-integrate`, and it is here for one
reason: this is the moment a landing becomes known, and nothing else is watching for it.

**Notify only when a human is blocking something** — `blocked:conflict`,
`blocked:changes-requested`, `blocked:wrong-base`. Use `ops-notify · send` with a stable
`key` such as `land-blocked-<repo>-<number>`, so a PR that stays blocked for a week does not
notify daily. A successful merge is not notification-worthy; the comment is the record.

## Guardrails

- **Never merge anything yourself.** `ops-integrate` merges. This loop has no merge path, no
  `github-ops` merge call, and no strategy.
- **Never resolve a base branch, a release base or a merge strategy.** You cannot get them,
  and must not want them.
- **Never re-implement a gate** to "save a call". The duplication that used to exist between
  this loop and its config is exactly the bug the capability model removes.
- **≤ 10 PRs per run; log the deferred.**
- **15-minute CI cap for the run**, not per PR — one stuck PR must not eat the whole window.
- **One comment per PR per run**, and don't repeat last run's comment verbatim when nothing
  has changed. A PR blocked for a week should not carry seven identical comments.
- **The landing label must be applied deliberately by a maintainer after review** — that act
  is the human gate, so control who can apply it.
- **Never use `fable`.**

## Running as a routine

**Primary: event-triggered.** `loop-dispatch` routes `pull_request.labeled` +
`ops/auto-merge` here, so labelling a PR fires it immediately. The loop sweeps *all* labelled
PRs, so a single-PR event just runs one pass of the same loop.

**Optional backstop:** a low-frequency poll (once or twice a weekday) catches a PR whose CI
went green *after* its event run hit the 15-minute cap. Not needed if you label after CI is
green.
