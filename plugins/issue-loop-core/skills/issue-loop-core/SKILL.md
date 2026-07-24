---
name: issue-loop-core
description: >-
  Generic orchestration that turns a repo's open `ready-for-ai` GitHub backlog into
  CI-green, reviewed, merged PRs. It owns the durable loop only — the queue, the `/goal`
  terminal condition, rolling cap-3 dispatch, the human-review-response phase, model
  selection, and the stop conditions/backstops — and knows NOTHING about how to build any
  one product. It reads the repo's `.claude/ai-ops.yml` for repo facts and locates the
  repo's OWN build skill via the `playbook` pointer (default `issue-loop`) — a repo-owned
  skill, scaffolded by ops-setup, that build subagents follow. Two modes chosen by the
  caller (default local): LOCAL — orchestrated, one isolated worktree + subagent per issue
  (cap 3), then a review-response loop until merged; CLOUD — one session per issue
  (event-triggered), CI as the test gate, build to a CI-green PR and stop. All GitHub/CI
  work defers to the github-ops skill; the base branch to release-and-branching. github-ops
  required. Trigger via loop-dispatch on Issue: Labeled `ready-for-ai` (cloud), or "work the
  ready issues" / "run the issue loop" (local).
---

# issue-loop-core

A durable, product-**agnostic** loop that turns the `ready-for-ai` GitHub backlog into
merged PRs. It owns *how to run the loop*; it does **not** own *how to build any one
product* — that lives in the **repo's own build skill** (see [The build skill](#the-build-skill)).

**How it's invoked.** `loop-dispatch` invokes it on a `ready-for-ai` event (cloud), or you
run it over a backlog (local). It is **not** parameterised by an injected "playbook"; it
reads the repo's **`.claude/ai-ops.yml`** ([`ai-ops.schema.json`](../../../../ai-ops.schema.json))
for repo facts and finds the repo's build skill from the `playbook` pointer. If there is no
`ai-ops.yml` and no build skill, stop and say so — there is nothing to build.

## The build skill

The per-issue build is a **skill the repo owns** — scaffolded by `ops-setup`, committed in
the repo's `.claude/skills/`, and named by `playbook` in `ai-ops.yml` (default `issue-loop`).
This core supplies the *orchestration* (queue, cap, `/goal`, review phase, model choice,
backstops); the repo's build skill supplies the *content* (what "implement this issue"
actually means for that product). This is the **override** point — a repo owns and edits its
build skill; the engine ships none.

When the core dispatches a build (or review-response) subagent, it instructs the subagent to
**follow the repo's build skill** (the one named by `playbook`), with the issue's
number/title/body substituted in — i.e. it **defers** to the repo skill located via the
config pointer. There is no same-name shadowing and no injected prompt: the pointer is how
the core finds what to run.

**The core never invents build steps.** Anything product-specific — the test command, the
toolchain, the file layout, project-specific worktree setup — lives **only** in the repo's
build skill and the repo's own `CLAUDE.md`. This skill contains no build steps and must
never grow any.

Review-response reuses the repo's build skill (its review-response section) or the bundled
[`rework-loop`](../rework-loop/SKILL.md) shape when the build skill defines none.

## Modes (set by the caller)

- **Local (orchestrated)** — default. You own a long-lived loop over the whole backlog:
  one isolated worktree + subagent per issue (cap 3), a build phase then a
  human-review-response phase. That's everything from *Config* through *Rules* below.
