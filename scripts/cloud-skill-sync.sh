#!/usr/bin/env bash
# cloud-skill-sync — deliver the engine to a Claude Code cloud environment.
#
# Paste this into a cloud environment's **Setup script** field. It runs once when the
# environment builds, BEFORE any session starts, clones this public repo, and installs:
#
#   every skill under plugins/*/skills/*   -> $HOME/.claude/skills
#   every agent under plugins/*/agents/*   -> $HOME/.claude/agents
#   the ops-learnings capture hooks        -> $HOME/.claude/ops-hooks, registered in
#                                             $HOME/.claude/settings.json
#
# Cloud routines in that environment then invoke those skills by name, spawn the agents, and
# fire the capture hooks. No per-repo marketplace marker, no committed skill files, no manual
# upload, and no token: the repo is public, so the clone is anonymous and the runner's egress
# proxy stays free for the routine's own GitHub work.
#
# WHY IT COPIES EVERYTHING. The prototype kept a hand-maintained list of skills to deliver,
# which is one more thing to forget when a skill is added — a routine then fails at run time
# with "skill not found". Every skill in this repo is engine machinery a loop may reach for,
# so the list is the repo.
#
# WHY THE HOOKS NEED WIRING. An installed plugin auto-registers its hooks through
# ${CLAUDE_PLUGIN_ROOT}. A *copied* skill does not, so this script writes the SubagentStop /
# SessionEnd entries into settings.json itself. Without that, proto-learning capture works
# locally and silently does nothing in cloud — which is where most runs happen.
#
# REFRESHING. The environment snapshot is cached (~7 days), and changing the source repo does
# NOT bust it — only editing this script does. Bump VERSION and re-save to force a re-clone.
#
# DEBUGGING. The run log is $HOME/skill-sync.log, readable from inside the session. The
# environment *build* log is not visible to the session, which is why this logs to a file.
#
# Env knobs (ops + test):
#   OPS_SRC   use an existing checkout instead of cloning (a branch-pointed env, or a test)
#   OPS_REPO  clone a different repo/fork
#   OPS_HOME  install under this root instead of $HOME
set -u

VERSION="1"
REPO="${OPS_REPO:-https://github.com/umbraco/umbraco-ai-ops}"
HOME_DIR="${OPS_HOME:-$HOME}"
SKILLS_DEST="$HOME_DIR/.claude/skills"
AGENTS_DEST="$HOME_DIR/.claude/agents"
HOOKS_ROOT="$HOME_DIR/.claude/ops-hooks"
SETTINGS="$HOME_DIR/.claude/settings.json"
LOG="$HOME_DIR/skill-sync.log"

mkdir -p "$SKILLS_DEST" "$AGENTS_DEST"
{
  echo "===== cloud-skill-sync v$VERSION ====="

  # Source of truth: an env that was launched from a checkout passes OPS_SRC, so a
  # branch-pointed environment delivers THAT branch. Otherwise clone the default branch.
  if [ -n "${OPS_SRC:-}" ] && [ -d "$OPS_SRC/plugins" ]; then
    OPS_DIR="$OPS_SRC"; echo "using provided source (no clone): $OPS_DIR"
  else
    rm -rf /tmp/ops
    if git clone --depth 1 "$REPO" /tmp/ops >/dev/null 2>&1; then
      OPS_DIR=/tmp/ops; echo "cloned $REPO"
    else
      echo "FATAL: could not clone $REPO — the environment will have no skills"
    fi
  fi

  if [ -n "${OPS_DIR:-}" ]; then
    # --- skills ----------------------------------------------------------
    count=0
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      name="$(basename "$src")"
      rm -rf "$SKILLS_DEST/$name"
      if cp -r "$src" "$SKILLS_DEST/$name"; then
        count=$((count + 1)); echo "installed skill: $name"
      else
        echo "FAILED to install skill: $name"
      fi
    done < <(find "$OPS_DIR/plugins" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' 2>/dev/null | sort)
    echo "skills installed: $count"
    [ "$count" -gt 0 ] || echo "WARNING: no skills found under $OPS_DIR/plugins — is this the right checkout?"

    # --- agents ----------------------------------------------------------
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      cp "$a" "$AGENTS_DEST/" && echo "installed agent: $(basename "$a")"
    done < <(find "$OPS_DIR/plugins" -type f -path '*/agents/*.md' 2>/dev/null | sort)

    # --- the capture hooks, plus their settings.json wiring --------------
    plug="$(find "$OPS_DIR/plugins" -maxdepth 1 -type d -name 'ops-learnings' 2>/dev/null | head -1)"
    if [ -n "$plug" ] && [ -d "$plug/hooks" ]; then
      rm -rf "$HOOKS_ROOT"; mkdir -p "$HOOKS_ROOT"
      cp -r "$plug/hooks" "$HOOKS_ROOT/hooks"
      # The hook script resolves its schema relative to its own plugin root, so the
      # skills tree it expects has to exist under the stand-in root too.
      mkdir -p "$HOOKS_ROOT/skills/ops-triage-loop"
      [ -d "$plug/skills/ops-triage-loop/references" ] \
        && cp -r "$plug/skills/ops-triage-loop/references" "$HOOKS_ROOT/skills/ops-triage-loop/references"
      echo "installed capture hooks under $HOOKS_ROOT"

      if command -v jq >/dev/null 2>&1; then
        [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
        tmp="$SETTINGS.tmp.$$"
        if jq --arg root "$HOOKS_ROOT" '
              def entry($scope):
                { hooks: [ { type: "command",
                             command: ("bash \"" + $root + "/hooks/capture-proto-learning.sh\" " + $scope),
                             async: true } ] };
              .hooks = ((.hooks // {})
                        | .SubagentStop = [entry("subagent")]
                        | .SessionEnd   = [entry("orchestrator")])
            ' "$SETTINGS" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
          mv "$tmp" "$SETTINGS"; echo "registered capture hooks in $SETTINGS"
        else
          rm -f "$tmp"; echo "FAILED to register hooks in $SETTINGS — capture will not run in cloud"
        fi
      else
        echo "no jq — cannot register hooks in $SETTINGS; capture will not run in cloud"
      fi
    else
      echo "no ops-learnings plugin in source — capture hooks not installed"
    fi
  fi
  echo "===== done ====="
} >>"$LOG" 2>&1

# Never fail the environment build: a session with some skills is better than no session, and
# the log says exactly what is missing.
exit 0
