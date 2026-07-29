#!/usr/bin/env bash
# ── PASTE THIS, AND ONLY THIS, INTO THE CLOUD ENVIRONMENT'S "Setup script" FIELD ──
#
# It clones the engine and runs the real setup (scripts/cloud-skill-sync.sh), which delivers
# every skill and agent into the environment and wires the capture hooks. All the logic lives
# in the repo and changes by PR; this stub is the only thing you ever paste.
#
# NO TOKEN, NO VARIABLES, NOTHING TO SET UP FIRST. `umbraco/umbraco-ai-ops` is public, so the
# clone is anonymous. This stub used to require OPS_TOKEN and said so in three places, because
# the repo was private; that is no longer true and the support is gone rather than left as a
# knob nobody needs. If the engine is ever made private again, the token handling has to come
# back HERE, in the field, and everyone re-pastes — which is the real cost of that decision.
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

rm -rf /tmp/ops-boot
if ! git clone --depth 1 "$REPO" /tmp/ops-boot >/dev/null 2>&1; then
  echo "FATAL: could not clone $REPO"
  echo "  The engine is public, so this is a network or URL problem, not an auth one."
  echo "  Check the runner has egress to github.com and that OPS_REPO, if you set it, is right."
  exit 1
fi

# Hand the checkout over so cloud-skill-sync does not clone a second time.
OPS_SRC=/tmp/ops-boot bash /tmp/ops-boot/scripts/cloud-skill-sync.sh
