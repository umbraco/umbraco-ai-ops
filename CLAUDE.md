# CLAUDE.md

Guidance for working in **umbraco-ai-ops** — the generic engine for AI-driven issue
automation across Umbraco products. See `README.md` for the what/why; this file is the
**conventions** every plugin follows.

## Golden rule: the engine is product-agnostic

Nothing here may hard-code one product's facts, toolchain, or branching. Product-specific
behaviour is supplied by the **consumer** (its own repo's `.claude/skills/`, or the shared
consumer repo for a repo family) via two inputs the engine reads: a **build playbook** and a
**config block** (see `README.md` → config contract). If you find yourself writing `npm`,
an MCP reference, a specific product name, or a specific branching rule in an engine skill,
it belongs in a **seam**, not the engine.

## Extension points are data + schema, never prose

Anything a consumer might override or extend is a **deterministic, machine-readable seam**:
a JSON data file plus a `*.schema.json` describing its shape, read by a script or named by a
skill. The engine ships the default data; a consumer overrides by shipping its own file of
the same shape — **never by editing an engine skill**. Current seams:

| Seam | Data | Schema |
|------|------|--------|
| **Per-repo consumer config** (how the engine runs in one repo — repos, CI, branching) | `<consumer>/.claude/ai-ops.yml` | `ai-ops.schema.json` (+ `ai-ops.example.yml`) |
| Event → loop routing | `loop-dispatch/.../scripts/route-map.json` | `route-map.schema.json` |
| GitHub/CI provider interface | `github-ops/.../operation-catalog.json` | `operation-catalog.schema.json` |

`ai-ops.yml` is the central seam: `/umbraco-ops-setup` writes it (detect + ask), and every
loop reads it for repo facts, CI provider, and the branching model. Anything the repo does
differently from the built-in models is handed to an applied-repo skill named in
`branching.release_skill`.

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

## Line endings

Scripts run on Linux routine/CI runners. `.gitattributes` forces `*.sh`/`*.yml` to **LF** —
keep it that way; never commit CRLF scripts.

## Before you commit

- `jq empty` every changed `*.json`.
- Run any touched skill's `scripts/*.test.sh`.
- Grep your change for product-specifics (`npm`, `mcp`, a product name) — if present, it's a
  seam, not engine code.
