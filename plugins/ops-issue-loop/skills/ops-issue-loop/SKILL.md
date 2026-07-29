---
name: ops-issue-loop
description: >-
  Turns a repo's `ops/ready-for-ai` backlog into CI-green PRs by commanding `ops-change`
  (implement → verify) per issue. It owns the loop only — the queue, the `/goal`, rolling
  cap-3 dispatch, model choice per issue, the CI-green cap and the backstops — and knows
  nothing about how to build any product: that is `ops-change`, which the repo provides and
  which wraps its own workspace. It stops at a green PR and never merges; landing is
  `ops-merge-loop`, rework is `ops-rework-loop`. Two modes: LOCAL (orchestrated, cap 3) and
  CLOUD (one session per issue, CI as the test gate). Trigger via loop-dispatch on Issue:
  Labeled `ops/ready-for-ai`, or "work the ready issues".
---

# ops-issue-loop

A durable, product-**agnostic** loop that turns the ready backlog into CI-green PRs. It owns
*how to run the loop*. It does not own *how to build anything* — that is **`ops-change`**,
which the repo always provides.

**Where it stops matters.** A green PR, and no further. It does not merge, and it does not
handle review feedback. There is exactly **one merge path** in this engine
(`ops-merge-loop → ops-integrate`) behind exactly **one human gate** (the landing label), and a
second one here would defeat both.

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| **`ops-change · implement`** | do the work for one issue | service |
| **`ops-change · verify`** | prove it, this repo's way | service |
| `ops-ci · status` / `log` | drive CI green on the PR | cross-cutting (read) |
| `ops-repo-meta · identity` | the labels, **by purpose** — `labels.ready`, `labels.in_progress`, `labels.blocked` | cross-cutting (read) |
| `ops-repo-meta · topology` / `lines` | `issues` = where the backlog is, `code` = where the PR opens, and which line is primary | cross-cutting (read) |
| `ops-notify · send` | only when the loop gives up on an issue | cross-cutting (infra) |

**Never `ops-workspace`.** `ops-change` wraps it, because whether this repo needs a worktree, a
container or nothing at all is a product fact. **Never `ops-branching`** — `ops-change` opens
its own PR. **Never `ops-integrate`** — this loop does not land.

If the repo ships no `ops-change`, **stop and say so.** There is nothing to build, and no
default could be right.

## Modes

- **Local (orchestrated)** — default. A long-lived loop over the whole backlog: cap-3 parallel
  dispatch, each issue driven to a green PR. Everything down to *Rules*.
