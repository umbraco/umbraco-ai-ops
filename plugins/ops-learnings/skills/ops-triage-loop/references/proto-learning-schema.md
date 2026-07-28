# Proto-learning schema

A **proto-learning** is a raw, un-triaged observation captured while a loop was working: a CI
failure someone had to diagnose, a mistake repeated, review feedback that revealed a pattern, a
blocker, a gap in a skill or in `CLAUDE.md`.

**It is not a fix.** It is a note that *something is worth improving somewhere*.
[`ops-triage-loop`](../SKILL.md) reads these later, clusters them, applies a threshold, and
routes each cluster to the repo that owns it.

Because a plugin is read-only once installed — and absent entirely on a stateless runner —
proto-learnings cannot be stored in the skill. They are filed as **GitHub issues** on the
**`learnings`** repo (the role from `ops-repo-meta · topology`, which defaults to the code
repo), labelled **`ops/proto-learning`**.

**Capture is automatic — this file is the contract, not a manual checklist.** The
`SubagentStop` / `SessionEnd` hooks run a read-only analyzer over the finished transcript; the
analyzer applies the rules below and emits a decision, and the hook files the issue. **Nobody
files one by hand.** This doc tells the analyzer (a) when a learning is worth filing and (b) the
exact record shape to emit.

## When to file — and when not to

**File one when something non-obvious happened** that a future run, or the skills themselves,
should benefit from:

- a CI failure that had to be diagnosed, especially a recurring or repo-specific one,
- a mistake made because a pattern was unclear, missing or wrong in the skills,
- review feedback pointing at a **systemic** gap, not a one-off nit,
- a blocker: an ambiguous issue, an environment problem, un-greenable CI,
- a repo-specific gotcha, true only of this repo,
- a cross-repo pattern worth promoting into shared tooling.

**Do not file** for a clean, by-the-book run where nothing was learned. **Silence is correct
when the run was uneventful** — the inbox has to stay signal, not noise, because triage clusters
by judgement and noise makes every cluster harder to read.

**One proto-learning per distinct lesson.** Never bundle unrelated observations: they would be
routed to one home, and at most one of them belongs there.

## Format

- **Repo:** the `learnings` role — see above
- **Label:** `ops/proto-learning`
- **Title:** `[proto-learning] <source-repo>#<issue>: <one-line lesson>`
- **Body:** a single fenced `json` block — the machine-readable record, so triage can parse it
  deterministically — followed by a short freeform **Notes:** section for anything that does not
  fit the fields.

### The JSON record

```json
{
  "sourceRepo": "owner/name",
  "sourceIssue": 4211,
  "pr": 8890,
  "category": "ci-failure",
  "lesson": "One-line statement of what should change or be remembered.",
  "detail": "What happened, in enough detail to act on later without the transcript.",
  "fix": "What resolved it this time (empty if unresolved / blocked).",
  "guessedHome": "code",
  "modelTier": "sonnet",
  "phase": "build"
}
```

| Field | Meaning |
|---|---|
| `sourceRepo` | `owner/name` of the repo being worked. |
| `sourceIssue` | The issue number the loop was working. |
| `pr` | The PR number if one was opened, else `null`. |
| `category` | One of: `ci-failure`, `review-feedback`, `pattern-gap`, `repo-gotcha`, `cross-repo-pattern`, `tooling`, `blocked`, `test`, `other`. **A closed set** — triage clusters on it, so an invented value silently prevents clustering. |
| `lesson` | The one-line actionable takeaway. Triage's dedupe key is `sourceRepo` + `category` + a semantically equivalent `lesson`, so write the *lesson*, not the incident. |
| `detail` | Self-contained: the transcript will be gone. |
| `fix` | How it was resolved this run. Empty if blocked or unresolved. |
| `guessedHome` | Best guess at the final home — `code`, `shared-skills`, `loop-self`, or `unsure`. **A hint only**; triage decides for real. |
| `modelTier` | The tier the subagent ran on (`opus` / `sonnet` / `haiku`) — signal for triage. |
| `phase` | `build`, `review-response`, or `orchestrator`. |

`guessedHome` heuristic:

- affects only *this* repo — a quirk of its own code, content or config → **`code`**
- would help a *different* repo, or is a recurring pattern → **`shared-skills`**
- about how the loop or orchestrator itself behaves → **`loop-self`**
- genuinely unsure → **`unsure`**, and let triage decide.

## How it is filed (analyzer → hook)

You, the analyzer, **file nothing** — you have read-only tools. Emit a single JSON object and
the hook (`hooks/capture-proto-learning.sh`) files it:

```json
{"file":true,"title":"[proto-learning] <source-repo>#<issue>: <lesson>","record":{ "...the fields above..." },"notes":"optional freeform context"}
```

To capture nothing, emit `{"file":false}`.

The hook creates the issue (title from `.title`, body = the fenced record then **Notes:**) and
skips an obvious **exact-title duplicate** itself. Deeper deduping and clustering is
`ops-triage-loop`'s job, not yours — **when in doubt about whether a learning is worth filing,
err toward `{"file":false}`.**
