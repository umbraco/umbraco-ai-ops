---
name: ops-release-loop
description: >-
  Event-triggered release with no mid-flow human approval, guarded by two automated gates:
  green CI, then an Opus pre-publish review against a repo-overridable checklist. When an
  issue titled `release <version>` is labelled `ops/auto-release`, it commands
  `ops-release · plan / cut`, drives CI green, runs the review (a BLOCK stops it), then
  `publish` and `sync`, and comments + closes the triggering issue. All release mechanics
  live in the repo's `ops-release`; this loop only orchestrates and gates, and never touches
  `ops-branching`. Requires github-ops. Trigger from a routine on Issue: Labeled =
  ops/auto-release, or run manually as "release <version>".
---

# ops-release-loop

The release loop: **issue-triggered and CI-gated, with no mid-flow human approval.** Two
deliberate signals are the go-ahead — a maintainer opened an issue naming the version and
applied the **`ops/auto-release`** label, and **CI on the release PR is green**. No approval
pause, by design, for fast beta cycles.

> **Publishing is irreversible.** Once the gates pass this ships with no further human look,
> and a published version cannot be cleanly un-published. Use it only where CI-green plus the
> pre-publish review is a sufficient gate. The deliberate label is the one human decision.

## Orchestrate and gate; the repo does the release

**Every release mechanic belongs to `ops-release`, which is always repo-provided.** Version
files, changelog format, the publish target, tagging, the back-merge: all product facts. This
loop owns the sequence and the two gates, and nothing else.

| This loop owns | `ops-release` owns |
|---|---|
| parsing the version from the issue | what a version *is* in this repo |
| the CI poll and its cap | — |
| the pre-publish review gate | — |
| commenting + closing the trigger issue | branching, bumping, tagging, publishing, back-merge |
| notifying a human | — |

**There is no framework default for `ops-release`.** A repo without one cannot release, and
that is correct: the engine has no business guessing how a product ships.

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| **`ops-release · plan`** | turn the trigger into release facts | service |
| **`ops-release · cut`** | branch, bump, changelog, open the release PR | service |
| **`ops-release · publish`** | tag, push artifacts, publish notes | service |
| **`ops-release · sync`** | put the line's branches back in step | service |
| **`ops-change · implement` / `verify`** | only to fix a red release branch — see Step 2 | service |
| `ops-ci · status` / `log` | the CI gate, and the failing log to act on | cross-cutting (read) |
| `ops-repo-meta · identity` / `topology` | the release and release-blocked labels by purpose (`labels.release`, `labels.release_blocked`); which repo holds issues | cross-cutting (read) |
| `ops-notify · send` | start, block, completion | cross-cutting (infra) |

**It never calls `ops-branching`.** Release branches and bases are `ops-release`'s business,
and `ops-release` reaches `ops-branching` itself if it needs to. Reporting on the trigger issue
goes through **`github-ops`**, against the `issues` repo from `topology`.

## The `/goal`

```
/goal Release <version> of <repo>: cut, CI-green, pre-publish review passed with no BLOCK, published with its tag and release notes, the line synced, and the triggering issue commented and closed. Not met until sync has run.
```

The sync is in the goal because it is the step manual releases most often forget.

## Step 0 — the trigger

- Fired by `loop-dispatch` on `issues.labeled` + the release label (`labels.release` from
  `ops-repo-meta · identity`), or run manually as "release &lt;version&gt;".
- **Version = the triggering issue's title**, e.g. `release 18.0.0-beta.3` → `18.0.0-beta.3`.
  If the title has no clear `release <version>`, **comment on the issue asking for one and
  stop.** Never guess a version.
- **Notify** (`ops-notify · send`, key `release-start-<repo>-<version>`): releasing
  `<version>` from issue #n.

## Step 1 — plan, then cut

1. **`ops-release · plan`** with `{ trigger: { issue_number, version_text } }`. It returns the
   line, the version and the units of work. It opens nothing.
2. **`ops-release · cut`** with that plan. It returns the release PR.

`cut` is **idempotent**: re-running returns the existing release PR rather than opening a
second. So a re-fired routine is safe, and this loop must **not** add a "did I already cut?"
check — that belongs in the action.

## Step 2 — drive CI green

**`ops-ci · status`** on the release PR until it settles.

- **Green** → Step 3.
- **Red** → read the failing log (`ops-ci · log`) and hand the fix to **`ops-change ·
  implement`**, then **`ops-change · verify`**, on the release branch. Re-check CI.
  **Cap: 8 attempts.** A release branch that will not go green is a stop, not a retry forever.
- **Still pending at the cap** → stop, comment on the issue, leave the PR open.

**Never publish on red.** Never treat a mergeable state as evidence of green — with no branch
protection, the forge will allow it.

If CI cannot be made green: **stop**, comment the blocker on the triggering issue, leave the
release PR open, and leave the label on so a human can decide.

## Step 3 — the pre-publish review (second gate)

Once CI is green, and **before anything irreversible**, run the **`release-reviewer` agent**
(defined in this plugin — judgement-only Opus; what it checks lives in its own definition).

