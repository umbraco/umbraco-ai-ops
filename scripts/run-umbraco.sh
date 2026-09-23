#!/usr/bin/env bash
# run-umbraco.sh — bring up a local Umbraco for testing, with a choice of DB provider.
# Run from a checkout of the product repo, in a session. cloud-env-setup.sh copies this into
# $HOME/.umbraco-ops/ at env build; the env manifest points here.
#
#   --provider sqlite      (default) server-less SQLite: the site keeps its own default DB.
#   --provider sqlserver   CI-parity: SQL Server 2022 via Docker, from the image env-build cached.
#   --boot "<command>"     REQUIRED. How this repo starts its site, e.g.
#                          "dotnet run --project path/to/Site.csproj --no-launch-profile".
#                          The repo's own ops-workspace says what it is.
#   --port <n>             HTTPS port for the site (default 44380).
#   --ready-path <path>    what to poll for readiness (default Umbraco's server status).
#
# A copy of umbraco-mcp-ops scripts/cloud-skill-sync/run-umbraco.sh. The provider half — the
# flag, Docker, the SQL Server container and its readiness wait — is kept as it was. The boot
# half is swapped: the original booted the MCP repo's demo-site-template through that repo's
# npm scripts and then created an API user for its tests, none of which any other product has.
# Here the product supplies its own start command with --boot, and gets the database through
# its environment: `ConnectionStrings__umbracoDbDSN` (+ `_ProviderName`) override appsettings,
# so nothing is written into the product's files.
#
# Also changed: the SQL Server `sa` password is generated per container instead of a fixed
# string copied from one repo's CI. It is a throwaway local container either way, but a
# committed password reads as a leaked one to every scanner and reviewer.
#
# Assumes cloud-env-setup.sh already installed the .NET SDK (dotnet on PATH via /usr/local/bin).
# Prints the base URL on success; leaves Umbraco running in the background.
set -uo pipefail

PROVIDER="sqlite"; BOOT=""; PORT="${OPS_UMBRACO_PORT:-44380}"
READY_PATH="/umbraco/management/api/v1/server/status"
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)   PROVIDER="${2:-}"; shift 2 ;;
    --boot)       BOOT="${2:-}"; shift 2 ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --ready-path) READY_PATH="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
export NODE_TLS_REJECT_UNAUTHORIZED=0   # the site uses a self-signed HTTPS dev cert

# CI-parity SQL Server
MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
MSSQL_DB="${OPS_MSSQL_DB:-umbraco-local}"
# FIXED path matching cloud-env-setup.sh, so a session's dockerd sees the env-build-cached image.
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/root/.docker-data}"
RUN_DIR="${OPS_RUN_DIR:-/tmp}"
PASSFILE="$RUN_DIR/ops-mssql.pass"
BOOT_LOG="$RUN_DIR/umbraco-run.log"

[ -n "$BOOT" ] || { echo "ERROR: --boot \"<command>\" is required — how this repo starts its site (see its ops-workspace)"; exit 1; }
command -v dotnet >/dev/null 2>&1 || { echo "ERROR: dotnet not on PATH — cloud-env-setup.sh installs it"; exit 1; }

# The routine env ships no Docker — install the engine and start the daemon on demand
# (only for --provider sqlserver). Needs root + a daemon that can actually run here; if
# `dockerd` can't start (unprivileged sandbox), this reports it.
ensure_docker() {
  # The env usually already has a running daemon — use it directly.
  if docker info >/dev/null 2>&1; then echo "docker ready (existing daemon)"; return 0; fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "installing docker engine…"
    if command -v apt-get >/dev/null 2>&1; then
      (apt-get update -qq && apt-get install -y docker.io) || echo "WARN: apt-get docker.io failed"
    else
      echo "ERROR: no apt-get to install docker"; return 1
    fi
  fi
  echo "starting docker daemon (data-root $DOCKER_DATA_ROOT)…"
  mkdir -p "$DOCKER_DATA_ROOT"
  service docker stop >/dev/null 2>&1 || true
  (nohup dockerd --data-root "$DOCKER_DATA_ROOT" >/tmp/dockerd.log 2>&1 &)
  for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || {
    echo "ERROR: docker installed but the daemon won't run in this env (likely no privileged/dind support)."
    echo "       See /tmp/dockerd.log. Use --provider sqlite here, and treat CI as the SQL Server gate."
    return 1
  }
}

mkdir -p "$RUN_DIR"

case "$PROVIDER" in
  sqlite)
    echo "SQLite: the site keeps its own default connection string" ;;
  sqlserver)
    ensure_docker || { echo "ERROR: docker unavailable — cannot run the SQL Server container"; exit 1; }
    # Reuse a running container only if this script started it and still has its password.
    if docker ps --format '{{.Names}}' | grep -qx mssql && [ -s "$PASSFILE" ]; then
      SA_PASSWORD="$(cat "$PASSFILE")"
      echo "SQL Server container already running — reusing it"
    else
      SA_PASSWORD="Ops-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')-9Q"
      printf '%s' "$SA_PASSWORD" > "$PASSFILE"; chmod 600 "$PASSFILE" 2>/dev/null || true
      echo "starting SQL Server 2022 (docker)…"
      docker rm -f mssql >/dev/null 2>&1 || true
      docker run -d --name mssql -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$SA_PASSWORD" -p 1433:1433 "$MSSQL_IMAGE" >/dev/null \
        || { echo "ERROR: could not start SQL Server container"; exit 1; }
    fi
    echo "waiting for SQL Server to accept connections…"
    ready=0
    for _ in $(seq 1 "${OPS_SQL_TRIES:-40}"); do
      if docker exec mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -Q "SELECT 1" >/dev/null 2>&1; then ready=1; break; fi
      sleep "${OPS_SQL_SLEEP:-3}"
    done
    [ "$ready" -eq 1 ] || { echo "ERROR: SQL Server did not become ready"; docker logs --tail 40 mssql; exit 1; }
    echo "SQL Server ready; the site gets its connection string through its environment"
    export ConnectionStrings__umbracoDbDSN="Server=localhost,1433;Database=$MSSQL_DB;User Id=sa;Password=$SA_PASSWORD;TrustServerCertificate=True"
    export ConnectionStrings__umbracoDbDSN_ProviderName="Microsoft.Data.SqlClient"
    ;;
  *) echo "ERROR: unknown --provider '$PROVIDER' (use sqlite or sqlserver)"; exit 1 ;;
esac

dotnet dev-certs https >/dev/null 2>&1 || true

echo "starting Umbraco ($PROVIDER)…"
ASPNETCORE_URLS="https://localhost:$PORT" nohup bash -c "$BOOT" > "$BOOT_LOG" 2>&1 &
base=""
tries="${OPS_READY_TRIES:-90}"
for i in $(seq 1 "$tries"); do
  if curl -ksf "https://localhost:$PORT$READY_PATH" >/dev/null 2>&1; then base="https://localhost:$PORT"; break; fi
  if [ $((i % 6)) -eq 0 ]; then echo "still booting (~$((i * ${OPS_READY_SLEEP:-5}))s)…"; tail -n 1 "$BOOT_LOG" 2>/dev/null; fi
  sleep "${OPS_READY_SLEEP:-5}"
done
[ -n "$base" ] || { echo "ERROR: Umbraco did not become ready; boot log:"; tail -n 40 "$BOOT_LOG"; exit 1; }

printf '%s' "$base" > "$RUN_DIR/umbraco-base-url"
echo ""
echo "==> Umbraco ($PROVIDER) ready at $base"
echo "==> Base URL also in $RUN_DIR/umbraco-base-url; boot log in $BOOT_LOG"
