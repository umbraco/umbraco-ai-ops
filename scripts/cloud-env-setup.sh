#!/usr/bin/env bash
# cloud-env-setup.sh — cloud env WARM-UP for the loop workers.
#
# A copy of umbraco-mcp-ops scripts/cloud-skill-sync/env-setup.sh, kept as close to it as
# possible. Invoked once at env-build by the stub in the env Setup script field
# (cloud-setup-stub.sh). It caches only the slow, CREDENTIAL-FREE downloads — the things that
# reliably persist — so a session can bring Umbraco up quickly:
#   1. skills / agents / hooks           (delegates to cloud-skill-sync.sh)   [required]
#   2. .NET SDK                          ($HOME/.dotnet, symlinked to /usr/local/bin)
#   3. (sqlserver only) Docker + the mssql:2022 image, in Docker's persistent store
#
# It deliberately does NOT pre-bake an Umbraco instance — caching a baked instance proved
# unreliable (needs a build-phase token for a private repo, and a plain seed dir isn't retained
# across rebuilds). Instead, a SESSION runs run-umbraco.sh to start the chosen database and boot
# the product's own site. Everything here is credential-free, so there's no private-repo / token
# dependency at build time.
#
# What changed from the mcp-ops original, and why:
#   - rsync is gone: only the MCP repo's demo-site bootstrap used it.
#   - the manifest describes run-umbraco.sh's --boot contract instead of MCP's npm scripts,
#     because the engine serves more than one product and each boots its own site.
#   - DOTNET_CHANNEL comes from the stub, so a repo pinned to another SDK can say so.
#   - log() no longer tees into the log as well as the main block, which doubled every line.
#
# Two environments from one stub, via --provider (or DB_PROVIDER):
#   sqlite     lean: skills + SDK. Sessions run Umbraco on server-less SQLite.
#   sqlserver  CI-parity: also Docker + the cached mssql image, for SQL Server sessions.
#
# Never fails the build (exit 0): a session with some of this is better than none, and the
# manifest and the log say exactly what is missing.
set -uo pipefail

VERSION="1"                       # log marker only — the cache-bust is `rebuild:` in the stub
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/env-setup.log"

export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"

MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/root/.docker-data}"   # persistent (proven)
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
MANIFEST="$HOME/env-manifest.md"
OPS_SCRIPTS_DIR="$HOME/.umbraco-ops"
BIN_DIR="${OPS_BIN_DIR:-/usr/local/bin}"                     # tests point this elsewhere

PROVIDER="${DB_PROVIDER:-sqlite}"
_prev=""; for _a in "$@"; do [ "$_prev" = "--provider" ] && PROVIDER="$_a"; _prev="$_a"; done

