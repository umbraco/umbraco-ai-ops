#!/usr/bin/env bash
# ── PASTE THIS, AND ONLY THIS, INTO THE CLOUD ENVIRONMENT'S "Setup script" FIELD ──
#
# It clones the engine and runs the real setup (scripts/cloud-env-setup.sh), which delivers
# every skill and agent, wires the capture hooks, installs the .NET SDK, and — for a SQL Server
# env — installs Docker and caches the mssql image. A session then boots its own Umbraco with
# run-umbraco.sh. All logic lives in the repo and changes by PR; you only re-paste THIS.
#
# TWO ENVIRONMENTS — set PROVIDER below:
#   sqlite     lean env: SDK + skills. Sessions run Umbraco on server-less SQLite.
#   sqlserver  CI-parity env: also installs Docker + caches the mssql:2022 image (~2.3 GB)
#              so sessions can run Umbraco on SQL Server exactly as CI does.
#
# DOTNET_CHANNEL: the major.minor of the SDK in the repo's global.json (10.0.102 → 10.0).
# If one environment serves several repos, use the channel they share.
#
# NETWORK ACCESS — ADD THESE TO THE ENVIRONMENT'S ALLOWED DOMAINS before saving. Without them
# the SDK install fails with HTTP 403, the build carries on, and every session has no .NET:
#   builds.dotnet.microsoft.com   the .NET SDK itself
#   ci.dot.net                    the .NET installer's fallback source
#   myget.org, www.myget.org      Umbraco's prerelease and nightly NuGet feeds
#   dev.azure.com                 CI builds and logs, for repos whose CI is Azure Pipelines
# Changing the allowlist does NOT rebuild the environment by itself — bump `rebuild:` as well.
#
# NO TOKEN. `umbraco/umbraco-ai-ops` is public, so the clone is anonymous. This stub used to
# require OPS_TOKEN and said so in three places, because the repo was private; that is no longer
# true and the support is gone rather than left as a knob nobody needs. If the engine is ever
# made private again, the token handling has to come back HERE, in the field, and everyone
# re-pastes — which is the real cost of that decision.
#
# TO PICK UP A NEWER ENGINE: bump the `rebuild:` number below and re-save.
# This is not optional and it is not obvious. The environment snapshot is cached, and it is
# busted ONLY by the text of this field changing — a stub that always clones `main` does NOT
# re-run just because the repo moved on. Changing one digit here is the whole mechanism.
#
# TO TRY A BRANCH: set REF to it in a test environment. Leave it on `main` everywhere else.
#
# WHY THE CLONE IS DUPLICATED HERE. These few lines repeat what cloud-skill-sync.sh does,
# which is unavoidable: you cannot run the shared code before you have fetched it. Keep this
# file as small as it is, and put every change in cloud-env-setup.sh instead.
set -e
PROVIDER=sqlite          # <-- set to `sqlserver` for the CI-parity environment
DOTNET_CHANNEL=10.0      # <-- the major.minor in the repo's global.json
# rebuild: 2

REPO="${OPS_REPO:-https://github.com/umbraco/umbraco-ai-ops}"
REF="${OPS_REF:-main}"

rm -rf /tmp/ops-boot
if ! git clone --depth 1 --branch "$REF" "$REPO" /tmp/ops-boot >/dev/null 2>&1; then
  echo "FATAL: could not clone $REPO at $REF"
  echo "  The engine is public, so this is a network or URL problem, not an auth one."
  echo "  Check the runner has egress to github.com, that OPS_REPO, if you set it, is right,"
  echo "  and that the branch in REF exists."
  exit 1
fi

DOTNET_CHANNEL="$DOTNET_CHANNEL" bash /tmp/ops-boot/scripts/cloud-env-setup.sh --provider "$PROVIDER"
