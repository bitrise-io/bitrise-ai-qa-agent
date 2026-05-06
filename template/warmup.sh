#!/usr/bin/env bash
#
# Bitrise QA Agent — RDE template warmup script.
# Runs ONCE on session VM creation, between `claudeAISetup` (which writes
# ~/.claude.json with credentials) and `claudeAIAutoStart` (which launches
# Claude in a tmux session with $AI_PROMPT). See bitrise-codespaces backend
# script_builder.go:579 for the full ordering.
#
# Performed work:
#   1. Pre-create the iOS simulator device the QA run will use. Booting is
#      left to startup.sh so the simulator is fresh each session.
#   2. Register `bitrise-dev-environments` as an MCP server for Claude Code so
#      the in-VM agent can drive screenshots / clicks / scrolls against this
#      same session.
#
# Required template variables (exposed as env vars at script time):
#   BITRISE_TOKEN          PAT for MCP server auth         (required)
#   BITRISE_WORKSPACE_ID   Workspace slug for MCP server   (required)
#
# Optional session inputs (sane defaults applied):
#   DEVICE_TYPE   e.g. "iPhone 15"  (default: iPhone 15)
#   IOS_VERSION   e.g. "17.5"       (default: highest available iOS runtime)

set -euo pipefail

log() { echo "[qa-agent warmup] $*"; }

DEVICE_TYPE="${DEVICE_TYPE:-iPhone 15}"
IOS_VERSION="${IOS_VERSION:-}"
SIM_NAME="bitrise-qa-agent"
UDID_FILE="$HOME/.qa-agent-simulator-udid"

if [ "$(uname)" != "Darwin" ]; then
  log "ERROR: QA Agent template only supports macOS sessions." >&2
  exit 1
fi

if ! xcrun simctl help >/dev/null 2>&1; then
  log "ERROR: xcrun simctl unavailable — image is missing Xcode." >&2
  exit 1
fi

# ---------- Resolve iOS runtime --------------------------------------------

resolve_runtime() {
  /usr/bin/python3 - "$IOS_VERSION" <<'PY'
import json, subprocess, sys
want = sys.argv[1].strip().lower()
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
ios = [r for r in data["runtimes"] if r.get("isAvailable") and "ios" in r["name"].lower()]
if not ios:
    sys.exit("no available iOS runtimes")
if want:
    for r in ios:
        if want in r["name"].lower():
            print(r["identifier"]); sys.exit()
    sys.exit(f"requested iOS {want} not available — image has: " + ", ".join(r["name"] for r in ios))
ios.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")), reverse=True)
print(ios[0]["identifier"])
PY
}

RUNTIME_ID="$(resolve_runtime)"
log "using runtime: $RUNTIME_ID"

# ---------- Create or reuse the simulator device ---------------------------

EXISTING_UDID="$(xcrun simctl list devices -j | /usr/bin/python3 -c "
import json, sys
name = '$SIM_NAME'
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == name and d.get('isAvailable', True):
            print(d['udid']); break
")"

if [ -n "$EXISTING_UDID" ]; then
  UDID="$EXISTING_UDID"
  log "reusing simulator $SIM_NAME ($UDID)"
else
  log "creating simulator $SIM_NAME ($DEVICE_TYPE / $RUNTIME_ID)"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME_ID")"
fi

printf '%s\n' "$UDID" > "$UDID_FILE"

# ---------- Register bitrise-dev-environments MCP server -------------------
# claudeAISetup has already exported PATH=$HOME/.local/bin:$PATH for this
# script, so `claude` resolves. `claude mcp add --scope user` merges the
# server entry into ~/.claude.json without disturbing the existing trust /
# onboarding fields written by claudeAISetup.

if ! command -v claude >/dev/null 2>&1; then
  log "ERROR: claude CLI not on PATH — Claude credentials must be configured" >&2
  log "       on the session (ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN)." >&2
  exit 1
elif [ -z "${BITRISE_TOKEN:-}" ] || [ -z "${BITRISE_WORKSPACE_ID:-}" ]; then
  log "ERROR: BITRISE_TOKEN / BITRISE_WORKSPACE_ID not set as template variables." >&2
  log "       The in-VM agent cannot drive the session without them." >&2
  exit 1
elif ! command -v go >/dev/null 2>&1; then
  log "ERROR: go not on PATH — image is missing Go ≥ 1.25, required to run the MCP server." >&2
  exit 1
else
  log "registering bitrise-dev-environments MCP server (user scope)"
  claude mcp remove --scope user bitrise-dev-environments >/dev/null 2>&1 || true
  claude mcp add --scope user bitrise-dev-environments \
    -e "BITRISE_TOKEN=${BITRISE_TOKEN}" \
    -e "BITRISE_WORKSPACE_ID=${BITRISE_WORKSPACE_ID}" \
    -- go run github.com/bitrise-io/bitrise-mcp-dev-environments@latest
fi

log "warmup complete (UDID=$UDID)"
