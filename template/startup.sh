#!/usr/bin/env bash
#
# Bitrise QA Agent — RDE template startup script.
# Runs on EVERY session start (initial provisioning + every restart of an
# archived session). Sits between `claudeAISetup` (refresh creds) and the
# backend's terminal sleep loop. Note: claudeAIAutoStart only runs in the
# warmup phase, so this script does not (re)launch Claude itself.
#
# Performed work:
#   1. Boot the simulator created by warmup.sh.
#   2. Wait for it to be fully ready.
#   3. Publish a known-path manifest the AI prompt can read to learn the
#      simulator UDID and the session_id (needed by bitrise-dev-environments
#      MCP tools to target *this* session).
#
# The AI prompt should look something like:
#
#   You are a QA tester. Wait until /tmp/<file> exists.
#   When it does:
#     - Read /tmp/.qa-agent-info.json for { udid, session_id, workspace_id }.
#     - Install: xcrun simctl install <udid> /tmp/<file>
#     - Launch the app, then drive it with the bitrise-dev-environments MCP
#       tools (screenshot, click, scroll) against session_id to verify <task>.
#     - Report results, then exit.

set -euo pipefail

log() { echo "[qa-agent startup] $*"; }

UDID_FILE="$HOME/.qa-agent-simulator-udid"
INFO_FILE="/tmp/.qa-agent-info.json"

if [ "$(uname)" != "Darwin" ]; then
  log "ERROR: QA Agent template only supports macOS sessions." >&2
  exit 1
fi

if [ ! -s "$UDID_FILE" ]; then
  log "ERROR: $UDID_FILE missing — warmup.sh did not run successfully." >&2
  exit 1
fi
UDID="$(tr -d '[:space:]' < "$UDID_FILE")"

# ---------- Boot the simulator (idempotent) --------------------------------

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
  Shutdown)
    log "booting simulator $UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" -b
    ;;
  NotFound)
    log "ERROR: simulator $UDID not registered with simctl — was the device deleted?" >&2
    exit 1
    ;;
  *)
    # Booting / Shutting Down — wait it out.
    log "simulator in transient state '$state', waiting for it to settle"
    xcrun simctl bootstatus "$UDID" -b || {
      log "fallback: shutdown + reboot"
      xcrun simctl shutdown "$UDID" 2>/dev/null || true
      xcrun simctl boot "$UDID"
      xcrun simctl bootstatus "$UDID" -b
    }
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
/usr/bin/python3 - "$UDID" "$SESSION_ID" "${BITRISE_WORKSPACE_ID:-}" > "$INFO_FILE" <<'PY'
import json, sys
udid, session_id, workspace_id = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "udid": udid,
    "session_id": session_id,
    "workspace_id": workspace_id,
}, indent=2))
PY

log "simulator ready (UDID=$UDID); manifest at $INFO_FILE"
