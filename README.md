# umbraco-ai-ops

The **generic engine** for AI-driven issue automation across Umbraco products. It turns
a `ready-for-ai` GitHub backlog into CI-green, reviewed, merged PRs — and feeds its own
improvement back into the repos it works.

This repo is product-**agnostic**. It knows *how to run the loop*; it does **not** know how
to build any one product. Each consumer supplies exactly two things:

1. a **build playbook** (the per-issue how-to for that product), and
2. a small **config block** (repo facts: where issues live, where PRs open, which CI, …).

Extracted from the [`umbraco-mcp-ops`](https://github.com/hifi-phil/umbraco-mcp-ops)
prototype, which proved the model on Claude Code web routines.

## Who consumes it, and how

Consumer shape follows **repo cardinality**:

| Consumer | Shape | Where its playbook + config live |
|----------|-------|----------------------------------|
| **Umbraco.Forms** | single product, one repo | committed in the repo's own `.claude/skills/` (in-repo) |
| **Umbraco.Automate** | single product (multi-package), one repo | committed in the repo's own `.claude/skills/` (in-repo) |
| **MCP server family** | many repos, one toolchain | one shared consumer repo (`umbraco-mcp-ops`), delivered like the engine |

> **One product = one repo → consumer half lives in-repo.**
> **One product family = many repos → consumer half lives in one shared repo**, to avoid
> duplicating an identical playbook across the family.

## Plugins

Installed from this marketplace (`.claude-plugin/marketplace.json`):

| Plugin | What it is |
|--------|------------|
| **issue-loop-core** | The orchestration engine (queue → `/goal` → cap-3 dispatch → review phase → stop conditions). Loads the product's build playbook via a named slot. Bundles `rework-loop`. |
| **github-ops** | GitHub work in both environments (`gh`/`git` local, `mcp__github__*` on web) **+ a CI-provider abstraction** (`github-checks`, `azure-pipelines`). Required by every loop. |
| **loop-dispatch** | One-routine-per-repo event router (`route-event.sh`). Supports a `target_repo` distinct from the event's repo (cross-repo-issues case, e.g. Forms). |
| **merge-flow** | Gated auto-merge on the `auto-merge` label once CI-green + conflict-free. |
| **learning** | The self-learning machinery: capture hooks → `proto-learning` issues → `triage-learnings`. Mechanism generic; inbox + routing are config. |
| **release-flow** | Branching/release/dev-sync (gitflow vs main-only). **Reference/default only** — Forms and Automate override with their own release skills. |
| **dotnet-web-runtime** | Cloud-env setup so a .NET product can run as a web routine (NuGet-feed proxy / 401 fix). |

## How a consumer links to the engine

Linkage is **by skill name** — a product's playbook is loaded *by* `issue-loop-core`, and
calls `github-ops` by name. Nothing is copied.

- **Local:** `/plugin marketplace add umbraco/umbraco-ai-ops` → install the engine plugins.
  In-repo consumer skills load as project skills automatically; the MCP family loads its
  shared skills from `umbraco-mcp-ops`.
- **Web routines (primary runtime):** `scripts/cloud-skill-sync.sh` (env Setup script)
  delivers the engine to `$HOME/.claude/skills`. Single-product repos add nothing — a
  routine loads the checked-out repo's committed `.claude/skills/` and `.claude/settings.json`
  hooks natively. **Caveat:** routines clone the **default branch** unless the prompt says
  otherwise, so keep one canonical consumer skill on the default branch and make the playbook
  **line-aware at runtime** (it detects the base branch) — don't fork per-branch skill copies.

## The config contract

The two inputs `issue-loop-core` reads from each consumer:

```yaml
# 1. build_playbook — the product's per-issue playbook (the only real content)
# 2. config block (repo facts; auto-detect where derivable):
inbox_repo:      <where ready-for-ai issues live>     # must be declared when it differs from source (Forms)
source_repo:     <where PRs open>                      # auto-detect: git remote
base_branch:     <auto | vX/dev>                       # auto-detect: release-and-branching
ci_provider:     github-checks | azure-pipelines       # auto-detect: azure-pipelines.yml vs GH checks
repo_type_gate:  <how to confirm this is the right repo>
issue_link:      same-repo-closes | cross-repo-full-url
learning_inbox:  <proto-learning repo>
triage_routing:  <shared-skills / product-repo / loop-self>
```

## Layout

```
.claude-plugin/
  marketplace.json         # marketplace manifest listing the plugins
plugins/
  <plugin>/                # one dir per plugin (skills/, agents/, scripts/, references/)
scripts/
  cloud-skill-sync.sh      # cloud-env Setup script: deliver the engine skills to a routine
```

## Status

**Work in progress** — scaffolding the engine by extracting and genericising the proven
`umbraco-mcp-ops` plugins. See the topology map for the full design and decision log.