- **Cloud (one-shot per issue)** — set by the caller ("run in cloud mode"). One routine fire per
  labelled issue; build that **one** issue to a green PR with **CI as the test gate**, then stop.
  See [Cloud mode](#cloud-mode).

## Step 1 — gather the backlog

Resolve `labels.ready` and the `issues` repo. **List** open issues carrying that label
(`github-ops` → *List issues by label / state*), reading number, title and body.

- None → report "nothing is ready" and stop. If the **label does not exist**, say that
  explicitly: someone has to create it before this loop has anything to do.
- Otherwise build a queue of `{number, title, body}` and **announce it** (numbers + titles)
  before dispatching anything.

## Step 2 — set the goal

```
/goal every open <labels.ready> issue in <issues repo> is terminal — a CI-green PR awaiting the landing label, or blocked-with-a-comment — and no actionable work is left in the queue
```

Make it **satisfiable**: terminal, not merged. This loop cannot merge, so a goal that said
"merged" would never clear. Clear it with `/goal clear` when met or aborted.

## Step 3 — build (rolling, cap 3)

Dispatch **one subagent per issue**, at most **3 at once** — the first three in a single
message, then one per freed slot.

Each subagent, for its issue:

0. **Claim the issue, before doing any work.** Remove `labels.ready`, add
   `labels.in_progress`. Resolve both names from `ops-repo-meta · identity` — never invent
   them. **This is the first action, not a closing formality.** Removing the ready label is
   the only thing stopping a second event re-dispatching the same issue, and a build can run
   for many minutes: leave the label on during it and a re-fire produces a duplicate branch
   and a duplicate PR.

   > This step used to sit at the end, after CI went green, while still claiming to be what
   > prevents a re-fire. It could not be both. A live run ended with CI still building, so the
   > issue kept `ops/ready-for-ai` and never got its comment — the loop had followed the skill
   > exactly (29-07-2026).

1. **`ops-change · implement`** with `{ issue, line, port }`. `line` is the **primary line**
   from `ops-repo-meta · lines`; `port` is `null` here. This loop works the primary line only —
   porting to another line is its own change, with its own PR, verify and CI.
2. **`ops-change · verify`** on the branch it returns. Red → fix and re-verify, inside
   `ops-change`.
3. **The PR** — `ops-change` opens it (through `ops-branching`, privately). This loop never
   picks a base.
4. **Drive CI green** — `ops-ci · status`; on red, `ops-ci · log` then back to `implement` /
   `verify`. **Cap: 8 attempts.**
5. **Comment the PR link** on the issue. The labels were already swapped in step 0; all that
   is left is the link, and it should go on **as soon as the PR exists** (step 3), not after
   CI. A run that ends while CI is still building must still leave the issue pointing at its
   PR — otherwise the backlog shows untouched work that is actually half done.

Track `{issue, branch, pr_number, model, attempts}`. A subagent is done at a green PR.

**Never pass `isolation: worktree` on the Agent call.** `ops-change · implement` prepares its
own workspace via `ops-workspace`, and a second isolation layer around it bypasses the repo's
own setup — the seeded database, the claimed port, the restored dependencies.

A subagent that cannot finish records the issue as **blocked**: `labels.blocked` on, ready label
off, a comment saying why. Confirm that happened and **move on** — one bad issue must not stall
the queue.

## Step 4 — hand off and stop

Every buildable issue now has a green PR. **That is the end of this loop's job.**

- **Landing** is `ops-merge-loop`: a human reviews and applies `labels.land`. This loop must
  **not** apply that label — it is the human gate, and a loop that applies its own approval has
  removed it.
- **Review feedback** is `ops-rework-loop`, fired by the rework label.

Report the tally — what is awaiting review, what is blocked and why — and `/goal clear`.

**Notify** only for issues the loop **gave up on**, with a stable `key` per issue so a re-run
does not re-notify. A green PR is not notification-worthy; the comment is the record.

## Model selection

The orchestrator has read each issue, so it triages scope and picks the tier — rather than
paying top-tier for a copy tweak or under-powering a real change. The orchestrator itself
**inherits the session model**; pinning it would fight `/model` and the routine's own setting.

| Scope | Model |
|---|---|
| **Complex** — new subsystem, cross-cutting, subtle correctness, wide blast radius | `opus` |
| **Standard** — a focused feature or fix in existing code, with tests | `sonnet` |
| **Trivial but code-touching** — a one-line fix, a config tweak | `sonnet` |
| **Docs / non-code only** — no build or test impact | `haiku` (optional) |

**Floor: never dispatch code-touching work below `sonnet`.** When unsure, round **up** — an
over-powered build is cheaper than a blocked one. **Never `fable`**, for any subagent, any
issue, any tier.

## Stop conditions

The loop ends when **no actionable work remains**: no queued issue, no running subagent. Every
remaining issue is then terminal — a green PR awaiting the landing label, or blocked.

- **Local / interactive** → stop, `/goal clear`, hand back a summary. Don't sit polling when the
  human is right there.
- **Cloud / unattended** → the routine ends. There is nothing to wait for: this loop no longer
  watches for reviews, because `ops-rework-loop` is event-driven and `ops-merge-loop` owns
  landing. That is a real simplification, and it exists because the loop no longer merges — the
  old long-lived review phase was there only to serve its own merge.

**Backstops — stop touching the issue, label it `labels.blocked`, remove the ready label,
comment why:**

- **CI-green cap: 8** attempts on one PR. Then blocked, with the last failure in the comment.
- **No-progress guard** — never retry the same failing action verbatim. A pass that produces no
  new state means blocked, not another lap.
- **Global backstop (unattended)** — bound total dispatches or wall-clock. When it trips, `log`
  what was left undone; never silently drop issues.
- **Label or issue changed mid-flight** — ready label pulled, or the issue closed → drop it
  immediately.

## Capturing learnings

**Not implemented here, and not this loop's job.** The `ops-learnings` plugin's read-only
`SubagentStop` / `SessionEnd` hooks analyse each transcript **off the critical path** and file
`ops/proto-learning` issues to the `learnings` repo. `ops-triage-loop` sweeps them weekly.

**Neither this loop nor any subagent files a learning by hand, and nothing here edits a skill or
`CLAUDE.md` inline.** The only duty is *not* to fix a learning inline: do the work well and let
the hooks capture it.

## Rules

- **Never touch an issue without the ready label.** It is the only gate. The one exception is
  the outcome swap in Step 3 — that is the loop finishing an issue, not a human pulling the gate.
- **Never merge, and never apply the landing label.** One merge path, one human gate.
- **Never resolve a base branch, a merge strategy, or a workspace.** You cannot, and must not
  want to.
- **Ask for labels by purpose**, never by literal name — a repo may have renamed them.
- **Reviews are non-negotiable**: `ops-change · verify` owns running this repo's security and
  code review over the changes, and fixing what they surface before pushing. This loop requires
  that it happened; it does not define what it is.
- **Recap as you go** — one line per dispatch, completion and block.
- **Never use `fable`.**

## Cloud mode

Everything above is local mode. Cloud mode is **event-triggered, one session per issue**, so
there is **no cap-3 queue**: cross-issue parallelism comes from separate sessions firing. The
session is a thin orchestrator on a cheap base model that triages one issue and dispatches
**one** build subagent on the best-fit tier.

For the triggering issue (from the event; if unclear, the **oldest** open ready issue; none → a
quiet no-op):

1. **Triage and dispatch** — pick the tier, spawn one subagent. *If the environment cannot spawn
   a subagent with a model override, do the work inline on the routine's own model and say so.*
2. **Build** in the session's own checkout. `ops-change` will recognise it already has an
   isolated workspace and reuse it rather than nesting a worktree. **CI is the test gate**: run
   whatever fast sanity pass `verify` defines and let the full suite run in CI.
3. **Open the PR, drive CI green** (8-attempt cap).
4. **Swap the labels and stop.** Do not enter a review phase; do not merge.
