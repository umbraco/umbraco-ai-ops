---
name: ops-ci
description: >-
  This repo's CI, read-only. `status` reports whether a PR is pending, green or red and
  which checks say so; `log` returns the failing part of a failing build's log, trimmed to
  what is needed to diagnose it. The CI provider — GitHub checks, Azure Pipelines, anything
  else — is internal: no caller learns which one this repo uses. Nothing here starts,
  retries or cancels a build. Called by name with (action, context-json) . NOT for direct use — never select it from a description match.
---

# ops-ci

Everything a caller needs to know about CI, and nothing about *whose* CI it is.

**Visibility: cross-cutting (read).** A loop may call it to gate; a service may call it to
re-check. Both actions are reads.

**Read-only, deliberately.** There is no `retry`, no `rerun`, no `cancel`. A loop that can
re-run a red build can loop on a real failure forever, and "rerun it and see" is exactly the
judgement a green-CI gate exists to prevent. If a check is genuinely flaky, that is a
finding for a human, not a retry for a loop.

## Invocation

```
ops-ci <action> '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `status` | `{ pr }` | `{ ok, state, checks }` |
| `log` | `{ pr, check? }` | `{ ok, check, log }` |

An absent context is `{}`. **Reject any other action.** Both actions are reads, so calling
either twice is free.

## The provider is internal

Resolve it once, from `ops-repo-meta`/detection, and **never return it**. The engine ships
two:

| Provider | Where CI runs | Reference |
|---|---|---|
| `github-checks` *(default)* | GitHub Actions / checks on the PR | the CI rows in `github-ops` → `references/gh-cli.md` / `github-mcp.md` |
| `azure-pipelines` | Azure DevOps, triggered by the push, reported outside GitHub's check API | `github-ops` → `references/azure-pipelines.md` |

Both actions go through **`github-ops`** by operation name — `get-ci-status` and
`read-failing-ci-log`, both flagged `"gate": true` in its operation catalog. A third
provider is added by implementing those two operations for it; **no caller changes**, which
is the whole reason the provider is private.

> A repo whose CI is neither of those ships its own `ops-ci`. That is the override path, and
> it is why `ci.provider` is no longer a config key: the capability *is* the answer.

## Action: `status`

```json
{ "ok": true, "state": "green", "checks": [ { "name": "Build (Release)", "conclusion": "success" } ] }
```

- **`state`** is exactly one of **`pending`**, **`green`**, **`red`**.
- **`pending` while anything is still running.** Do not report `green` on a partial pass —
  a caller reading `green` will merge.
- **`green` requires every check to have passed.** Not "no failures"; every check *passed*.
  A skipped required check is not a pass.
- **`red`** as soon as one check has failed, even with others pending. A caller does not
  need to wait out a run that is already lost.
- Report the checks that produced the verdict, so a caller can name the blocker without a
  second call.

**Waiting is the caller's job, not this action's.** `status` answers once, for the state
right now. It does not block, poll or sleep. The polling cadence and its cap belong to the
loop that owns the schedule.

## Action: `log`

```json
{ "ok": true, "check": "Build (Release)", "log": "…the relevant excerpt…" }
```

- With no `check`, read the **first failing** one.
- Return **the failing part**, not the whole run. A full CI log is mostly noise, and a
  caller pays for every line of it. Find the failure and give enough context to act on it.
- If nothing is failing, say so — `{ ok: false, detail: "no failing check" }` — rather than
  returning a green log.

## Rules

- **Never return the provider name**, the pipeline id, the ADO org, or a CI URL shaped like
  one provider. A caller that can tell azure-pipelines from github-checks will eventually
  branch on it.
- **Never start, retry or cancel anything.**
- **`pending` is not `green`.** The single most expensive mistake this capability can make
  is reporting a partial pass as a pass.
- **Never infer green from a merge being allowed.** With no branch protection — the case in
  both current consumers — GitHub will happily allow a red merge.
