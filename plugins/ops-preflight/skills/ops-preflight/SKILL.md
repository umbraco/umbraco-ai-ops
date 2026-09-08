---
name: ops-preflight
description: >-
  Check whether a product repo is in a state where the loops will do GOOD work, before onboarding
  it. `ops-install` proves a repo is wired up; this proves it is worth wiring, because coverage
  matches skill names and a repo with no test command, no isolated build and an undocumented
  branch model onboards green and wastes every run. Reads the repo against a merged check catalog
  (engine base + every matching stack profile + the repo's own override), groups every check under
  the section of the source checklist it belongs to (release management and testing first, since
  they unlock the merge and release parts of the pipeline), and reports each as needed for the
  loops to work or as making them better rather than as a pass or fail grade. Three verdicts, never
  two: present, gap, and unknown for anything detection could not see. It never runs your build.
  Then it interviews the human on what the files could not answer and offers to file one issue per
  real gap. Advisory — it blocks nothing. Interactive, run before `/ops-install`.
  Trigger on "is this repo ready for ai-ops", "run the preflight", "readiness check".
---

# ops-preflight

Onboarding answers *"will the loops run in this repo?"* This answers the other half: **will they
do good work?**

They are different questions with different failure modes. `ops-install` can report full coverage
for a repo the loops will nonetheless waste every run on, because coverage matches capability
**names**, not the state of the product. A repo with no single test command, a build that cannot
run in an isolated worktree, and a branch model nobody wrote down passes onboarding and fails at
everything after it.

**It is not a loop** and **not a capability** — it implements no catalog action. Like
`ops-install`, a human runs it, and it takes no `-loop` suffix for that reason.

**It blocks nothing.** A repo is allowed to onboard with gaps and close them afterwards. What it
must not do is let anyone believe there are none.

## What it does, in order

| Step | Deterministic? |
|---|---|
| 1. Work out which check files apply | `scripts/select-profile.sh` |
| 2. Read the repo against them | `scripts/inspect.sh` |
| 3. **Ask about everything the files could not answer** | you, by interview |
| 4. Plan an issue per real gap | `scripts/plan-issues.sh` |
| 5. File them, on a yes | you, with `github-ops` |

## Three verdicts, never two

| Verdict | Set by | Printed as |
|---|---|---|
| **present** | detection matched | `present` + the evidence that matched |
| **present** | a human confirmed it | `present (declared)` — never with evidence |
| **gap** | a human said it is not there | `gap`. The only thing that becomes an issue |
| **unknown** | detection found nothing and nobody has been asked | `unknown` |
| **unknown** | a `signal` check matched — see below | `SIGNAL`, with what was found |

**Silence is never a pass.** This is the same rule as *a gate that cannot run reports blocked*:
a check nothing could answer reports `unknown`, not a pass. And a **self-reported yes is not
evidence** — that is why `present (declared)` prints differently from a detected one, and why
`inspect.sh` alone can never produce a `gap`. Only a human can say something is missing.

**Never summarise `unknown` away.** "18 unknown" is not "18 missing" and it is not "18 fine". It
is the count of questions still open, and reporting it as either of the other two is the one
failure mode of this skill.

## A map, not an entry exam

The data still carries two severities, `blocking` and `quality`. Nothing renamed them, and no
other tool that reads this data changed. What changed is how a human reads them. This is a
diagnostic map of a repo, not a pass/fail test, and nobody clears every box. The report says so at
the top, and prints each severity as what it means for the loops rather than as a grade:

| Severity (data, unchanged) | Printed as |
|---|---|
| `blocking` | **Needed for the loops to work** |
| `quality` | **Makes the loops better** |

## Step 1 — which checks apply

```
scripts/select-profile.sh <repo-root>
```

Three layers, merged by check `id` — later wins, **by field**, so a profile entry may carry
nothing but an `id` and the `detect` it is replacing:

| Layer | Where | Ships |
|---|---|---|
| base | `scripts/checks.json` | engine. Product-agnostic wording only |
| stack | `scripts/profiles/<stack>.json` | engine. Loads when its own `when` block matches |
| repo | `<repo>/.claude/ops-preflight-profile.json` | the consumer |

**Profiles are named for a stack, never a product**, and every matching one loads — a repo holding
both a solution and a `package.json` genuinely has both stacks and both sets of checks are true of
it. A check that is only true of one product belongs in that repo's own override file; layer 3
exists for exactly that, and putting a product fact in the engine breaks the golden rule.

## Step 2 — read the repo

```
scripts/inspect.sh <repo-root>          # the report
scripts/inspect.sh <repo-root> --json   # keep this; step 4 needs it
```

**Show the report verbatim.** It is the honest answer, and a summary of it is not — particularly
the `unknown` count.

**It groups by section, in a fixed order**, not alphabetically and not by which capability breaks:

1. Release management
2. Testing
3. Harness
4. Environment
5. Frontend
6. Backend
7. Best practices
8. Utilities
9. Misc

Release management and Testing come first because they are what unlock the merge and release
parts of the pipeline, and they are the two sections to do first if someone only has time for one.

**Within a section, severity is a sub-heading, printed once, not repeated per line.** A `blocking`
check sorts above a `quality` one, under its own **Needed for the loops to work** or
**Makes the loops better** heading:

```
Release management
  Needed for the loops to work
    [unknown] Something already knows how to prepare a release (ops-release cut)
              why:   Preparing a release ...
  Makes the loops better
    [unknown] After a release, the branches get put back in step (ops-release sync)
              why:   ...
```

Earlier this repeated the severity phrase on every row, comma-joined onto the title — "Needed for
the loops to work, Title" — which read as one broken sentence, and got worse the more checks a
section held. Printing it once per group instead is what keeps a 26-row report readable.

**It never runs your build.** A preflight that compiles the product only works on a machine that
can compile the product, which rules out CI, a routine, and anyone looking at a repo they do not
work in. It reads files. That is a deliberate ceiling, and it is why Step 3 is not optional.

### Read the evidence on a blocking `present` before you trust it

Detection is a **seed, not an authority** — the same stance `ops-install`'s `detect.sh` takes. A
glob is a guess, and a wrong `present` is worse than a wrong `unknown`, because it skips the
question instead of asking it.

So for every **blocking** check reported `present`, look at what matched. If the evidence is thin
or plainly the wrong thing — a build check satisfied by an unrelated script that happens to be
called `build-something.sh` — **treat it as unknown and ask anyway**. This costs one question and
is the only defence against a confident wrong answer.

### `SIGNAL` means the opposite of `present`

Some checks are marked `signal` in the catalog, and for those a **match is a reason to ask, never
a pass**. A `NuGet.config` proves a private feed *might* need a credential; it proves nothing
about whether a restore works without one. A `docker-compose.yml` says a build probably needs more
than a bare worktree — which is the argument *against* the default, not for it.

They print as `SIGNAL` with the evidence attached, and they count as `unknown`. **Always ask
these, and open with what was found:** *"There's a `NuGet.config` here — does a restore need a
credential for a private feed?"* That is a much better question than the blind version, which is
the entire reason the evidence is kept.

Before this existed, `dotnet-private-feed` found a `NuGet.config` and reported `present` for *"a
restore needs no credential"* — a false pass on a **blocking** check, for precisely the repos most
likely to fail. Found in a dry run against a synthetic repo, which is why there is one.

## Step 3 — ask about the rest

Two rules, the same two `ops-install` runs by.

**Batch them.** `AskUserQuestion` takes **up to four questions per call** and the human tabs
through them. Ask four at a time. Do not make four calls with one question each.

**Seed every option from what you already know.** `inspect.sh` just told you what is in the repo;
the `evidence` array on a nearby check is often the answer to the next question. A question
detection already answered is never asked, which is why a check with a `detect` block that matched
generates no question at all.

Ask in this order, and say why the order matters:

1. **In the printed section order**, release management and testing first, then harness,
   environment, frontend, backend, best practices, utilities, and misc last. That is the order a
   repo hits the problems, and it is why those two sections come first even if the human runs out
   of patience before the rest: they are what unlock the merge and release parts of the pipeline.
2. **Within a section, `blocking` before `quality`.** A blocking gap means a capability cannot be
   written; a quality gap means the loops run and produce worse work. If the human tires partway
   through a section, the ones that mattered there are done first.

A check with **no `ask`** is never asked. It is reported and left — some misses are worth showing
and not worth a question.

**Write the answers to a file** as a flat map of check id to verdict:

```json
{ "verify-test-command": "present", "release-trigger": "gap", "verify-ui-approval": "unknown" }
```

`unknown` is a legitimate answer and must stay available: *"I do not know"* is the truth
surprisingly often, and forcing it to `present` or `gap` invents a fact. It files nothing.

**Do not answer on the human's behalf.** Not from the repo, not from what seems likely, not from
what a similar repo did. Every value in that file came from a person, or it is `unknown`.

## Step 4 — plan the issues

```
scripts/plan-issues.sh <findings.json> <answers.json>
```

Only a `gap` becomes an issue. `unknown` never does — filing work for something nobody looked at
fills a backlog with noise, and it would quietly convert *"we could not see it"* into *"it is
missing"*.

The planned issues come out in the same fixed section order as the report (release management and
testing first, misc last, blocking above quality within a section), so the backlog reads in the
order a repo actually hits the problems.

## Step 5 — file them

**Ask first.** Filing issues on someone's repo is a visible, outward-facing write, and the plan is
useful on its own.

On a yes:

1. Create the `ops/preflight` label with **`github-ops` → `create-label`**. Idempotent, so it is
   safe on a re-run.
2. **Search for each title before creating it.** `create-issue` is **not** idempotent. The titles
   are stable precisely so a second run can find what is already open and file nothing; skipping
   the search turns a re-run into a duplicate backlog.
3. Create the rest with **`github-ops` → `create-issue`**, on the repo that holds issues. If
   `.claude/ops-repo-meta.json` declares `topology.issues`, that is the repo — not the one you are
   standing in.

Then say plainly what was filed, what was skipped as already open, and what is still `unknown`.

## Then what

Point at `/ops-install`. Preflight does not run it, does not gate it, and does not record that it
happened — **a "preflight passed" flag something later reads is the central config this design
deleted, arriving by the back door.** A repo with blocking gaps may still onboard; it will just
find the same gaps again the first time a loop runs, at a much worse moment.

## Rules

- **Never report `unknown` as a pass, or as a failure.** It is neither. It is a question nobody
  answered, and both roundings are lies in different directions.
- **Never answer a question for the human.** An inferred `present` is a gap you have hidden.
- **Never treat a detected `present` on a blocking check as proven without looking at the
  evidence.** A glob is a guess.
- **Never file an issue for an `unknown`.**
- **Never file without searching for the title first.** `create-issue` is not idempotent.
- **Never file anything without asking.** It is a write on someone's repo.
- **Never run the product's build, tests or lint.** The moment this needs a working toolchain it
  stops working in the places it is most useful.
- **Never put a product fact in `checks.json` or in a stack profile.** A product name, a product's
  tool, a product's command — all of it belongs in the repo's own
  `.claude/ops-preflight-profile.json`.
- **Never persist the run.** No report file, no flag, no score. Ask again next time.
