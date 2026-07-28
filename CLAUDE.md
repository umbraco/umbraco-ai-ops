# CLAUDE.md

Guidance for working in **umbraco-ai-ops** — the generic engine for AI-driven issue
automation across Umbraco products. See `README.md` for the what/why; this file is the
**conventions** every plugin follows. Shared terms are defined in
**[`docs/vocabulary.md`](docs/vocabulary.md)** — use that language, and read its
**collisions** table before arguing about a word (`action`, `catalog`, `provider` and `base`
each already mean two things here).

## Golden rule: the engine is product-agnostic

Nothing here may hard-code one product's facts, toolchain, or branching. Product-specific
behaviour is supplied by the **consumer** (its own repo's `.claude/skills/`, or the shared
consumer repo for a repo family) as **capability skills**: one skill per unit of variation,
named `ops-<capability>`. If you find yourself writing `npm`, an MCP reference, a specific
product name, or a specific branching rule in an engine skill, it belongs in a
**capability**, not the engine.

## Convention, not configuration (how a repo customises the engine)

A capability is found by its **name**. There is no pointer, no registry, no slot to inject
into, and no frontmatter to key on:

- **A capability is a skill named `ops-<capability>`** (`[a-z][a-z0-9-]*` after the prefix) —
  `ops-change`, `ops-release`, `ops-ci`, `ops-branching`, and the rest.
- **A loop reaches one by invoking that name** with two positional arguments, `action` and
  `context`. `context` is a **single JSON object encoded as a string**; an absent context is
  `{}`. An action the capability doesn't implement is **rejected**, never guessed at and
  never silently succeeded.
- **The capability catalog declares the interface** — [`catalog.json`](catalog.json): which
  capabilities exist, which actions each answers to, and a worked `example` per action. The
  **action names are normative** (they are the validation set a skill rejects against); the
  `input` / `output` lists are guidance and must never be enforced at runtime. A capability skill
  for a capability the catalog doesn't declare is illegal.
- **Only `ops-change` and `ops-release` are always the repo's.** The rest ship as **framework
  defaults** the repo *inherits*, and overrides by shipping its own skill of that name.
- **Capability skills set `disable-model-invocation: true`.** A loop is the only caller; they
  must not auto-fire on a `description` match.
- **Framework loops are named `ops-<noun>-loop`** — `ops-issue-loop`, `ops-merge-loop`,
  `ops-release-loop`, `ops-rework-loop`, `ops-triage-loop`. The suffix is what keeps a loop
  out of the capability namespace, so `ops-release-loop` can never collide with the
  `ops-release` capability. **`loop-dispatch`** (the edge router, bash at the CI edge) and
  **`ops-install`** (the installer, invoked by a human) are exempt: neither is a loop.
- **Who may call what is recorded, not enforced.** Each capability carries a `visibility` —
  `service` (a loop may command it), `supporting` (wrapped by a service, **never** called by
  a loop), `cross-cutting` (callable from any layer). Held by review reading the catalog, not
  by code.

Why name-based and not same-name shadowing: skills do **not** cleanly shadow across delivery
mechanisms — plugin skills are namespaced, project skills are not, and cloud delivers both
flat into overlapping locations with undocumented precedence. Convention-by-name sidesteps
that, but it also means an engine skill and a repo skill **must never share a name unless the
repo means to replace it**.

> **In flight.** The engine still binds through `.claude/ai-ops.yml` pointers today
> (`playbook` → build skill, `branching.release_skill` → release skill). That is the model
> being retired, in Phase 8 of
> **[`docs/capabilities-migration-plan.md`](docs/capabilities-migration-plan.md)**. Write new
> work against the convention above; do not add config keys.

## Data seams are data + schema, never prose

**"Seam" now means one narrow thing: a data + schema extension point.** What a consumer
*implements* is a capability (above). What a consumer *declares* is a seam — a JSON data file
plus a `*.schema.json` describing its shape, read by a script or named by a skill. The engine
ships the default data; a consumer overrides by shipping its own file of the same shape —
**never by editing an engine skill**. Current seams:

