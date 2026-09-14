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
| 5. Score the repo, once every check is answered | `scripts/score.sh` |
| 6. File the planned issues, on a yes | you, with `github-ops` |

## Three verdicts, never two

| Verdict | Set by | Printed as |
|---|---|---|
| **present** | a STRONG pattern matched — see below | `present` + the evidence that matched |
| **present** | a human confirmed it | `present (declared)` — never with evidence |
| **gap** | a human said it is not there | `gap`. The only thing that becomes an issue |
| **unknown** | detection found nothing and nobody has been asked | `unknown` |
| **unknown** | only a WEAK pattern matched — see below | `ASK`, with what was found |
| **unknown** | a whole-product check found strong evidence for SOME active stacks, not all (see below) | `ASK`, naming the stack(s) with no strong evidence |

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

**Use the harness's own Glob and Grep to do the looking.** Three calls to this script, and the
searching in between is done by the tools you already have.

### 2a. Ask what to look for

```
scripts/inspect.sh <repo-root> --plan > plan.json
```

Each entry in `plan.json` is one lookup, and it is dropped straight into a tool call:

| Field | What to do with it |
|---|---|
| `tool` | `glob` means the **Glob** tool; `grep` means the **Grep** tool |
| `glob` | Glob's `pattern`, or Grep's `glob` filter. Hand it over **exactly as written** |
| `pattern` | Grep only: its `pattern`. Use `output_mode: "files_with_matches"` |
| `id` | The key to file the results under |
| `match`, `uses` | Not yours. Step 2c uses them |

The patterns need no editing because the catalog is written in the same glob language the Glob
tool speaks. `**` reaches into folders, a single `*` does not. If you find yourself rewriting a
pattern to make it work, the catalog is wrong and the fix belongs there, not here.

### 2b. Run them, in parallel

There are usually well over a hundred lookups, and they are independent. **Put many tool calls in
one message** so they run at once. A few at a time turns a fast step into a slow one.

Write the results to a file as `{"<id>": ["<path>", ...]}`, one key per lookup, an empty list for a
lookup that found nothing. Paths are **relative to the repo root**; trim the absolute prefix the
tools return. Record every path a tool gives back, and if a tool says it truncated a long list, say
so rather than presenting what came back as the whole of it.

### 2c. Turn the results into the report

```
scripts/inspect.sh <repo-root> --evidence evidence.json          # the report
scripts/inspect.sh <repo-root> --evidence evidence.json --json   # keep this; step 4 needs it
```

Every path is checked against the pattern that asked for it before it counts, so a stray result
changes nothing, and the verdict rules are the same ones that have always applied.

> **`inspect.sh <repo-root>` on its own still works and needs no harness at all.** It does the
> looking itself with `rg` and `grep`. That is what the tests exercise, and what to fall back on
> when something here misbehaves. It is slower: on Windows it starts around 1,400 programs, which
> costs about 26ms each, so a real repo takes half a minute. The two paths are asserted to produce
> identical findings, and if they ever disagree, the script is right and this step has a bug.

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

**`verify-build-command`, `verify-test-command`, `verify-lint-command` and `verify-warnings-clean`
live in Harness, not Backend or Frontend.** Each asks about the WHOLE product: "one command builds
THIS repo", not "one command builds the dotnet half", and the source checklist's Harness item is
"it runs all linting and tests to validate its own work", so the commands the harness runs belong
there, next to `verify-self-check`. `dotnet-analyzers` stays in Backend and `node-component-tests` /
`node-lockfile` stay in Frontend: those genuinely are stack-specific, so they stay where a
stack-specific check belongs. On a repo with real backend AND frontend code, this leaves Backend and
Frontend thin, and that is honest, not a bug: those sections were never about "how much backend or
frontend code exists", they are about what is stack-specific ENOUGH that a whole-product answer
would be the wrong shape for it.

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

### Evidence strength lives on the pattern, not on the whole check

