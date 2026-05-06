#!/usr/bin/env bash
#
# Bitrise QA Agent — RDE template startup script.
# Runs on EVERY session start (initial provisioning + every restart of an
# archived session). Sits between `claudeAISetup` (refresh creds) and the
# backend's terminal sleep loop.
#
# Startup is intentionally minimal: pick the Xcode (so DEVELOPER_DIR is in
# the env the watcher inherits), then fork the watcher detached. All
# simulator handling — waiting for the background `simctl create` started by
# warmup.sh, booting it, bootstatus, and writing /tmp/.qa-agent-info.json —
# is now the watcher's job. That keeps startup off the critical path so the
# session reaches RUNNING in seconds even if the simulator is still
# initializing in the background.

set -euo pipefail

log() { echo "[qa-agent startup] $*"; }

XCODE_VERSION="${XCODE_VERSION:-26.3}"

if [ "$(uname)" != "Darwin" ]; then
  log "ERROR: QA Agent template only supports macOS sessions." >&2
  exit 1
fi

# Match warmup.sh: pick the same Xcode so the watcher's simctl calls hit
# the version the simulator was created against. Bitrise images install
# Xcode under /Applications/Xcode-${MAJOR.MINOR.PATCH}.app — fall back to a
# `Xcode-${MAJOR.MINOR}.*.app` glob so a request like "26.3" resolves to
# "Xcode-26.3.0.app" (highest patch wins).
XCODE_PATH=""
for _candidate in \
  "/Applications/Xcode-${XCODE_VERSION}.app" \
  "/Applications/Xcode_${XCODE_VERSION}.app"; do
  if [ -d "$_candidate" ]; then
    XCODE_PATH="$_candidate"; break
  fi
done
if [ -z "$XCODE_PATH" ]; then
  XCODE_PATH="$(ls -d "/Applications/Xcode-${XCODE_VERSION}".*.app 2>/dev/null | sort -V | tail -n 1)"
fi
if [ -z "$XCODE_PATH" ] || [ ! -d "$XCODE_PATH" ]; then
  log "ERROR: Xcode ${XCODE_VERSION} not found at /Applications/Xcode-${XCODE_VERSION}.app or /Applications/Xcode-${XCODE_VERSION}.*.app" >&2
  exit 1
fi
export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
log "using Xcode ${XCODE_VERSION} at $XCODE_PATH"

# ---------- Fork the upload watcher ----------------------------------------
# Detached from this script's process tree (setsid + nohup) so it survives
# after startup.sh returns and the parent inner-script transitions into
# `sleep 2147483647`. The watcher inherits AI_PROMPT and PATH from this env.
#
# AI_PROMPT comes from session.AiPrompt (set by the CLI). When it's set,
# the codespaces backend's claudeAIAutoStart ALSO fires at the end of
# warmup and creates a competing claude-auto running plain `claude`; the
# watcher's first job is to kill+recreate that session in yolo mode.

WATCHER="$HOME/.qa-agent/watcher.sh"
if [ -z "${AI_PROMPT:-}" ]; then
  log "WARN: AI_PROMPT not set — watcher will not start. Did the CLI forget to set ai_prompt? The session will reach RUNNING but no QA run will fire."
elif [ ! -x "$WATCHER" ]; then
  log "ERROR: $WATCHER missing or not executable — warmup did not complete." >&2
  exit 1
else
  # nohup + & alone leaves the watcher attached to the controlling terminal,
  # so use setsid (or `disown` fallback on systems without it) to reparent.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$WATCHER" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$WATCHER" </dev/null >/dev/null 2>&1 &
    disown
  fi
  log "upload watcher started (pid=$!, log: \$HOME/.qa-agent/launcher.log)"
fi
