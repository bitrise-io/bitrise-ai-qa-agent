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
#   3. Drop the upload watcher script ($HOME/.qa-agent/watcher.sh) onto disk;
#      startup.sh forks it on every session start.
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

# ---------- Install the upload watcher script ------------------------------
# startup.sh forks this on every session start. It blocks until the CLI's
# `--upload` lands inside QA_WATCH_DIR (default /tmp/bitrise-ai-qa-agent),
# then launches Claude in tmux with $QA_PROMPT. Watching a dedicated
# subdirectory (rather than /tmp at large) means we don't have to filter
# noise from system temp files or the codespaces backend's own /tmp/.claude_*
# state — the directory itself is the signal.

mkdir -p "$HOME/.qa-agent"
cat > "$HOME/.qa-agent/watcher.sh" <<'WATCHEREOF'
#!/usr/bin/env bash
# QA Agent upload watcher. Forked by startup.sh; runs detached for the
# lifetime of the session. Inherits QA_PROMPT, BITRISE_*, and PATH from
# the parent startup environment.
set -u

WATCH_DIR="${QA_WATCH_DIR:-/tmp/bitrise-ai-qa-agent}"
TIMEOUT_SEC="${QA_WATCH_TIMEOUT_SEC:-1800}"   # 30 min default
POLL_SEC="${QA_WATCH_POLL_SEC:-2}"
LOG="$HOME/.qa-agent/watcher.log"

mkdir -p "$HOME/.qa-agent"
exec >>"$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S UTC'; }
say() { echo "[$(ts)] $*"; }

# Recursive total size of all regular files under WATCH_DIR. Returns 0 if
# the directory does not exist yet. Sum rather than count because the CLI's
# tar extraction grows files in place — a stable size means extraction is
# done.
dir_size() {
  if [ ! -d "$WATCH_DIR" ]; then echo 0; return; fi
  find "$WATCH_DIR" -type f -exec stat -f%z {} + 2>/dev/null \
    | awk 'BEGIN{s=0} {s+=$1} END{print s}'
}

dir_file_count() {
  if [ ! -d "$WATCH_DIR" ]; then echo 0; return; fi
  find "$WATCH_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

if [ -z "${QA_PROMPT:-}" ]; then
  say "ERROR: QA_PROMPT not set — nothing to send to Claude. Exiting."
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  say "ERROR: claude CLI not on PATH."
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  say "ERROR: tmux not on PATH (claudeAIWarmupSetup should have installed it)."
  exit 1
fi

say "watcher pid=$$, watching $WATCH_DIR, timeout=${TIMEOUT_SEC}s"

# Phase 1: wait for the directory to exist and contain at least one file.
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))
while true; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    say "ERROR: timed out waiting for $WATCH_DIR after ${TIMEOUT_SEC}s"
    exit 1
  fi
  if [ -d "$WATCH_DIR" ] && [ "$(dir_file_count)" -gt 0 ]; then
    say "$WATCH_DIR appeared with $(dir_file_count) file(s)"
    break
  fi
  sleep "$POLL_SEC"
done

# Phase 2: wait for total size to stabilize — tar extraction on the server
# side writes incrementally, so a too-eager Claude could read a
# half-extracted .ipa. Require two consecutive identical readings.
PREV=-1
while true; do
  CURR="$(dir_size)"
  if [ "$CURR" != "0" ] && [ "$CURR" = "$PREV" ]; then
    break
  fi
  PREV="$CURR"
  sleep 1
done
say "upload stabilized at ${CURR} bytes total across $(dir_file_count) file(s)"

# Persist the resolved upload directory so the prompt / Claude can refer to
# it without re-doing the discovery dance.
printf '%s\n' "$WATCH_DIR" > "$HOME/.qa-agent/upload-path"

PROMPT_FILE="$(mktemp /tmp/.qa_prompt_XXXXXX)"
printf '%s' "$QA_PROMPT" > "$PROMPT_FILE"

START_DIR="${SESSION_WORKING_DIR:-$HOME}"
# Headless yolo: -p prints to stdout and exits when Claude is done; --dangerously-skip-permissions
# auto-approves every tool call so the run never blocks on a permission prompt
# (no human is attached to the session). tmux is kept as a wrapper so the run
# is still observable via SSH `tmux attach -t qa-agent` and so its stdout is
# captured by tmux's pipe-pane log if enabled.
tmux new-session -d -s qa-agent -c "$START_DIR"
tmux pipe-pane -t qa-agent -o "cat >> $HOME/.qa-agent/claude.log"
tmux send-keys -t qa-agent "claude -p --dangerously-skip-permissions \"\$(cat $PROMPT_FILE)\"" Enter
say "claude launched (headless yolo) in tmux session 'qa-agent' (prompt at $PROMPT_FILE)"

# Mirror claudeAIAutoStart's behaviour: nudge the backend with WORKING so the
# session UI doesn't sit on "idle" until the first hook event fires.
if [ -x "$HOME/.claude/notify.sh" ]; then
  echo '{}' | "$HOME/.claude/notify.sh" SESSION_NOTIFICATION_TYPE_AGENT_WORKING || true
fi
WATCHEREOF
chmod +x "$HOME/.qa-agent/watcher.sh"

log "warmup complete (UDID=$UDID); watcher installed at $HOME/.qa-agent/watcher.sh"
