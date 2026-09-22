---
name: ops-port-loop
description: >-
  Land a change that has already shipped on one line onto this repo's other live lines. Fired
  by the port label on a merged PR, or by `ops-merge-loop` straight after it lands one. Works
  out the target lines from the repo's declared port order — never from a branch name a human
  typed — and drives each one through the repo's own `ops-change` as a real change with its
  own verify and CI. It never lands a port: each gets the same human gate as any other PR.
  Trigger via loop-dispatch on Pull request: Labeled `ops/port`.
---

# ops-port-loop

One logical change, N lines, N moments. This loop owns the "N" — nothing else in the engine
opens a port.

**A port is a real change, not a copy.** It gets its own branch, its own `verify`, its own CI
and its own review. Treating it as a mechanical cherry-pick is how unbuilt code lands on a line
nobody was watching.

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| `ops-repo-meta · lines` | live lines, and the **port order** that decides direction | cross-cutting (read) |
| `ops-repo-meta · topology` / `identity` | which repo holds issues, the label names by purpose | cross-cutting (read) |
| **`ops-change · implement`** | make the change on the target line, with port context | service |
| **`ops-change · verify`** | prove it, this repo's way | service |
| `ops-ci · status` / `log` | drive each port PR green | cross-cutting (read) |
| `ops-notify · send` | only when a port is abandoned | cross-cutting (infra) |

**Never `ops-branching`** — `ops-change` opens its own PR onto the right base. **Never
`ops-integrate`** — this loop does not land anything, including its own ports.

## Step 1 — check it actually landed

Read the PR: its merge state, its base branch, and the issue it closes.

- **Not merged yet.** Comment *"this will be ported once it lands"* and **stop**. Do not port
  from an open PR: review can still change it, and you would be copying something that never
  shipped. `ops-merge-loop` re-enters this loop the moment it merges, so nothing is lost.
- **Merged.** Take the **merge commit** — that, not the branch, is what gets ported. The branch
  may be deleted by the time you run.

**Merged is not the same as yours to port.** This loop has two entry points — the label event
and `ops-merge-loop`'s handoff — and a PR given the landing label and the port label together
fires **both**, for the same change. Neither is wrong and neither is removable, so the
arbitration is per target line and lives in step 2's claim rule. Reaching this point is not
permission to start.

## Step 2 — work out the target lines

Ask `ops-repo-meta · lines` for `live`, `primary` and `port_order`. **`live` is ordered oldest
first**, and that order is the whole of how you know which lines lie in the port direction.

**Name the source line first.** In order:

1. **The caller told you.** `ops-merge-loop` hands over the PR it just landed, its merge commit
   and its **line** — the one `ops-integrate · land` returned, which came from the only thing
   that holds the branch-to-line mapping. This is the normal path and the only reliable one.
2. **Fired by the label alone** (a human labelled an already-merged PR), so there is no caller.
   Match the PR's base ref against the live line names and accept **exactly one** match. Not
   one match, or more than one → **stop and ask on the PR** which line it is. Do not pick the
   closest, and do not carry on with a guess: every target below is derived from this answer, so
   getting it wrong ports the change to the wrong lines.

> **Why this is a lookup and not an inference.** The rule below says never read a line out of a
> branch name, and matching a base ref against the *declared* live set is not that: the names
> come from the repo's own data, the match must be exact and unique, and an ambiguous one stops
> the loop. What the rule forbids is deciding anything about a *base* from a string, and
> deriving "newer" by comparing the numbers in `v17` and `v18`. Neither happens here.
>
> There is no action that answers "which line is this PR on". `ops-branching` owns the
> branch-to-line mapping and is command-only by ruling, so this is the residue of that ruling,
> handled by asking a human rather than by guessing.

**Then take the targets off the ordered list, in two parts.** A change travels **to `primary`
first, and onward from there** in the `port_order` direction:

1. **Back to primary** — every live line strictly between the source and `primary`, plus
   `primary` itself. Empty when the source already **is** the primary line.
2. **Onward from primary** — every live line past `primary` in the `port_order` direction:
   after it in `live` for `upward`, before it for `downward`.

The targets are the two parts together with the source line removed. Work both out by
**position in `live`, never by a comparison of version numbers.** A loop that parses `17` out of
`v17` has learned a product's naming scheme, and it breaks on the first line that is not `vN`.

| `live` | `primary` | `port_order` | Source | Targets |
|---|---|---|---|---|
| `v17, v18` | `v18` | `downward` | v18 | v17 |
| `v17, v18` | `v18` | `downward` | v17 | v18 |
| `v13, v17, v18` | `v17` | `upward` | v13 | v17, v18 |
| `v13, v17, v18` | `v17` | `upward` | v17 | v18 |
| `v13, v17, v18` | `v17` | `upward` | v18 | v17 |

> **Why the direction is relative to the source and not absolute.** A one-way filter — "every
> line after the source under `upward`" — silently drops any change that lands *behind* the
> primary line, which is what an outside contribution opened against an older line normally is.
> Automate runs `live: [v17, v18]` with v18 primary and `downward`, so a PR based on v17 has
> nothing before it: a one-way rule reports no targets, stops, and v18 never gets the fix.
> Routing through `primary` sends it up to v18 and leaves every normal case exactly as it was.

> **It still is not "every other live line".** A repo can have a line that is live but is not a
> normal port target, and routing through `primary` protects it with no special case. Forms runs
> **v13, v17 and v18** with v17 primary and `upward`. Nothing ever targets v13: it sits behind
> `primary` in the direction opposite `port_order`, so neither part above can reach it, and it
> takes security merges a human lands on it directly. Those still port **up** to v17 and v18,
> which is what you want. "Every other live line" would open an unwanted v13 PR on every single
> change.
>
> That protection is **positional, not declared**: v13 is safe because of where it sits in
> `live`, not because anything marks it legacy. Flip that repo's `port_order` to `downward` and
> v13 becomes an ordinary target with nothing to warn you.