Every detection rule in the catalog carries a **strength**, `strong` by default: STRONG means the
thing matched is named for, or dedicated to, the exact job the check is asking about — a script
literally named `build.sh`, a skill directory named `release-management`, a canonical file like
`version.json`. A strong match resolves the check straight to `present`, evidence shown, no
question.

WEAK means the match only proves something *exists*, not that it does *this* job — a `package.json`
proves a package exists, not that the published version lives there; an `azure-pipelines.yml`
proves CI exists, not that it publishes a release; a `NuGet.config` proves a private feed *might*
need a credential, nothing about whether a restore works without one. A weak match prints as
`ASK` with the evidence attached, and counts as `unknown`. **Always ask these, and open with what
was found:** *"There's a `NuGet.config` here — does a restore need a credential for a private
feed?"* That is a much better question than the blind version, which is the entire reason the
evidence is kept.

One check can hold **both** kinds of pattern at once. `release-version-source` treats `version.json`
as strong (it is the dedicated file) and `package.json` as weak (it is a generic manifest that
happens to also exist) — a repo with only `package.json` still gets asked; a repo with `version.json`
resolves straight to `present`. A check where **no** file could ever prove the positive fact — only
ever hint that it might not hold — is still marked `signal: true` at the check level instead of
tagging every pattern `weak` individually; `workspace-isolated-build` and `dotnet-private-feed` are
the two that stay this way, because no detectable file proves a bare worktree suffices or that a
restore needs no credential.

Before pattern strength existed, `dotnet-private-feed` found a `NuGet.config` and reported `present`
for *"a restore needs no credential"* — a false pass on a **blocking** check, for precisely the
repos most likely to fail. Found in a dry run against a synthetic repo, which is why there is one.
A second dry run, against a real repo with three genuine release skills, then surfaced the opposite
problem: `signal: true` asked about all three in the same tone it would ask about a stray file that
merely had "release" in its name — because a whole-check flag cannot tell strong evidence from
weak. Pattern strength is the fix: `release-prepare` and `release-cleanup` now resolve straight to
`present` when a skill directory is genuinely named for the job, and only ask when the evidence is
generic.

### Evidence: strong first, weak second, never the same file twice

A row's evidence line shows what actually matched, split by strength rather than mixed together:
a reader has to be able to tell which file earned a `present` without guessing.

```
    [PRESENT] The version lives in a known file (ops-release cut)
              found: version.json
              also seen (weak): Directory.Build.props, package.json
```

`found:` is always the STRONG matches: what earned the verdict, if the row is `present` at all.
`also seen (weak):` only appears when there is ALSO weak evidence, so a reader can see the rest of
what was found without mistaking it for what earned the pass. A row with no strong evidence at all
(an `ASK`) still gets one plain `found:` line, the same as always. A file that happens to match
both a strong pattern and a weak one on the same check (a `post-release-cleanup` skill matches both
the strong `*post-release*` glob and the weak `*clean*` one) is shown only once, under `found:`,
never repeated under `also seen (weak):` as if it were separate evidence.

**JSON never hides a match, strong or weak. Text still caps, but only the weak list, never the
strong one.** A real dry run found four `.claude/skills/...` entries (alphabetically first, and
weak) filling every slot of a 3-item cap and pushing a genuinely strong `azure-pipelines.yml` match
out of the report entirely: a false claim that the file was not detected. `evidence_strong` and
`evidence_weak` in the JSON report are both complete, always; only the TEXT rendering of
`evidence_weak` caps at 3 with a trailing `(+N more)`, because a weak match is supplementary
evidence, never what a `present` rests on. A check can legitimately show dozens of strong matches
in text (twenty-two integration test files is twenty-two lines of real evidence), and that is the
correct trade: never hiding a strong match matters more than a short report.

### Whole-product checks need EVERY active stack, not just one