# Stdout only. The main block below already tees everything into $LOG; the mcp-ops original
# ALSO tee'd here, so every line landed in the log twice.
log() { printf '%s %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo now)" "$*"; }

# ── 1. Skills / agents / hooks (required) ──────────────────────────────────
deliver_skills() {
  if [ -f "$HERE/cloud-skill-sync.sh" ]; then
    # Deliver skills from THIS checkout (the branch env-setup was launched from), not a
    # fresh clone of main — otherwise a branch-pointed env can't test its own new skills.
    local ops_root; ops_root="$(cd "$HERE/.." && pwd)"
    log "delivering skills/agents/hooks via cloud-skill-sync.sh (source: $ops_root)"
    OPS_SRC="$ops_root" bash "$HERE/cloud-skill-sync.sh" || log "WARN: cloud-skill-sync.sh returned non-zero"
  else
    log "ERROR: cloud-skill-sync.sh not found next to cloud-env-setup.sh"
  fi
}

# ── 2. .NET SDK ────────────────────────────────────────────────────────────
# Symlink onto a PATH dir every shell sees — .bashrc isn't sourced by a backgrounded
# `nohup dotnet run`, so without this the backgrounded boot fails "command not found".
link_dotnet() { [ -x "$HOME/.dotnet/dotnet" ] && ln -sf "$HOME/.dotnet/dotnet" "$BIN_DIR/dotnet" 2>/dev/null || true; }

install_dotnet() {
  local channel="$1"
  if dotnet --list-sdks 2>/dev/null | grep -q "^${channel%.*}\."; then
    log ".NET SDK channel $channel already present"; link_dotnet; return 0
  fi
  log "installing .NET SDK channel $channel"
  local tmp; tmp="$(mktemp -d)/dotnet-install.sh"
  # raw-github URL, NOT dot.net/v1 (which 301-redirects and traps curl into an empty file).
  if ! curl -fsSL -o "$tmp" https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.sh; then
    log "WARN: could not download dotnet-install.sh"; return 1
  fi
  chmod +x "$tmp"
  "$tmp" --channel "$channel" --install-dir "$HOME/.dotnet" || { log "WARN: dotnet install failed"; return 1; }
  if ! grep -q 'DOTNET_ROOT=$HOME/.dotnet' "$HOME/.bashrc" 2>/dev/null; then
    { echo 'export DOTNET_ROOT=$HOME/.dotnet'; echo 'export PATH=$HOME/.dotnet:$HOME/.dotnet/tools:$PATH'; } >> "$HOME/.bashrc"
  fi
  dotnet --version >/dev/null 2>&1 || { log "WARN: dotnet not usable after install"; return 1; }
  link_dotnet
}

# ── 3. Docker + mssql image (sqlserver only) ───────────────────────────────
# Use an existing daemon if one is running; else install + start dockerd with a data-root
# under the persistent store, so the pulled image survives to sessions.
ensure_docker() {
  if docker info >/dev/null 2>&1; then log "docker ready (existing daemon)"; return 0; fi
  if ! command -v docker >/dev/null 2>&1; then
    log "installing docker engine"
    command -v apt-get >/dev/null 2>&1 && (apt-get update -qq && apt-get install -y docker.io) >>"$LOG" 2>&1 || log "WARN: apt-get docker.io failed"
  fi
  mkdir -p "$DOCKER_DATA_ROOT"
  log "starting docker daemon (data-root $DOCKER_DATA_ROOT)"
  service docker stop >/dev/null 2>&1 || true
  (nohup dockerd --data-root "$DOCKER_DATA_ROOT" >/tmp/dockerd.log 2>&1 &)
  for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || { log "WARN: dockerd won't run here (see /tmp/dockerd.log)"; return 1; }
}

prep_sqlserver() {
  log "prep SQL Server: docker + cache the mssql image"
  ensure_docker || { log "WARN: docker unavailable — mssql image not cached"; return 1; }
  if docker image inspect "$MSSQL_IMAGE" >/dev/null 2>&1; then
    log "mssql image already cached ($(docker images --format '{{.Size}}' "$MSSQL_IMAGE" | head -1)) — skip pull"; return 0
  fi
  log "pulling $MSSQL_IMAGE (~2.3 GB; cached in $DOCKER_DATA_ROOT)"
  docker pull "$MSSQL_IMAGE" >>"$LOG" 2>&1 && log "mssql image cached" || log "WARN: docker pull failed"
}

# ── Manifest — tell the session what's here + how to bring Umbraco up ──────
write_manifest() {
  mkdir -p "$OPS_SCRIPTS_DIR"
  cp "$HERE/run-umbraco.sh" "$OPS_SCRIPTS_DIR/" 2>/dev/null || true
  local docker_line="not installed (sqlite env)" has_mssql=0
  if [ "$PROVIDER" = "sqlserver" ]; then
    if docker image inspect "$MSSQL_IMAGE" >/dev/null 2>&1; then
      docker_line="mssql image cached ($(docker images --format '{{.Size}}' "$MSSQL_IMAGE" | head -1))"; has_mssql=1
    else
      docker_line="requested but image NOT cached (see $LOG)"
    fi
  fi
  local db_section
  if [ "$has_mssql" = "1" ]; then
    db_section="$(cat <<'DBEOF'
**SQL Server is available** (image cached) — **use it for any test run** (it is CI-parity;
SQLite is a last resort only and throws false failures/passes). The daemon is not running yet
(it does not persist across sessions); "not running" means startable, not unavailable. Check
live:
```
docker info >/dev/null 2>&1 && echo RUNNING || echo "AVAILABLE (not started)"
```
- **RUNNING** → `--provider sqlserver`.
- **AVAILABLE (not started)** → `run-umbraco.sh --provider sqlserver` starts it (daemon +
  container from the cached image). This is the default for testing; only drop to
  `--provider sqlite` when speed on a single focused change matters, and confirm on SQL
  Server / CI.
DBEOF
)"
  else
    db_section="Only **SQLite** is available (no mssql image). Use \`--provider sqlite\`."
  fi

  # The heading and the SDK row say what is TRUE, not what was asked for. The first build of
  # this script said "ready" and "on PATH" over an SDK that had failed to install, and the
  # session reading it called that out as the manifest contradicting itself.
  # "Has the channel it asked for" is the same test install_dotnet uses. An SDK from another
  # channel is not a pass: global.json would refuse it and the build would fail anyway.
  local sdk_version status sdk_line warning=""
  sdk_version="$(dotnet --version 2>/dev/null || true)"
  if dotnet --list-sdks 2>/dev/null | grep -q "^${DOTNET_CHANNEL%.*}\."; then
    status="ready"
    sdk_line="$sdk_version (requested channel $DOTNET_CHANNEL; on PATH via $BIN_DIR)"
  else
    status="NOT ready — no .NET SDK for channel $DOTNET_CHANNEL"
    if [ -n "$sdk_version" ]; then
      sdk_line="**channel $DOTNET_CHANNEL NOT installed** (only $sdk_version is)"
    else
      sdk_line="**NOT installed** (requested channel $DOTNET_CHANNEL)"
    fi
    warning="$(cat <<WARNEOF
> **No .NET $DOTNET_CHANNEL SDK. \`dotnet build\`, \`dotnet test\` and run-umbraco.sh will
> fail in this session.** The install failed at env build; the reason is in $LOG. The usual cause is the
> environment's network allowlist — it must allow \`builds.dotnet.microsoft.com\` and
> \`ci.dot.net\` (see the stub's header). Report any build or test gate as **blocked**, not
> failed, until the environment is fixed: nothing here tested the change.
WARNEOF
)"
  fi
  if [ "$PROVIDER" = "sqlserver" ] && [ "$has_mssql" != "1" ] && [ "$status" = "ready" ]; then
    status="ready on SQLite only — SQL Server was requested and is not available"
  fi

  cat > "$MANIFEST" <<EOF
# Umbraco worker environment — $status ($(date -u +%FT%TZ 2>/dev/null || echo 'time n/a'))

$warning

**Agent: read this first.** Written on every env build (initial or cached rebuild) so you
don't need to probe. There is **no pre-baked Umbraco instance and no auto-boot** — bring one
up yourself with run-umbraco.sh when you need it.

| What        | State |
|-------------|-------|
| Provider    | $PROVIDER |
| .NET SDK    | $sdk_line |
| SQL Server image | $docker_line |
| Skills      | delivered to ~/.claude/skills |
| Ops scripts | $OPS_SCRIPTS_DIR (run-umbraco.sh) |

## Which database to use RIGHT NOW
$db_section

## Bring up Umbraco (run from your repo checkout)
\`\`\`
bash $OPS_SCRIPTS_DIR/run-umbraco.sh --provider <sqlite|sqlserver> --boot "<how this repo starts its site>"
\`\`\`
\`--boot\` is the repo's own start command — its \`ops-workspace\` says what it is. It must honour
\`ASPNETCORE_URLS\` (for \`dotnet run\`, pass \`--no-launch-profile\`). For sqlserver, the
connection string reaches the site as \`ConnectionStrings__umbracoDbDSN\` in its environment;
for sqlite the site keeps its own default. run-umbraco.sh polls the site's server status and
exits non-zero if it never comes up — wait on it, don't re-implement the wait. Give the wrapper
its own log path: the script writes the site's boot log to /tmp/umbraco-run.log itself.
EOF
  log "wrote manifest: $MANIFEST"
}

# ── main ───────────────────────────────────────────────────────────────────
{
  log "===== cloud-env-setup v$VERSION (provider=$PROVIDER, dotnet=$DOTNET_CHANNEL) ====="
  case "$PROVIDER" in
    sqlite|sqlserver) ;;
    *) log "WARN: unknown provider '$PROVIDER' (use sqlite or sqlserver) — treating as sqlite"; PROVIDER=sqlite ;;
  esac
  deliver_skills
  install_dotnet "$DOTNET_CHANNEL"
  [ "$PROVIDER" = "sqlserver" ] && { prep_sqlserver || true; }
  write_manifest
  log "dotnet: $(dotnet --version 2>/dev/null || echo 'not installed')"
  [ "$PROVIDER" = "sqlserver" ] && log "mssql image: $(docker images --format '{{.Size}}' "$MSSQL_IMAGE" 2>/dev/null | head -1 || echo 'not cached')"
  log "===== cloud-env-setup done (manifest: $MANIFEST) ====="
} 2>&1 | tee -a "$LOG"
exit 0
