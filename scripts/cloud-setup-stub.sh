#!/usr/bin/env bash
# ── PASTE THIS, AND ONLY THIS, INTO THE CLOUD ENVIRONMENT'S "Setup script" FIELD ──
#
# It clones the engine and runs the real setup (scripts/cloud-skill-sync.sh), which delivers
# every skill and agent into the environment and wires the capture hooks. All the logic lives
# in the repo and changes by PR; this stub is the only thing you ever paste.
#
# BEFORE IT WILL WORK: set OPS_TOKEN in the environment's variables to a token that can read
# `umbraco/umbraco-ai-ops`. The repo is PRIVATE, so without one the clone fails and the
# environment comes up with no skills — which looks like the loops silently doing nothing
# rather than like a setup failure. GH_TOKEN or GITHUB_TOKEN are accepted instead.
#
# TO PICK UP A NEWER ENGINE: bump the `rebuild:` number below and re-save.
# This is not optional and it is not obvious. The environment snapshot is cached, and it is
# busted ONLY by the text of this field changing — a stub that always clones `main` does NOT
# re-run just because the repo moved on. Changing one digit here is the whole mechanism.
#
# WHY THE CLONE IS DUPLICATED HERE. These few lines repeat what cloud-skill-sync.sh does,
# which is unavoidable: you cannot run the shared code before you have fetched it. Keep this
# file as small as it is, and put every change in cloud-skill-sync.sh instead.
set -e

# rebuild: 1

REPO="${OPS_REPO:-https://github.com/umbraco/umbraco-ai-ops}"
TOKEN="${OPS_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

url="$REPO"
case "$REPO" in
  https://github.com/*)
    [ -n "$TOKEN" ] && url="https://x-access-token:${TOKEN}@github.com/${REPO#https://github.com/}"
    ;;
esac

rm -rf /tmp/ops-boot
# Never echo $url — it carries the token. Errors mention $REPO only.
if ! git clone --depth 1 "$url" /tmp/ops-boot >/dev/null 2>&1; then
  echo "FATAL: could not clone $REPO"
  if [ -z "$TOKEN" ]; then
    echo "  This repo is private. Set OPS_TOKEN (or GH_TOKEN / GITHUB_TOKEN) in the environment."
  else
    echo "  A token was set but the clone failed — check it can read $REPO and has not expired."
  fi
  exit 1
fi
unset TOKEN url

# Hand the checkout over so cloud-skill-sync does not clone a second time.
OPS_SRC=/tmp/ops-boot bash /tmp/ops-boot/scripts/cloud-skill-sync.sh
