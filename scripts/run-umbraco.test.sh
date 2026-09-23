#!/usr/bin/env bash
# Tests for run-umbraco.sh. Hermetic: bash only, no network, no Docker, no Umbraco. Fake
# `dotnet`, `docker` and `curl` sit first on PATH, and the --boot command is a fake site that
# records the environment it was started with and then marks itself ready. What is tested is
# the contract a product relies on: --boot is required, sqlite leaves the site's own database
# alone, sqlserver starts one container and hands the site its connection string through the
# environment, and a site that never comes up is a failure, not a hang.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run-umbraco.sh"
[ -f "$RUN" ] || { echo "FATAL: run-umbraco.sh not found"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
count() { local n; n="$(grep -c -e "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }

F="$TMP/fakes"; mkdir -p "$F"
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/dotnet"
# docker: tracks one container named mssql in $OPS_RUN_DIR/containers.
cat > "$F/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$OPS_RUN_DIR/docker.log"
case "$1" in
  info) exit 0 ;;
  ps)   cat "$OPS_RUN_DIR/containers" 2>/dev/null; exit 0 ;;
  run)  echo mssql > "$OPS_RUN_DIR/containers" ;;
  rm)   rm -f "$OPS_RUN_DIR/containers" ;;
  exec) exit 0 ;;
  logs) echo "fake logs" ;;
esac
SH
# curl: the site is "up" once the fake site has written its ready flag.
printf '#!/usr/bin/env bash\n[ -f "$OPS_RUN_DIR/site-ready" ]\n' > "$F/curl"
# The fake site: record what it was started with, then say it is ready.
cat > "$F/site.sh" <<'SH'
#!/usr/bin/env bash
env | grep -E '^(ConnectionStrings__|ASPNETCORE_URLS=)' | sort > "$OPS_RUN_DIR/site.env"
touch "$OPS_RUN_DIR/site-ready"
SH
# A site that never becomes ready.
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/dead-site.sh"
chmod +x "$F"/*

run() { # run <case> [args...]
  local d="$TMP/$1"; shift; mkdir -p "$d"
  env PATH="$F:$PATH" OPS_RUN_DIR="$d" OPS_READY_SLEEP=0 OPS_SQL_SLEEP=0 OPS_READY_TRIES=20 \
    bash "$RUN" "$@" > "$d/out.log" 2>&1
}
wait_for_site() { for _ in $(seq 1 40); do [ -f "$TMP/$1/site.env" ] && return 0; sleep 0.1; done; }

# --- --boot is required ----------------------------------------------------------
run noboot --provider sqlite; rc=$?
check "no --boot is refused"          1 "$rc"
check "  saying what it needs"        1 "$(count 'is required' "$TMP/noboot/out.log")"

# --- an unknown provider is refused ----------------------------------------------
run badprov --provider postgres --boot "bash $F/site.sh"; rc=$?
check "an unknown provider is refused" 1 "$rc"

# --- sqlite: the site keeps its own database --------------------------------------
run sqlite --provider sqlite --port 45001 --boot "bash $F/site.sh"; rc=$?; wait_for_site sqlite
check "a sqlite boot exits 0"                     0 "$rc"
check "  starts the site on the requested port"   1 "$(count '^ASPNETCORE_URLS=https://localhost:45001$' "$TMP/sqlite/site.env")"
check "  hands it no connection string"           0 "$(count '^ConnectionStrings__' "$TMP/sqlite/site.env")"
check "  never touches docker"                    0 "$(count '^docker' "$TMP/sqlite/docker.log")"
check "  and records the base URL"                "https://localhost:45001" "$(cat "$TMP/sqlite/umbraco-base-url" 2>/dev/null)"

# --- sqlserver: one container, connection string through the environment ---------
run sql --provider sqlserver --boot "bash $F/site.sh"; rc=$?; wait_for_site sql
pw="$(cat "$TMP/sql/ops-mssql.pass" 2>/dev/null)"
check "a sqlserver boot exits 0"                  0 "$rc"
check "  starts one SQL Server container"         1 "$(count '^docker run -d --name mssql' "$TMP/sql/docker.log")"
check "  hands the site the SQL connection string" 1 \
  "$(count "^ConnectionStrings__umbracoDbDSN=Server=localhost,1433;Database=umbraco-local;User Id=sa;Password=$pw;" "$TMP/sql/site.env")"
check "  and the SQL Server provider"             1 "$(count '^ConnectionStrings__umbracoDbDSN_ProviderName=Microsoft.Data.SqlClient$' "$TMP/sql/site.env")"
check "  with a generated password, not a fixed one" 1 "$( [ "${#pw}" -ge 16 ] && echo 1 || echo 0)"
check "  that never appears in the output"        0 "$(count "$pw" "$TMP/sql/out.log")"

# --- a second boot in the same session reuses the container ----------------------
rm -f "$TMP/sql/site.env" "$TMP/sql/site-ready"
env PATH="$F:$PATH" OPS_RUN_DIR="$TMP/sql" OPS_READY_SLEEP=0 OPS_SQL_SLEEP=0 OPS_READY_TRIES=20 \
  bash "$RUN" --provider sqlserver --boot "bash $F/site.sh" > "$TMP/sql/out2.log" 2>&1; wait_for_site sql
check "a second boot starts no second container" 1 "$(count '^docker run -d --name mssql' "$TMP/sql/docker.log")"
check "  and keeps the same password"            "$pw" "$(cat "$TMP/sql/ops-mssql.pass")"

# --- a container this script did not start is replaced ----------------------------
# Its password is unknown, so there is no connection string to give the site.
mkdir -p "$TMP/foreign"; echo mssql > "$TMP/foreign/containers"
run foreign --provider sqlserver --boot "bash $F/site.sh"; wait_for_site foreign
check "a foreign mssql container is removed"      1 "$(count '^docker rm -f mssql' "$TMP/foreign/docker.log")"
check "  and a fresh one started"                 1 "$(count '^docker run -d --name mssql' "$TMP/foreign/docker.log")"

# --- two fresh containers never share a password ---------------------------------
run sql2 --provider sqlserver --boot "bash $F/site.sh"; wait_for_site sql2
check "each fresh container gets its own password" "different" \
  "$( [ "$(cat "$TMP/sql2/ops-mssql.pass")" != "$pw" ] && echo different || echo same)"

# --- a site that never comes up fails, and says so --------------------------------
d="$TMP/dead"; mkdir -p "$d"
env PATH="$F:$PATH" OPS_RUN_DIR="$d" OPS_READY_SLEEP=0 OPS_READY_TRIES=3 \
  bash "$RUN" --provider sqlite --boot "bash $F/dead-site.sh" > "$d/out.log" 2>&1; rc=$?
check "a site that never comes up exits non-zero" 1 "$rc"
check "  and says it did not become ready"        1 "$(count 'did not become ready' "$d/out.log")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