- **Cloud (one-shot per issue)** — set explicitly by the caller (a routine prompt says
  *run in cloud mode*). A routine fires once per `ready-for-ai` issue (cross-issue
  parallelism comes from separate sessions); you build that **one** issue to a CI-green PR
  with **CI as the test gate**, then **stop**. See [Cloud mode](#cloud-mode).

In **local mode** you are the **orchestrator**. You own a long-lived loop (it survives
across turns and scheduled wake-ups) whose terminal condition is: *every open
`ready-for-ai` issue is in a terminal state.* You reach it by dispatching **one subagent
per issue, each in its own isolated worktree**, capped at **3 running at once**.

Each issue has a two-part lifecycle:

1. **Build phase** — finite, autonomous, parallel (cap 3). A subagent runs the consumer's
   **build playbook**: implements the issue, reviews it, pushes, greens CI, opens a PR.
2. **Review phase** — long-lived, human-gated. You (the orchestrator) watch each PR for the
   human's review and, when changes are requested, dispatch a response subagent (the
   consumer's **review-response playbook**) that addresses the feedback, re-greens CI, and
   re-requests review. Repeats until the PR is approved and merged.

`/goal` is what keeps the loop alive between wake-ups and human waits — set it in Step 2 and
only clear it when the whole backlog is done (or you abort).

## Config (resolve once, up front)

Read from the repo's **`.claude/ai-ops.yml`** ([`ai-ops.schema.json`](../../../../ai-ops.schema.json)); auto-detect where derivable.

| Key | Meaning | How to resolve | Default |
|-----|---------|----------------|---------|
| `repos.inbox` | where `ready-for-ai` issues live | consumer declares it — **required when it differs from `repos.source`** | = `repos.source` |
| `repos.source` | where PRs open | auto-detect: the git remote (github-ops → *Detect base branch / repo*) | current repo |
| `branching.base` | PR base | detect via the `release-and-branching` skill (gitflow → `dev`) | per release-and-branching |
| `ci.provider` | which CI reports status | auto-detect (`github-checks` vs `azure-pipelines`); read via github-ops | `github-checks` |
| `repos.issue_link` | how a PR references its issue | `same-repo-closes` or `cross-repo-full-url` | `same-repo-closes` |
| `learning.inbox` | where `proto-learning` issues are filed | consumer declares it | — |
| `learning.routing` | where captured learnings route | consumer declares it | — |
| `playbook` | the repo's build skill this core defers to (the override point) | consumer declares it; scaffolded by ops-setup | `issue-loop` |
| AI label | the queue gate | fixed | `ready-for-ai` |
| Concurrency cap | parallel build subagents | fixed | **3** |

**Cross-repo (issues ≠ source).** When `repos.inbox` differs from `repos.source` (issues live
in a separate tracker from the code), **read the issue from `repos.inbox`** but **open the PR
on `repos.source`**. In that case `repos.issue_link` is `cross-repo-full-url`: reference the issue
with a **full URL** (`https://github.com/<repos.inbox>/issues/N`), **not** a `Closes #N` /
`#N` shorthand — a
bare `#N` resolves inside `repos.source` and a `Closes` keyword there would auto-close an
unrelated item. The full URL links the correct issue and never triggers a cross-repo
auto-close. When `repos.inbox == repos.source`, use `same-repo-closes` (`Closes #N`, which
closes the issue on merge).

**Confirm the repo fits the build skill.** The repo's build skill owns verifying it applies
to this repo (e.g. an early sanity check against the repo layout). If it reports the repo
doesn't match, stop and say so — a mismatched build won't succeed. The engine has no
separate repo-type config; applicability is the build skill's responsibility.

**GitHub operations** (list issues, open/merge PRs, check CI, read failing logs, push
files, …) go through the **`github-ops`** skill — name the *operation*, never a raw command.
CI status and failing logs also go through `github-ops`, which resolves `github-checks` vs
`azure-pipelines` per `ci.provider` — **do not assume GitHub checks.** **`github-ops` must
be installed for this loop to run.**

## Step 1 — gather the backlog

**List** the open issues labelled `ready-for-ai` on **`repos.inbox`** (github-ops → *List
issues by label / state*), reading each one's number/title/body.

- No matching issues → report "nothing labelled `ready-for-ai` is open" and stop. (If the
  label doesn't exist yet, say so — someone has to create and apply it before this loop has
  anything to do.)
- Otherwise build a queue of `{number, title, body}`. Announce the queue to the user
  (numbers + titles) before dispatching anything.

## Step 2 — set the goal

Set the durable terminal condition so the loop persists across turns / wake-ups. Make it
**satisfiable** — every issue reaching a *terminal* state, not every issue merged (a blocked
issue or an un-reviewed PR must not keep the loop alive forever):

```
/goal every open ready-for-ai issue in <repos.inbox> is in a terminal state — merged, or blocked-with-a-comment, or a CI-green PR awaiting the human's review with no unaddressed feedback — and no actionable work is left in the queue
```

Clear it with `/goal clear` when the goal is met or you abort. See
[Stop conditions](#stop-conditions) for exactly when the loop ends.

## Step 3 — build phase (rolling, cap 3)

Dispatch a **build subagent per issue**, at most 3 running at once. Dispatch the first 3 in a
single message (parallel); each subsequent dispatch happens when a running one completes and
frees a slot.

For each issue, spawn a subagent (`agentType: general-purpose`, background) instructed to
**follow the repo's build skill** (the one named by `playbook`) with the issue's
number/title/body substituted in. The repo's build skill — not this skill — owns the actual
build steps; the core only chooses the model, tracks the slot, and owns the waiting.

**Worktree isolation is the consumer's setup.** If the consumer's playbook creates a
project-specific (hook-backed) worktree itself, do **not** also pass `isolation: worktree` on
the Agent call — that would bypass the project's own setup. If the playbook does not manage
its own isolation, use the Agent tool's isolation so each subagent gets a clean worktree. The
rule is: **one isolated worktree per issue**; how it's provisioned is the playbook's business.

**You choose the model per issue** — see [Model selection](#model-selection). Triage the
issue's scope and pass the fitting tier as the Agent `model`.

Track each subagent's result:
`{issue, worktreeName, worktreePath, branch, prNumber, model, tier}`. A build subagent's job
is done when its PR is open and CI is green. If a build subagent reports it could not finish
(ambiguous issue, CI can't be greened), record it as **blocked** — the playbook will have
labelled the issue `ai-blocked` (removing `ready-for-ai`) and commented the reason; just
confirm that happened and move on — don't let one bad issue stall the queue.

Keep dispatching until the queue is empty and all build subagents have returned.

## Step 4 — review phase (loop until approved + merged)

Now every buildable issue has an open PR. For each PR, the human reviews it and you respond.
This phase is cheap waiting punctuated by short bursts of work.

**Watch for reviews.** Poll each open PR for new review activity — its review decision, review
state, and CI/merge status (github-ops → *Get a PR* + *Get PR CI / check-run status*).

Drive the wait with `ScheduleWakeup` (dynamic `/loop`) at a long interval (e.g. 1200s+)
rather than busy-polling — a human review can take hours or days. On a hosted/cloud run this
is the same shape: a scheduled routine that wakes, checks review state, acts, and re-arms.

For each PR, react to its review decision:

- **`CHANGES_REQUESTED`** (or new review comments) → dispatch a **review-response subagent**
  that follows the repo's build skill's review-response section (or the bundled
  [`rework-loop`](../rework-loop/SKILL.md) shape). It re-enters that issue's existing worktree
  (`EnterWorktree({ path })` if the playbook manages worktrees), addresses every comment,
  re-runs the reviews over the new changes, pushes, re-greens CI, replies to the review
  threads, and re-requests review. Only one response subagent per PR at a time, and only up
  to the review-round cap (see [Stop conditions](#stop-conditions)) — past that, hand the PR
  back for a human to resolve rather than ping-ponging.
- **`APPROVED`** → the human has accepted it. Merge per the `release-and-branching` skill
  (squash into `branching.base` for gitflow repos), confirm the merge, then have the worktree
  removed (`ExitWorktree` remove, or the repo's cleanup). Mark the issue done — the merge
  closes it if the PR/issue are linked in the same repo; on a cross-repo `repos.issue_link`, close
  the issue on `repos.inbox` with a note linking the PR.
- **Still pending / no review yet** → do nothing; re-arm the wake-up.

Repeat until every PR is approved + merged (or explicitly blocked). Then the `/goal`
condition holds — report the final tally and `/goal clear`.

## Model selection

The **orchestrator decides the model per subagent** — it has read each issue, so it triages
scope and picks the tier that fits, rather than paying top-tier for a copy tweak or
under-powering a substantial change. The orchestrator itself always **inherits the session
model** (don't pin it) — it's coordination and judgment, and pinning would fight `/model` and
the cloud routine's configured model.

Triage each issue at dispatch and pass the tier as the Agent `model`:

| Scope of the issue | Model |
|---|---|
| **Complex** — a new subsystem, cross-cutting change, tricky domain logic, anything with subtle correctness or wide blast radius | `opus` |
| **Standard** — a focused feature or bug fix in existing code, with its tests | `sonnet` |
| **Trivial, code-touching** — a one-line fix, a config tweak, a description change | `sonnet` |
| **Docs / non-code only** — README, comments, pure Markdown, no build/test impact | `haiku` (optional) |

**Floor:** never dispatch a code-touching issue below `sonnet`. `haiku` is only acceptable for
genuinely non-code work. When unsure, round **up** a tier — an over-powered build is cheaper
than a blocked one.

**Review-response subagents** reuse the tier the build subagent used for that issue (carried
in the tracking record). Bump **up** one tier if the human's feedback is architectural or the
change is proving harder than the build implied.

The tier names resolve to the current model in each family, so the skill doesn't go stale as
versions advance. Valid choices here are `opus`, `sonnet`, and `haiku` only.

**Never use `fable` — for any subagent, any issue, any tier.** It is not a valid choice in
this loop.

## Stop conditions

The loop ends when **no actionable work remains** — not only when everything is merged.
Actionable work = a queued issue, a running build/response subagent, or a PR with unaddressed
review feedback. When none of those exist, every remaining issue is already terminal:
**merged**, **awaiting the human** (CI-green PR, no new feedback), or **blocked** (labelled
`ai-blocked` with a comment explaining why).

What happens at that point depends on run mode:

- **Local / interactive** → stop. `/goal clear` and hand back a summary: what merged, what's
  awaiting your review, what's blocked and why. Re-invoke the loop later to resume —
  any reviews you've since left get picked up. Don't sit polling for a human when the human
  is right there.
- **Cloud / unattended** → don't stop; go **dormant**. Re-arm the `ScheduleWakeup` at a long
  interval and re-check next tick. End the routine only when everything is merged or a
  backstop below trips.

**Safety backstops (all modes) — stop touching an issue, label it `ai-blocked` (remove
`ready-for-ai`, comment why), and hand back if any trips:**

- **CI-green cap** — at most **8** attempts to green one PR's CI. After that, the issue is
  `ai-blocked` (comment the last failure).
- **Review-round cap** — at most **5** requested-changes rounds on one PR without reaching
  approval. After that, hand back — the disagreement needs a human.
- **No-progress guard** — never retry the same failing command/action verbatim. If a build or
  response pass produces no new state, treat the issue as blocked rather than looping.
- **Global backstop (unattended)** — bound total wake-ups / dispatches (or a wall-clock/date
  limit). When it trips, `log` what was left undone — never silently drop issues.
- **Label / issue changes** — if the `ready-for-ai` label is removed or the issue is closed
  mid-flight, drop it from the loop immediately.

## Capturing learnings (compounding)

Learning capture is **not implemented here.** It is **fully automatic and hook-driven** via
the separate **`learning`** plugin (installed alongside this one): read-only `SubagentStop`
and `SessionEnd` hooks analyse each transcript off the critical path and file
`proto-learning` issues (to `learning.inbox`) when something non-obvious happened — a
diagnosed CI failure, a repeated mistake, a missing/unclear pattern, a backstop that tripped.
A separate triage routine later turns those into PRs, routed per `learning.routing`.

**Neither the orchestrator nor any subagent files a learning by hand, and nothing in this
loop edits skills or `CLAUDE.md` inline.** Your only capture-related duty is *not* to fix
learnings inline — do the work well and let the hooks capture.

## Rules

- **Never touch an issue without the `ready-for-ai` label.** The label is the only gate. If a
  human removes it mid-flight, stop work on that issue. The one exception is the **outcome
  swap** the playbook performs on finishing: it removes `ready-for-ai` and adds
  `generated-by-ai` (green PR) or `ai-blocked` (backstop tripped) — that's the loop finishing
  the issue, not a human pulling the gate.
- **One isolated worktree per issue.** How it's provisioned is the consumer playbook's job
  (some ship a project hook that seeds a DB/port/deps; others rely on the Agent tool's
  isolation). The core's rule is only that each issue gets its own clean worktree — never two
  issues in one tree.
- **Build subagents are finite; the orchestrator owns the waiting.** A subagent must never sit
  waiting for a human review — it returns once its PR is green. All long waits (CI, human
  review) that span turns live in the orchestrator loop under `/goal`.
- **Reviews are non-negotiable.** Every build and every review-response pass runs the repo's
  security + code review over its changes and fixes what they surface before pushing. The
  consumer's playbook owns the exact commands; the core requires that it happen.
- **Follow the repo/playbook, not this skill, for specifics.** Test/build commands, the
  version-bump file list, and worktree cleanup live in the consumer's playbook, the repo's
  `CLAUDE.md`, and the `release-and-branching` skill — obey those.
- **Recap as you go.** After each dispatch, each subagent completion, each merge, give a
  one-line status (queue depth, in-flight issues, PRs awaiting review).
- **Capture, never fix.** Learnings are filed automatically by the `learning` plugin's hooks;
  do not edit skills or `CLAUDE.md` from inside this loop.

## Cloud mode

Everything above (Config → Rules) is **local mode**. **Cloud mode** is set explicitly by the
caller — the routine prompt says *run in cloud mode*. It's **event-triggered, one session per
`ready-for-ai` issue**, so there's **no cap-3 queue and no worktrees** — cross-issue
parallelism comes from separate sessions firing. The session is a **thin orchestrator on a
cheap base model**: it triages the one issue and dispatches a **single** build subagent on the
best-fit model — the same *Model selection* logic as local, just one subagent instead of up to
three.

For the one triggering issue (identify it from the event; if unclear, take the **oldest** open
`ready-for-ai` issue on `repos.inbox`; none → quiet no-op):

1. **Triage + dispatch.** Read the issue, pick its tier from
   [Model selection](#model-selection) (`opus` / `sonnet` / `haiku`; never `fable`; floor
   `sonnet` for code-touching work), and spawn **one** build subagent on that model instructed
   to follow the repo's build skill (named by `playbook`). The base session stays on a cheap
   model — it only triages, dispatches, and reports. *If the routine environment can't spawn a
   subagent with a model override, follow the repo's build skill **inline** on the routine's
   own model instead (set that to a sensible default, e.g. `sonnet`) and note it.*
2. **Build (in the subagent).** Work **directly in the session's checkout** — no worktree
   (cloud sessions are already isolated). Follow the **repo's build skill** with one
   substitution it must honour: **CI is the test gate.** Run whatever fast local
   sanity pass the playbook defines (a compile/build), but the full suite runs in CI, not in
   the session. Still run the repo's **security + code review** before pushing.
3. Push, open the PR against `branching.base` (referencing the issue per `repos.issue_link`), and
   **drive CI green** from the logs (github-ops → *Read a failing check's log*, resolved per
   `ci.provider`; the **8-attempt** cap applies).
4. **Mark the issue complete, then stop at the CI-green PR.** Once CI is green, run the
   playbook's outcome step on the triggering issue (on `repos.inbox`) — remove `ready-for-ai`,
   add `generated-by-ai`, comment the PR link. Removing `ready-for-ai` is what stops this
   routine re-firing on the same issue. Then **stop**: do **not** enter a review phase and do
   **not** merge — review-response is [`rework-loop`](../rework-loop/SKILL.md)'s job (it fires
   on the review event / `auto-rework` label), and merging is the merge-flow loop's.

**Not used in cloud mode:** the cap-3 queue, worktrees, and the review-response phase. The
**capture hooks** (`learning` plugin) still run in cloud, so self-learning capture happens
there too. The same guardrails hold — `ready-for-ai` is the only gate, reviews are
non-negotiable, follow the repo's `CLAUDE.md`, never leave CI red, and a blocked issue gets
labelled `ai-blocked` + a comment, then stop.