`verify-build-command`, `verify-test-command`, `verify-lint-command` and `verify-warnings-clean` are
marked `whole_product: true` in the catalog (see `checks.schema.json`) because their QUESTION is
about the whole repo, not one stack. On a repo with only one active stack profile this changes
nothing. On a repo with **two or more** (a repo with both a `.sln` and a `package.json`, which
loads both the `dotnet` and `node` stack profiles), a strong match tagged to only ONE of them can no
longer resolve the check to `present`. This is the OR-union problem `signal: true` originally
existed to prevent, coming back through pattern strength: a real `npm test` script is genuinely
strong evidence that the front-end half is tested, and proves nothing about the dotnet half sitting
right next to it. A repo reporting `present` on `verify-test-command` from front-end evidence alone,
while an equivalent dotnet-only repo reports `ASK` for the identical check, was found in a real dry
run, and this is the fix for it.

```
    [ASK    ] One command runs the tests (ops-change verify)
              found: src/StaticAssets/package.json
              also seen (weak): Tests/FooTests.cs (+383 more)
              no strong evidence from: dotnet
              why:   A verify that cannot run the tests reports a pass that means nothing. ...
```

`no strong evidence from: <stacks>` only appears on a `whole_product` check that found strong
evidence for some active stacks but not all: that is `source: partial` in the JSON, a third
`unknown` source alongside `weak` and `null`. A strong match with no stack tag at all (a literal
root `build.sh`, `test.sh` or `lint.sh`) counts for every active stack at once, because a real
repo-wide command genuinely answers the question regardless of how many stacks the repo has. It
does not need to be repeated once per stack to satisfy this rule.

## Step 3 — ask about the rest

**Read what the repo already says about itself, first.**

```
scripts/list-skills.sh <repo>
scripts/list-skills.sh <repo> --json
```

A repo's own skills are a short, purpose-written index of what this codebase knows how to do, and
they answer preflight questions outright. A live repo had a `repo-setup` skill describing "git
hooks, demo site creation, and dependency installation", a `session-hook-config` skill naming
"dotnet restore fails with 401 errors", and a `demo-site-management` skill. All three questions
were asked anyway, because nothing read them.

It also reports engine skills the repo already has. That same repo had four, so it was
part-onboarded and preflight never said so.

**A description is a claim, never a verdict.** It says what a skill means to do, not that it works,
and the same repo proves the difference: it ships `repo-setup` and still answered "no, a bare
worktree is not enough, it needs a demo site stood up". So this never resolves a check. Use it to
put the name in front of the person and let them answer.

**Four questions per call is the tool's limit, not a choice made here.** `AskUserQuestion` accepts
at most four, and the human tabs through them. So ask four at a time: do not make four calls with
one question each, and do not plan around a single call that asks everything, because no such call
exists.

**Must-haves first, then stop and offer the rest.** Ask every `blocking` question, then **stop**,
report what is known so far, and say how many `quality` questions are left, offering them as a
second sitting. A live run against a real repo asked eighteen questions in one go, which is more
than anyone answers well; the must-haves are around nine, and they are the ones that decide
whether the loops can start at all. Section order holds inside each pass: release management and
testing first, then harness, environment, frontend, backend, best practices, utilities, misc. That
is the order a repo hits the problems, and it is why those two come first if patience runs out.

**Seed every option from what you already know.** `inspect.sh` just told you what is in the repo;
the `evidence` array on a nearby check is often the answer to the next question. A question
detection already answered is never asked, which is why a check with a `detect` block that matched
generates no question at all.

**Write the questions in the repo's own words, not the engine's.** Nobody running this has
installed anything yet, so a question naming `ops-change`, `ops-release` or a capability means
nothing to them. The shipped `ask` and `why` text is already free of those names and
`inspect.test.sh` fails if one comes back; do not reintroduce them when writing the options.

### *"I do not know"* is an answer, and also a prompt to go and look

Keep the option on every question. It is the truth surprisingly often, and forcing it to `present`
or `gap` invents a fact.