| Seam | Data | Schema |
|------|------|--------|
| **Capability catalog** (which capabilities exist, their actions, `visibility`) | `catalog.json` | `catalog.schema.json` |
| Event → loop routing (framework **base ⊕ per-repo overlay**) | `loop-dispatch/.../scripts/route-map.json` | `route-map.schema.json` |
| GitHub/CI provider interface | `github-ops/.../operation-catalog.json` | `operation-catalog.schema.json` |
| ~~Per-repo consumer config~~ | ~~`<consumer>/.claude/ai-ops.yml`~~ | *retired in Phase 8 — absorbed by `ops-repo-meta` plus the capabilities* |

When you add a seam, follow the same pattern (data file + schema alongside the code that
reads it) and document it here.

## Plugin & skill folder layout

```
plugins/<plugin>/
  .claude-plugin/plugin.json         # manifest (see below)
  agents/<agent>.md                  # optional subagent definitions
  skills/<skill>/
    SKILL.md                         # the skill (frontmatter: name, description)
    references/<topic>.md            # supporting reference docs
    scripts/                         # ALL executable scripts + their data + tests
      <name>.sh                      # a script
      <name>.test.sh                 # its test, ALONGSIDE (see below)
      <name>.json / <name>.schema.json   # data + schema a script reads
```

### Scripts and tests

- **Scripts live in the skill's `scripts/` folder** — not loose in the skill root.
- **Tests live alongside the script they test, named `<script>.test.<ext>`** (e.g.
  `route-event.sh` → `route-event.test.sh`). **Do not** use a separate `test/` folder.
- A script that reads a data file resolves it **relative to its own location** (so the
  script + its data move together), with an env override for a consumer's custom file.
- Keep tests **hermetic** — no network, no `gh`, no `claude`; `bash` + `jq` only.

Repo-wide shared scripts (not tied to one skill) live in the top-level `scripts/`.

## Manifests

- Every plugin has `.claude-plugin/plugin.json`; it must be declared in
  `.claude-plugin/marketplace.json` with a matching `name`, `version`, and description.
- `author`: `{ "name": "Umbraco", "url": "https://github.com/umbraco" }`.
- `homepage`: `https://github.com/umbraco/umbraco-ai-ops/tree/main/plugins/<plugin>`.
- `license`: `MIT`. Validate with `jq empty` before committing.

## GitHub / CI work

All GitHub and CI operations go through the **`github-ops`** skill by operation **name** —
never a raw `gh`/`curl` in another skill. The forge (gh vs GitHub MCP) and the CI provider
(`github-checks` vs `azure-pipelines`) are resolved there. Adding a provider = implementing
the `operation-catalog.json` operations for that axis; no loop changes.

An **operation** is a forge/CI primitive (`merge-pr`, `get-ci-status`); an **action** is a
capability verb (`ops-change · implement`). Never interchange them. Phase 3 splits the CI axis
out as the `ops-ci` capability; the forge mechanism stays framework mechanics and is not
overridable.

## Line endings

Scripts run on Linux routine/CI runners. `.gitattributes` forces `*.sh`/`*.yml` to **LF** —
keep it that way; never commit CRLF scripts.

## Before you commit

- `jq empty` every changed `*.json`.
- Run any touched skill's `scripts/*.test.sh`.
- **If you touched `catalog.json`:** run `scripts/validate-catalog.sh`, then
  `scripts/catalog-to-readme.sh` to regenerate the README's action table. Never hand-edit that
  table — CI fails on drift.
- Grep your change for product-specifics (`npm`, `mcp`, a product name) — if present, it
  belongs in a **capability**, not in engine code.

The first two are enforced in CI by `.github/workflows/tests.yml` (runs every
`plugins/**/*.test.sh` and `jq empty` on every JSON, on each PR and push to `main`) — keep
it green. It's hermetic (`bash` + `jq` only): a new test must not need network, `gh`, or
`claude`. The other workflow, `.github/workflows/loop-dispatch.yml`, is **runtime, not CI** —
the reusable edge router consumers call from their own caller workflow.
