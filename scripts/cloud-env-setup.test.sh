#!/usr/bin/env bash
# Tests for cloud-env-setup.sh. Hermetic: bash + jq, no network. $HOME is a temp dir and
# fake `dotnet`, `docker` and `curl` sit first on PATH, so no test installs an SDK, starts a
# daemon or downloads anything. What is tested is the script's own decisions: deliver the
# skills, skip an SDK that is already there, cache SQL Server only for a sqlserver env, and
# always leave a manifest that says truthfully what the environment has.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/cloud-env-setup.sh"
[ -f "$SETUP" ] || { echo "FATAL: cloud-env-setup.sh not found"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
count() { local n; n="$(grep -c -e "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"; }

F="$TMP/fakes"; mkdir -p "$F"
# dotnet: reports the SDKs in $FAKE_SDKS (default one 10.0 SDK).
cat > "$F/dotnet" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --list-sdks) for v in ${FAKE_SDKS-10.0.102}; do echo "$v [/fake/sdk]"; done ;;
  --version) set -- ${FAKE_SDKS-10.0.102}; [ -n "${1:-}" ] && echo "$1" || exit 1 ;;
esac
SH
# docker: a daemon that is up; the image is cached only when $FAKE_IMAGE=cached.
cat > "$F/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  image) [ "${FAKE_IMAGE:-}" = cached ] ;;
  images) echo "2.3GB" ;;
  pull) exit 0 ;;
esac
SH
# curl: every download fails, and is recorded.
printf '#!/usr/bin/env bash\necho "curl $*" >> "$FAKE_LOG"\nexit 1\n' > "$F/curl"
chmod +x "$F"/*

run() { # run <home> [VAR=value...] [args...]
  local h="$1"; shift
  mkdir -p "$h/bin"
  local envs=() args=()
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) args+=("$a") ;; esac; done
  env HOME="$h" PATH="$F:$PATH" OPS_BIN_DIR="$h/bin" FAKE_LOG="$h/fake.log" ${envs[@]+"${envs[@]}"} \
    bash "$SETUP" ${args[@]+"${args[@]}"} >/dev/null 2>&1
}
man() { cat "$1/env-manifest.md" 2>/dev/null; }

# --- sqlite: the lean env ------------------------------------------------------
H="$TMP/sqlite"; run "$H" --provider sqlite; rc=$?
check "a sqlite env exits 0"                    0 "$rc"
check "  delivers the skills"                   "yes" "$( [ -f "$H/.claude/skills/ops-issue-loop/SKILL.md" ] && echo yes || echo no)"
check "  writes the manifest"                   "yes" "$( [ -f "$H/env-manifest.md" ] && echo yes || echo no)"
check "  saying the provider"                   1 "$(man "$H" | grep -c '| Provider    | sqlite |')"
check "  and that only SQLite is available"     1 "$(man "$H" | grep -c 'Only \*\*SQLite\*\* is available')"
check "  and installs run-umbraco.sh"           "yes" "$( [ -f "$H/.umbraco-ops/run-umbraco.sh" ] && echo yes || echo no)"
check "  downloads no SDK it already has"       0 "$(count '^curl' "$H/fake.log")"
check "  and never touches docker"              0 "$(count '^docker' "$H/fake.log")"
check "  and logs the run"                      1 "$(count 'cloud-env-setup done' "$H/env-setup.log")"

# --- no --provider at all: the same lean env -----------------------------------
H="$TMP/default"; run "$H"
check "no provider means sqlite"   1 "$(man "$H" | grep -c '| Provider    | sqlite |')"

# --- sqlserver, image already cached --------------------------------------------
H="$TMP/cached"; run "$H" FAKE_IMAGE=cached --provider sqlserver; rc=$?
check "a sqlserver env exits 0"                 0 "$rc"
check "  says SQL Server is available"          1 "$(man "$H" | grep -c 'SQL Server is available')"
check "  and does not pull a cached image"      0 "$(count '^docker pull' "$H/fake.log")"

# --- sqlserver, image not cached yet ---------------------------------------------
H="$TMP/uncached"; run "$H" --provider sqlserver
check "an uncached image is pulled"             1 "$(count "^docker pull mcr.microsoft.com/mssql/server:2022-latest" "$H/fake.log")"
check "  and the manifest does not claim it"    1 "$(man "$H" | grep -c 'requested but image NOT cached')"

# --- an unknown provider falls back, loudly --------------------------------------
H="$TMP/unknown"; run "$H" --provider postgres; rc=$?
check "an unknown provider still exits 0"       0 "$rc"
check "  is built as sqlite"                    1 "$(man "$H" | grep -c '| Provider    | sqlite |')"
check "  and the log says so"                   1 "$(count "unknown provider 'postgres'" "$H/env-setup.log")"

# --- a channel that is not installed, and a download that fails -------------------
H="$TMP/missing"; run "$H" DOTNET_CHANNEL=9.0 --provider sqlite; rc=$?
check "a failed SDK install still exits 0"      0 "$rc"
check "  it tried the raw GitHub installer"     1 "$(count 'raw.githubusercontent.com/dotnet/install-scripts' "$H/fake.log")"
check "  and logs the failure"                  1 "$(count 'could not download dotnet-install.sh' "$H/env-setup.log")"
check "  and still writes the manifest"         "yes" "$( [ -f "$H/env-manifest.md" ] && echo yes || echo no)"
check "  naming the channel it asked for"       1 "$(man "$H" | grep -c 'requested channel 9.0')"

# --- no SDK on the machine at all ------------------------------------------------
H="$TMP/nosdk"; run "$H" FAKE_SDKS= --provider sqlite
check "with no SDK the manifest says so"        1 "$(man "$H" | grep -c 'NOT installed')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