But **do not record it and move on.** Take one targeted look for the thing the question was about.
Start with the skill list above, which is the highest-yield place by a distance, then that check's
`detect` patterns, then the obvious places a repo keeps it. Put the question back with what you
found:

> I looked. `package.json` has a `lint` script that runs eslint and exits non-zero, and
> `CLAUDE.md` links to `docs/coding-standards.md`. Does that answer it?

**The look never sets the answer.** It gathers evidence and hands it back; the person still
decides. If they still do not know, the verdict is `unknown` and it stays there. This matters
because it is cheap: two of the three unknowns in a live run against a real repo were a lint
script and a `CLAUDE.md` link, both sitting in files nobody had opened.

A check with **no `ask`** is never asked, and is reported and left. Every check this plugin ships
has one, and a test fails if a new one arrives without it, because a check nobody can answer stays
`unknown` forever and silently blocks the score.

**Write the answers to a file** as a flat map of check id to verdict:

```json
{ "verify-test-command": "present", "release-trigger": "gap", "verify-ui-approval": "unknown" }
```

**Do not answer on the human's behalf.** Not from the repo, not from what seems likely, not from
what a similar repo did. Showing someone what you found is not the same as deciding for them:
every value in that file came from a person saying so, or it is `unknown`.

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

## Step 5 — score it

```
scripts/score.sh <findings.json> <answers.json>
scripts/score.sh <findings.json> <answers.json> --json
```

Same two inputs as Step 4, and the same resolution: an answer overrides what `inspect.sh` found,
and a check nobody answered keeps whatever verdict it already had.

**A score is only honest after the interview.** If even one check still reads `unknown`, this
prints **no score and no percentage**, only the counts that are known, and how many questions are
still open. Guessing at the rest would let a well-prepared repo take a low number for having files
this tool cannot read, which is exactly the failure mode the rest of this skill exists to avoid:

```
No score yet.

Needed for the loops to work: 1 of 2 present
Makes the loops better: 1 of 2 present

Release management
  Needed for the loops to work: 0 of 1 present
...

2 checks are still unknown. Finish the interview (step 3 in the ops-preflight
skill), then run this again for a score.

Loops can start: no. 1 check needed for the loops to work is not present yet: ...
```

Once every check reads `present` or `gap`, it scores. `blocking` weighs 3, `quality` weighs 1, a
must-have outweighs a nice-to-have, and the score is the weight of what is `present` over the
weight of everything.

**There is no letter grade.** There was one, an `A*` to `F` band table with a hard cap at `C`, and
it is gone on purpose: a letter reads as a verdict on the people who built the repo, which is the
one thing this report must never be. What the cap used to do is now a plain sentence printed next
to the number whenever a must-have is a gap, so quality polish still cannot paper over something
the loops actually need:

```
Readiness score: 85%
A check needed for the loops to work is a gap, so that number reads higher than the
repo is ready. The checks named at the bottom are the ones to close first.

Needed for the loops to work: 4 of 5 present
Makes the loops better: 5 of 5 present
...

Loops can start: no. 1 check needed for the loops to work is not present yet: ...
```

With nothing blocking, the number stands on its own:

```
Readiness score: 83%
```

The score is a snapshot of the repo as it stands, never a judgement on the people who built it,
the same stance the rest of this report takes. It never persists either: run `score.sh` again next
time, the same as everything else here.

## Step 6 — file them

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
- **Never score while any check is still `unknown`.** `score.sh` refuses and prints the known
  counts instead. A raw scan is mostly `unknown`; scoring it would hand a well-prepared repo a low
  number for having files this tool cannot read.
- **Never hand out a letter grade.** A percentage and the counts, nothing that reads as a verdict
  on the people who built the repo.
- **Never let a good score hide a missing must-have.** Any blocking `gap` is named in words right
  beside the number, whatever the rest of the repo looks like.
- **Never persist the run.** No report file, no flag, no stored score. Ask again next time; score
  again next time, freshly, from whatever the interview says then.