Then:

- **No targets** → comment saying so and stop. That is a normal outcome, not a failure, but only
  two things produce it now and one of them is a bug. **Say which it was**, because they read
  identically otherwise:
  - **`live` has one entry** — there is nowhere to port to at all.
  - **The source is `primary` and nothing lies past it** in the `port_order` direction. Name the
    source line and quote `live` in the order you read it, so a human seeing `live` the wrong way
    round can spot it. A reversed `live`, or a `port_order` pointing away from the rest of the
    repo, sends every change on the primary line straight down this path and nothing ever errors
    (a real onboarding did exactly that on 29-07-2026).
- **Skip any line that already has a port** for this issue — open or merged. A re-fired label
  MUST NOT open a second PR. This is the idempotency requirement and it is the one most likely
  to bite, because labels get re-applied by hand.
- **Then claim the line before you work it, and honour another run's claim.** The rule above is
  a check with no claim, and two runs in flight both pass it. Per target line, in this order:
  1. A port PR already exists for this issue on that line → **skip**, and say so.
  2. Otherwise read the source PR's comments for a claim marker for that line —
     `<!-- ops-port-claim: <line> -->` — posted in the **last 30 minutes**. Found → another run
     owns this line right now. **Skip**, naming the line and saying a twin has it.
  3. Otherwise post that marker on the source PR, inside a comment that also reads as English
     to a human (*"Porting to v17."*), and only then go to step 3 for that line.

  **A claim older than 30 minutes with nothing behind it is dead, and is ignored.** That is
  deliberate: a run that dies between claiming and opening its PR must not wedge the line
  forever. The claim only has to cover the gap between claiming and the PR existing, which is
  minutes. After that, rule 1 is the real guard, because it reads authoritative state.

  **It is a record, not a lock, and it is never cleared on success.** Nothing here is atomic,
  and two runs firing in the same second can still both claim. It closes the window that
  actually opened, not every window that could.

> **The incident this exists for (22-09-2026, `umbraco/Umbraco.Automate`).** A maintainer put
> `ops/auto-merge` and `ops/port` on a PR in the same second. That is **two** labelled events,
> so the edge router correctly fired **two** loops — `ops-merge-loop` and this one. The merge
> loop landed the PR and handed off to this loop again, exactly as it is meant to. The port
> therefore ran twice, from two entry points, and each opened its own PR onto v17 (#312 and
> #313 from one source, #314 and #315 from another).
>
> **Step 1's "not merged yet, stop" did not catch it**, because it asks about *now*. The label
> fired while the PR was open, the merge landed two minutes later, and by the time the cloud
> session read the PR it was merged. Both paths saw a merged PR and both went on. A guard
> phrased as a moment in time cannot hold against a run that reads at a different moment.
>
> **Nor did the branch name save it**, because the two entry points produced different ones —
> `v17/feature/create-content-action` from the label fire, `v17/feature/port-285-...` from the
> handoff, which knew the source PR. `ops-change` dedupes on the branch, so two names meant two
> branches and two PRs.

Announce the target list before doing anything.

## Step 3 — port, one line at a time

Work targets nearest first, measured as distance from the source line in `live`. For each:

1. **`ops-change · implement`** with `{ issue, line, port: { from_line, commit } }`. The `port`
   block is what tells the repo it is porting and from where. **How** it ports — cherry-pick
   then adapt, or re-implement — is the repo's business, inside its own `ops-change`. The
   engine never learns the mechanism.
2. **`ops-change · verify`**. A port can fail on a line the original passed on; that is the
   entire reason it gets its own verify.
3. **The PR** — `ops-change · implement` already opened it onto that line's base and returned
   `pr_number`. A returned branch with no `pr_number` is a failure for that line, not something
   to work around by opening the PR here.
4. **Drive CI green** — `ops-ci · status`, then `log` on red. **Cap: 8 attempts**, the same as
   the issue loop.
5. **Comment the port PR link on the issue**, saying which line it targets.

**Sequential, not parallel.** Ports of one change touch the same code on adjacent lines, and a
fix found on the first target usually applies to the next. Running them at once means finding
the same problem twice.

**A port that cannot be made green:** stop that line, comment on the **original PR** saying
which line failed and why, and `ops-notify · send`. Do **not** label the issue blocked — the
other lines may have succeeded, and the original change is fine. Then continue to the next
target: one bad line must not strand the others.

## Step 4 — stop

**Never apply the landing label to a port.** Each port PR goes through the same human gate as
anything else. A loop that approves its own work has removed the gate.

**Never close the issue.** `ops-change · close-issue` owns that, and it waits until every target
line has landed — which is exactly what this loop is creating the work for.

Report: which lines were targeted, which have a green PR, which failed and why.

## Rules

- **Port from the merge commit, never from an open PR.** Review changes things.
- **Targets come from position in `live`: back to `primary`, then onward in `port_order`.**
  Never from a version number. A loop that compares the `17` in `v17` with the `18` in `v18` has
  learned a product fact.
- **Never guess the source line.** Take it from the caller, or match it exactly once against the
  declared live set, or stop and ask. Everything else here depends on it.
- **Idempotent.** Same PR labelled twice must not open a second port. Check for an existing one
  before implementing, not after.
- **Never land a port.** Not even a green one.
- **The label is the confirmation.** No `ops/port`, no ports — a port is never opened without a
  maintainer asking for it.
