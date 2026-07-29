---
name: ops-repo-meta
description: >-
  Ambient facts about this repo and its family, returned as structured data: `identity`
  (repo, default branch, the trigger labels), `topology` (which repo fills the `code` /
  `issues` / `releases` / `learnings` role), and `lines` (the live version lines, which
  is primary, and the port direction). The framework default detects what it can and
  reads a repo's declared facts; a repo that has facts detection cannot reach ships its
  own `ops-repo-meta` instead. Called by name with (action, context-json) . NOT for direct use — never select it from a description match.
---

# ops-repo-meta

The **data capability**. Every other capability and loop asks it "what is true about this
repo?" instead of detecting, guessing, or holding a config key.

**Visibility: cross-cutting (read).** Any layer may call it — a loop, a service, a
supporting primitive. It has no side effects.

**Kind: data.** Per the conformance spec's §4.4 carve-out, the structure *is* the
deliverable: every action **MUST** return well-formed structured data, not prose. A caller
parses the object; it does not read a sentence.

## Invocation

```
ops-repo-meta <action> '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `identity` | *(none)* | `{ repo, default_branch, labels }` |
| `topology` | *(none)* | `{ repos: { <role>: "owner/name" } }` |
| `lines` | *(none)* | `{ live, primary, port_order }` |

All three take **no context**. An absent context is `{}`, never an error. **Reject any
action not in that table** — do not guess, do not silently succeed. All three are reads, so
idempotency is free.

## Where the facts come from

In this order. Stop at the first that answers.

1. **A repo-owned skill.** If the repo ships its own `ops-repo-meta`, this one is not running
   at all — that is what overriding means. Only needed for *behaviour*; for facts, use 2.
2. **The repo's declared facts** — `.claude/ops-repo-meta.json`, shaped by
   [`scripts/ops-repo-meta.schema.json`](scripts/ops-repo-meta.schema.json) and checked by
   [`scripts/validate-repo-meta.sh`](scripts/validate-repo-meta.sh). **This is the normal way a
   repo answers.** `ops-install` writes it; every key is optional, so a single-repo project on
   one line needs no file at all. Read it, don't re-derive it.
3. **Detection.** `detect.sh` (in the `ops-install` plugin) reads git branches and repo
   settings and returns `source`, `branching.*`, `ci.provider`, `release.*`, `stack`. Use it
   for `identity.repo`, `identity.default_branch`, and as the seed for `lines`.
4. **The framework defaults** in this file.

> **This is not the old config file.** `.claude/ai-ops.yml` bound the engine through skill
> pointers and held facts that now have exactly one owner each — branch model, base, release
> base and merge strategy are private to `ops-branching`, the CI provider is internal to
> `ops-ci`, and a capability is found by its name. That file is deleted, and
> `ops-repo-meta.json` is a strict subset of what it held: **only facts nothing can detect and
> nothing else owns.** The schema sets `additionalProperties: false` at every level so an
> attempt to put the rest back fails loudly rather than drifting.

**Topology in the file reads "what this repo is not."** A role left out resolves to the repo
the file lives in. So a code repo whose issues live elsewhere declares `issues`, and **the
issues repo declares `code`** — which is the only place the code repo can be named, because
detection there would read the issues repo's own remote. `route-event.sh` reads exactly that
key at the edge to decide which repo a routine should work in.

## Action: `identity`

Who am I, and what labels do I run by.

```json
{
  "repo": "owner/name",
  "default_branch": "main",
  "labels": {
    "ready":       "ops/ready-for-ai",
    "in_progress": "ops/in-progress",
    "done":        "ops/generated-by-ai",
    "blocked":     "ops/ai-blocked",
    "land":        "ops/auto-merge",
    "rework":      "ops/auto-rework",
    "release":     "ops/auto-release",
    "release_blocked": "ops/release-blocked",
    "proto_learning":  "ops/proto-learning",
    "triaged":         "ops/triaged",
    "loop_improvement": "ops/loop-improvement"
  }
}
```

**Labels are keyed by purpose, never by name.** A caller asks for
`labels.land`, not for the string `ops/auto-merge` — which is what lets a repo rename a
label without touching a loop. The values above are the framework defaults; every engine
label is namespaced `ops/` (see `CLAUDE.md`). A repo that has already got a label meaning
"ready" points `labels.ready` at it instead of creating a second one.

**`in_progress` and `done` are not two names for one thing.** `in_progress` is **state** — on
while a loop is working the issue, off the moment it stops, so an interrupted run is findable.
`done` is **provenance** — a loop built this, which stays true forever. They shared one slot
until a live routine read `labels.in_progress`, found it pointed at the finished label, and
invented a name of its own (29-07-2026).

`repo` and `default_branch` come from detection. Note that **the default branch is not
necessarily a branch work happens on** — see `lines`.

## Action: `topology`

Which repo fills which role.

```json
{ "repos": { "code": "owner/name", "issues": "owner/name-issues", "releases": "owner/name", "learnings": "owner/name" } }
```

- Roles are **`code`** (required), **`issues`**, **`releases`**, **`learnings`**.
- **An unspecified role resolves to `code`.** So a single-repo project returns only `code`,
  and every role collapses onto it. Return what you know; the caller applies the fallback.
- `learnings` is **not** automatically `issues`: where issues are public and code is not, a
  proto-learning is an internal note and belongs with the code.

Operation → role, which is normative (conformance §7.3):

| Operation class | Role |
|---|---|
| Read / label / close issues; the release trigger issue | `issues` |
| Branch, push, PR, CI status, PR labels, merge, tag | `code` |
| Publish / release realization | `releases` |
| File / label / close proto-learnings | `learnings` |

**Framework default:** every role is the detected `code` repo, i.e. a single-repo project.

## Action: `lines`

The version lines currently taking work.

```json
{ "live": ["v17", "v18"], "primary": "v17", "port_order": "upward" }
```

- **`live`** — every line taking work *now*. A repo can have several at once, which is why
  a caller must treat "the integration branch" as **set membership**, never equality with
  one branch.
- **`primary`** — the line work starts on before being ported. **Not** necessarily the
  newest line, and **not** necessarily the default branch.
- **`port_order`** — `upward` (primary is older; ports go to newer lines) or `downward`.

**None of this is derivable** from version numbers or from the default branch, so a repo
that has more than one live line **must** override this skill and declare them. Guessing
"newest = primary" picks wrong.

**Callers MUST read this every time and MUST NOT cache it.** A major-version cutover adds a
line, and that must not require an engine change.

**Framework default:** a single unnamed line —
`{ "live": ["default"], "primary": "default", "port_order": "upward" }` — meaning the repo
has no version lines and the default branch is the whole story. `ops-branching` reads that
as "one integration branch".

## Rules

- **Return data, never prose.** A caller parses this. A sentence is a bug.
- **Never invent a fact.** If something is genuinely unknown, omit the key rather than
  guessing — an omitted role resolves to `code`, and an omitted line list is the
  single-line default. A guessed primary line silently sends work to the wrong branch.
- **No side effects.** All three actions are reads. Never create a label, branch or file.
- **Detection is a seed, not an authority**, for anything a human had to decide: the
  primary line and the port order are declared facts by definition.
