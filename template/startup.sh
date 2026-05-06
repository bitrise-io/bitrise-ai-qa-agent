#!/usr/bin/env bash
#
# Bitrise QA Agent — RDE template startup script.
# Runs on EVERY session start (initial provisioning + every restart of an
# archived session). Sits between `claudeAISetup` (refresh creds) and the
# backend's terminal sleep loop.
#
# Performed work:
#   1. Boot the simulator created by warmup.sh.
#   2. Publish a known-path manifest with { udid, session_id } so MCP tools
#      and the prompt can target *this* session.
#   3. Fork the upload watcher (installed by warmup.sh): it blocks until the
#      CLI's `--upload` lands in /tmp, then launches Claude in tmux with
#      $QA_PROMPT. We do NOT use the codespaces backend's claudeAIAutoStart
#      path here — that fires immediately at warmup with $AI_PROMPT, which
#      means Claude burns tokens polling for the file from inside its own
#      loop. Instead, the CLI passes the prompt as a $QA_PROMPT session input
#      (with expose_as_env_var=true) and we launch Claude only once there's
#      something to act on.
#
# The QA_PROMPT should look something like:
#
#   You are a QA tester. The app is at $(cat ~/.qa-agent/upload-path).
#   Read /tmp/.qa-agent-info.json for { udid, session_id }.
#   Install: xcrun simctl install <udid> <upload-path>
#   Launch the app, then drive it with the qa-agent MCP tools
#   (qa_screenshot, qa_click, qa_scroll) to verify <task>.
#   Report results, then exit.

set -euo pipefail

log() { echo "[qa-agent startup] $*"; }

XCODE_VERSION="${XCODE_VERSION:-26.3}"
UDID_FILE="$HOME/.qa-agent-simulator-udid"
INFO_FILE="/tmp/.qa-agent-info.json"

if [ "$(uname)" != "Darwin" ]; then
  log "ERROR: QA Agent template only supports macOS sessions." >&2
  exit 1
fi

# Match warmup.sh: pick the same Xcode for every simctl call so the version
# the simulator was created against is the version we boot it with.
XCODE_PATH=""
for _candidate in \
  "/Applications/Xcode-${XCODE_VERSION}.app" \
  "/Applications/Xcode_${XCODE_VERSION}.app"; do
  if [ -d "$_candidate" ]; then
    XCODE_PATH="$_candidate"; break
  fi
done
if [ -z "$XCODE_PATH" ]; then
  log "ERROR: Xcode ${XCODE_VERSION} not found at /Applications/Xcode-${XCODE_VERSION}.app" >&2
  exit 1
fi
export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
log "using Xcode ${XCODE_VERSION} at $XCODE_PATH"

if [ ! -s "$UDID_FILE" ]; then
  log "ERROR: $UDID_FILE missing — warmup.sh did not run successfully." >&2
  exit 1
fi
UDID="$(tr -d '[:space:]' < "$UDID_FILE")"

# ---------- Kick off the simulator boot (non-blocking) ---------------------
# We deliberately do NOT call `xcrun simctl bootstatus -b` here. That blocks
# until the simulator is fully booted (springboard ready), which on a fresh
# image cold-boot can take minutes — and until startup.sh returns, the
# codespaces backend can't transition the session to RUNNING. The watcher
# (forked below) waits for that full boot right before it launches Claude,
# overlapping the boot wait with the upload wait.

current_state() {
  xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
udid = '$UDID'
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['udid'] == udid:
            print(d.get('state', 'Unknown')); sys.exit()
print('NotFound')
"
}

state="$(current_state)"
case "$state" in
  Booted)
    log "simulator $UDID already booted"
    ;;
  Booting)
    log "simulator $UDID already booting — leaving it to finish in the background"
    ;;
  Shutdown | Shutting\ Down)
    log "issuing async boot for simulator $UDID (state=$state)"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    ;;
  NotFound)
    log "ERROR: simulator $UDID not registered with simctl — was the device deleted?" >&2
    exit 1
    ;;
  *)
    log "simulator in unexpected state '$state', issuing boot anyway"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    ;;
esac

# ---------- Publish manifest for the prompt --------------------------------
# session_id is parsed out of the backend-injected webhook URL, which has the
# shape `<base>/v1/machines/sessions/<session_id>/notifications` (see
# bitrise-codespaces session_start.go:309). It's the only env var that
# carries the session ID into the script.

SESSION_ID=""
if [ -n "${CODESPACES_NOTIFICATIONS_URL:-}" ]; then
  SESSION_ID="$(printf '%s' "$CODESPACES_NOTIFICATIONS_URL" \
    | sed -n 's|.*/sessions/\([^/]*\)/notifications.*|\1|p')"
fi

if [ -z "$SESSION_ID" ]; then
  log "WARN: could not derive session_id from CODESPACES_NOTIFICATIONS_URL"
  log "      ('${CODESPACES_NOTIFICATIONS_URL:-<unset>}'); MCP tools will need"
  log "      it passed explicitly via the AI prompt."
fi

umask 077
/usr/bin/python3 - "$UDID" "$SESSION_ID" > "$INFO_FILE" <<'PY'
import json, sys
udid, session_id = sys.argv[1], sys.argv[2]
print(json.dumps({
    "udid": udid,
    "session_id": session_id,
}, indent=2))
PY

log "simulator ready (UDID=$UDID); manifest at $INFO_FILE"

# ---------- Fork the upload watcher ----------------------------------------
# Detached from this script's process tree (setsid + nohup) so it survives
# after startup.sh returns and the parent inner-script transitions into
# `sleep 2147483647`. The watcher inherits QA_PROMPT and PATH from this env.

WATCHER="$HOME/.qa-agent/watcher.sh"
if [ -z "${QA_PROMPT:-}" ]; then
  log "WARN: QA_PROMPT not set — watcher will not be started; the session will"
  log "      reach RUNNING but no Claude run will fire on upload."
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
  log "upload watcher started (pid=$!, log: \$HOME/.qa-agent/watcher.log)"
fi
