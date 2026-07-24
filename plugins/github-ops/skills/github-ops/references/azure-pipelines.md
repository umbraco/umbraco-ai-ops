# CI provider — Azure Pipelines (`ci_provider: azure-pipelines`)

Use this **only** for the two CI-reading operations — *Get PR CI status* and *Read a
failing check's log* — when the repo's CI runs in Azure DevOps. **Everything else stays
GitHub** (issues, PRs, reviews, branches, merge) via [`gh-cli.md`](gh-cli.md) /
[`github-mcp.md`](github-mcp.md). Azure only tells you whether the build the push
triggered is green, and why it isn't.

## Auth & egress (no GitHub-App equivalent)

Unlike GitHub, there is **no proxy that authenticates Azure DevOps for you**. You need:

- **A PAT** in the env var **`AZURE_DEVOPS_PAT`** — scope **Build (Read)** only (the loop
  never queues builds; pushes trigger them). Store it as a cloud-environment variable.
  Personal PAT to prototype; a **service account / Entra service principal** for standing
  routines (expiry + ownership).
- **Egress:** `dev.azure.com` must be reachable — set the cloud environment's network
  access to **Custom** and add `dev.azure.com` (keep "include default list").

Auth is HTTP Basic with an empty username: `curl -u ":$AZURE_DEVOPS_PAT"`.

## Config the consumer supplies (under `ci_provider`)

| Key | Meaning | Example |
|-----|---------|---------|
| `ado_org` | DevOps organization | `umbraco` |
| `ado_project` | DevOps project | `Umbraco.Forms` |
| `gh_repo` | the GitHub repo builds are wired to | `umbraco/Umbraco.Forms` |

Base URL used below: `https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis`. Pin
`api-version=7.1`.

## Operations

### Get PR CI / build status

An Azure pipeline triggered by a GitHub PR builds the merge ref `refs/pull/<n>/merge`
(a branch-triggered pipeline builds the PR's head branch instead — try the merge ref
first, fall back to the head branch). List that branch's builds newest-first and read the
top one's `status` (`notStarted` / `inProgress` / `completed`) and `result`
(`succeeded` / `failed` / `partiallySucceeded` / `canceled`):

```bash
curl -sS -u ":$AZURE_DEVOPS_PAT" \
  "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/builds\
?repositoryId=$GH_REPO&repositoryType=GitHub\
&branchName=refs/pull/$PR/merge&\$top=1&queryOrder=queueTimeDescending&api-version=7.1" \
  | jq -r '.value[0] | "\(.id) \(.status) \(.result)"'
```

**The gate (mirror `merge-flow`):** poll until `status == "completed"`, then require
`result == "succeeded"`. Anything else is not-green — `failed`/`partiallySucceeded` is a
real failure (diagnose it), `canceled` is a re-run. Never treat a red build as flaky from
the summary alone.

### Read a failing build's log

Get the build's **timeline**, pick the records that failed, and fetch each one's log by
its `log.id`:

```bash
# 1. failed timeline records (job/task name + its log id)
curl -sS -u ":$AZURE_DEVOPS_PAT" \
  "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/builds/$BUILD_ID/timeline?api-version=7.1" \
  | jq -r '.records[] | select(.result=="failed") | "\(.log.id)\t\(.name)"'

# 2. the log for a failed record
curl -sS -u ":$AZURE_DEVOPS_PAT" \
  "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/builds/$BUILD_ID/logs/$LOG_ID?api-version=7.1"
```

Read the failing task's log, reproduce the root cause locally, fix, push, and re-poll —
the same discipline as the GitHub-checks path. The 8-attempt green-it cap still applies.

## Notes

- **Only CI reads live here.** Opening the PR, commenting, labelling, merging — all GitHub.
- **`repositoryType=GitHub`** matters: it's how DevOps knows the `repositoryId` is an
  `owner/name` GitHub repo, not an internal Git repo.
- If the merge-ref query returns nothing, the pipeline is branch-triggered — re-query with
  `branchName=refs/heads/<PR head branch>` (get the head branch from the GitHub PR).
- A `403` with `host_not_allowed` means egress isn't configured — add `dev.azure.com` to
  the environment's allowed domains.