**You gather the facts; the agent reads nothing.** The agent's only tool is `Read`, and its
only legitimate target is the engine default checklist that ships beside this skill. It has no
way to fetch a file and must never be pointed at the working tree, because a local checkout can
be stale, on another branch, or absent — a gate that judged the wrong content would still
report a pass. So everything it judges comes from you, through `github-ops`, from the forge's
API.

**Resolve the head SHA first**, and fetch every file at that SHA. The PR can move while the
loop is mid-flight; facts gathered without pinning may describe a commit that is no longer what
would publish. Pass in:

1. **PR number**, title, body, head branch, **head commit SHA**, base branch.
2. The target **version** and the **line** it targets.
3. The **triggering issue**'s title and body.
4. The **diff** (changed files + size), **CI status per check**, and **mergeability**.
5. **The version-file list** from `ops-release · plan` — the literal paths that were supposed
   to be bumped, so the agent can spot one that was missed entirely rather than only judging
   the files it was handed.
6. **The content of those version files and the changelog, fetched at the head SHA.**
7. **The resolved checklist.** Look for the repo's own — `.claude/release-review-checklist.md`,
   then a repo-root `release-review-checklist.md` — **at the head SHA, through `github-ops`**,
   and pass its content and path when one exists. Say so explicitly when the repo ships none,
   and the agent falls back to the engine default
   ([`references/release-review-checklist.md`](references/release-review-checklist.md)). The
   checklist is an extension point, not a fixed list.
8. **A note per failed fetch**, in the form `could not fetch <path> at <sha>: <error>`, for any
   file that should have been there. Never drop a failed fetch silently: the agent scores a
   check it cannot judge as a BLOCK, which is the point.

It returns **VERDICT: PASS** or **VERDICT: BLOCK + findings** with a per-check scorecard, and
this loop gates on the verdict — the agent cannot publish.

> **The routine's `allowed_tools` must include the Agent/Task tool.** If the agent cannot be
> spawned, the gate has **not run** — treat that as a **BLOCK** and follow the BLOCK path
> below. Do **not** fall back to reviewing inline on the loop's own model.
>
> An earlier version of this step did exactly that, and it was wrong twice over. A gate the
> release driver performs on itself is not a second gate; it is the same judgement that
> decided to release, asked again. And "reviewed inline" reads in a comment as *reviewed*, so
> the release ships with a gate everyone believes held.
>
> This is not hypothetical. The `umbraco-mcp-ops` prototype shipped PRs reporting a passed
> review that had never run: its review skills carried `disable-model-invocation: true`, so a
> headless subagent received them as inert text rather than executing them, and nothing
> noticed (their PR #39). **A gate that cannot run must say so and stop. It must never
> report a pass.**

On any **BLOCK**: do not publish. Then, in order:

1. **Open an issue** titled `Release <version> blocked by pre-publish review`, detailing every
   BLOCK finding (which check, what is wrong, why) and linking the release PR and the trigger
   issue. Label it with **`labels.release_blocked`** from `ops-repo-meta · identity`, by purpose
   and never the literal name, if that label exists on the repo.
2. **Notify** (`ops-notify · send`, `urgency: high`, key `release-blocked-<repo>-<version>`) —
   a human is now blocking a release.
3. **Comment on the trigger issue** pointing at the blocked issue and the PR, and **remove the
   release label** so the loop does not re-fire until a human fixes the cause and re-labels.

**WARN** findings → proceed, and include them in the completion comment.

## Step 4 — publish, then sync

1. **`ops-release · publish`** with the plan and the merge commit. It tags, pushes the
   artifacts and publishes the notes, marking a prerelease where the version says so.
2. **`ops-release · sync`** for that line. **The `/goal` is not met until this has run** — see
   [`references/sync-contract.md`](references/sync-contract.md) for what it owes.
3. **Comment the outcome** on the trigger issue (release link, tag, "line synced") and
   **close it**, on the `issues` repo from `topology`.
4. **Notify** (key `release-done-<repo>-<version>`): released `<version>`, line synced.

## Guardrails

- **Two gates before publish: CI-green AND the pre-publish review.** Never publish on red,
  never with an open BLOCK. These are the loop's own gates and **delegation never bypasses
  them** — `ops-release` doing the mechanics does not make it responsible for the gate.
- **A BLOCK is always surfaced, never silent** — an issue *and* a notification, then de-label.
- **Never skip `sync`** (except where the model has no separate release base, which `sync`
  itself reports as a no-op). An un-synced line is the classic release mistake.
- **Never force-push.**
- **One release per triggering issue**, version from that issue's title only.
- **Never resolve a branch, a base or a merge strategy**, and never call `ops-branching`.
- **8 attempts** to get a release branch green, then stop and report.
- If the version is ambiguous, **stop and ask on the issue** rather than shipping something
  unverified.
- **Never use `fable`.**

## Running as a routine

`loop-dispatch` routes `issues.labeled` + `ops/auto-release` here, so labelling a
`release <version>` issue fires it. The version comes from the issue, so nothing else needs
configuring per run. The environment needs this skill, `github-ops`, `ops-capabilities`, and
the repo's own `ops-release`. *(The label must exist on the target repo.)*
