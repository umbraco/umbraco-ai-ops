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

**Then take the direction off the ordered list.** `port_order` says which way changes travel:

| `port_order` | Targets |
|---|---|
| `upward` | every live line **after** the source line in `live` |
| `downward` | every live line **before** the source line in `live` |

**Position in `live`, never a comparison of version numbers.** A loop that parses `17` out of
`v17` has learned a product's naming scheme, and it breaks on the first line that is not `vN`.

> **Direction is the whole rule, and "every other live line" is wrong.** A repo can have a line
> that is live but is not a normal port target. Forms runs **v13, v17 and v18** with v17 primary
> and `upward`: a change landing on v17 ports to **v18 only**, because v13 comes earlier in
> `live` and takes security merges alone. "Every other live line" would open an unwanted v13 PR
> on every single change. The direction rule excludes it with no special case — and a security
> fix that lands on v13 still ports up to v17 and v18, which is what you want.

Then:

- **No targets** (the change landed on the newest line under `upward`, or the oldest under
  `downward`) → comment saying so and stop. That is a normal outcome, not a failure.
- **Skip any line that already has a port** for this issue — open or merged. A re-fired label
  MUST NOT open a second PR. This is the idempotency requirement and it is the one most likely
  to bite, because labels get re-applied by hand.

Announce the target list before doing anything.

## Step 3 — port, one line at a time

Work targets in `port_order` sequence — nearest line first. For each:

1. **`ops-change · implement`** with `{ issue, line, port: { from_line, commit } }`. The `port`
   block is what tells the repo it is porting and from where. **How** it ports — cherry-pick
   then adapt, or re-implement — is the repo's business, inside its own `ops-change`. The
   engine never learns the mechanism.
2. **`ops-change · verify`**. A port can fail on a line the original passed on; that is the
   entire reason it gets its own verify.
3. **The PR** — `ops-change` opens it onto that line's base.
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
- **Direction comes from `port_order` plus the order of `live`, never from a version number.**
  A loop that compares the `17` in `v17` with the `18` in `v18` has learned a product fact.
- **Never guess the source line.** Take it from the caller, or match it exactly once against the
  declared live set, or stop and ask. Everything else here depends on it.
- **Idempotent.** Same PR labelled twice must not open a second port. Check for an existing one
  before implementing, not after.
- **Never land a port.** Not even a green one.
- **The label is the confirmation.** No `ops/port`, no ports — a port is never opened without a
  maintainer asking for it.
