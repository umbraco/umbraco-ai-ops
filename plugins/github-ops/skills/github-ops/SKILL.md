---
name: github-ops
description: >-
  Shared how-to for GitHub operations in both environments this system runs in —
  locally with the `gh` CLI + `git`, and on Claude web / in scheduled routines with
  the GitHub MCP server (`mcp__github__*`, no `gh` there). One operation catalog, two
  reference files for the GitHub mechanism, plus a CI-provider reference so the "read
  CI status / read a failing log" operations resolve to GitHub checks or Azure
  Pipelines — which of the two is chosen inside the `ops-ci` capability, not here and
  not in any config key. The loop skills point here instead of
  each re-explaining the dual path. Load this whenever a loop needs to touch GitHub
  (list/create issues, open/merge PRs, check CI, push files) and you need the concrete
  command/tool for the current environment.
---

# github-ops

The loops in this marketplace run in **two environments**, and GitHub is reached
differently in each. This skill is the single source of truth for that mapping so no
loop skill has to repeat it.

## Pick the mechanism by environment

```mermaid
flowchart LR
    START{"is gh available?<br/>(run: command -v gh)"} -->|yes — dev machine| CLI["gh CLI + git<br/>→ references/gh-cli.md"]
    START -->|no — Claude web / routine| MCP["GitHub MCP server<br/>(mcp__github__*)<br/>→ references/github-mcp.md"]
```

- **Local (dev machine):** `gh` and `git` are installed → use
  [`references/gh-cli.md`](references/gh-cli.md). Auth is your `gh` login.
- **Claude web / scheduled routine:** `gh` is **not** available; the **GitHub MCP
  server** is → use [`references/github-mcp.md`](references/github-mcp.md). Auth is
  the MCP server's connected GitHub App (no token to paste).

Both are first-class. Detect with `command -v gh` (or: if the `mcp__github__*` tools
are present, you're on the MCP path). **Bash scripts** under `scripts/` are a third,
separate case — they call the REST API with `curl` directly and are out of scope
here.

> The MCP reference uses the tool names from the current `github/github-mcp-server`.
> Server versions differ — **confirm against the live `mcp__github__*` tool list**
> and use the tool that performs the operation if a name doesn't match.

## The operation catalog (the provider interface)

The canonical list of operations a loop can invoke by name is **data, not prose**:
[`operation-catalog.json`](operation-catalog.json) (shape:
[`operation-catalog.schema.json`](operation-catalog.schema.json)). It's the **interface**
every provider implements — each operation carries an `axis`:

- **`forge`** — the git host. Implemented by [`gh-cli.md`](references/gh-cli.md) (local) and
  [`github-mcp.md`](references/github-mcp.md) (web). Both cover **every** `forge` operation —
  keep them in sync with the catalog.
- **`ci`** — the CI system. Which provider a repo uses is resolved inside **`ops-ci`** (see
  below), never by a config key: GitHub checks live in the `gh-cli`/`github-mcp` CI rows;
  Azure Pipelines in [`azure-pipelines.md`](references/azure-pipelines.md).

Operations flagged `"gate": true` (`get-ci-status`, `read-failing-ci-log`, `merge-pr`) are
merge/CI gates — loops must never bypass them.

**Adding a provider** (a different git host, or a CI system beyond GitHub-checks / Azure
Pipelines): add a reference file that maps **every operation of that axis** in
`operation-catalog.json` to a concrete command/tool. The loops don't change — they call
operations by id.

## CI provider — GitHub checks vs Azure Pipelines

Two operations above — **Get PR CI / check-run status** and **Read a failing check's
log** — depend on *which CI system the repo uses*, not on the GitHub mechanism:

- **`github-checks`** (default) — CI is GitHub Actions / checks on the PR. Use the CI
  rows in [`gh-cli.md`](references/gh-cli.md) / [`github-mcp.md`](references/github-mcp.md).
- **`azure-pipelines`** — CI runs in Azure DevOps, triggered by the push but reported
  outside GitHub's check API. Use [`references/azure-pipelines.md`](references/azure-pipelines.md).

> **Which one is not decided here.** It is internal to the **`ops-ci`** capability, which is
> the only caller of these two operations and the only thing that knows the answer. That is
> why there is no longer a `ci_provider` config key: it was spelled two ways in two places,
> and the capability replaces both. This skill just implements each provider's mechanics.

Everything else in the catalog (issues, PRs, branches, files, merge) is **always GitHub**
whatever the CI provider — Azure-Pipelines consumers keep their PRs and issues on GitHub and
only their *CI reads* go to Azure. So on an Azure repo you use the GitHub mechanism (gh / MCP)
for every row **except** those two CI rows.

## Rules that hold in both mechanisms

These are policy, not mechanism — they apply whichever reference you use:

- **Never merge without green CI + approval** (poll status; don't rely on GitHub's native
  auto-merge to bypass the gate). The gates themselves live in **`ops-integrate`** — this
  skill provides the merge operation, it does not decide whether to use it.
- **Never force-push; never edit a protected branch directly.**
- **On the web, no local clone** — create the branch and push file contents through
  the MCP server; you don't have a working tree.
- **Never resolve a base branch here.** Branch knowledge is private to **`ops-branching`**;
  this skill takes the base it is given. The old `detect-base-branch` operation was removed
  for exactly this reason — it was a fourth place base knowledge lived.
