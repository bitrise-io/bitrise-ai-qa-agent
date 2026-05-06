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
#   2. Register `qa-agent` as an MCP server for Claude Code. It runs in-VM
#      via `ai-qa-agent-cli mcp` and exposes qa_screenshot / qa_click /
#      qa_type / qa_scroll / qa_mouse_drag tools that drive the local macOS
#      display directly — no Codespaces-backend round-trip, no PAT.
#   3. Drop the upload watcher script ($HOME/.qa-agent/watcher.sh) onto disk;
#      startup.sh forks it on every session start.
#
# Optional session inputs (sane defaults applied):
#   XCODE_VERSION e.g. "26.3"       (default: 26.3) — selects /Applications/Xcode-<version>.app via DEVELOPER_DIR
#   DEVICE_TYPE   e.g. "iPhone 15"  (default: iPhone 15)
#   IOS_VERSION   e.g. "17.5"       (default: highest available iOS runtime)

set -euo pipefail

log() { echo "[qa-agent warmup] $*"; }

XCODE_VERSION="${XCODE_VERSION:-26.3}"
DEVICE_TYPE="${DEVICE_TYPE:-iPhone 15}"
IOS_VERSION="${IOS_VERSION:-}"
SIM_NAME="bitrise-qa-agent"
UDID_FILE="$HOME/.qa-agent-simulator-udid"

if [ "$(uname)" != "Darwin" ]; then
  log "ERROR: QA Agent template only supports macOS sessions." >&2
  exit 1
fi

# Pre-create the results directory the prompt asks Claude to write into. Bitrise's
# JUnit attachment convention requires the attachment files to sit next to junit.xml,
# so we keep this layout flat (no screenshots/ subdir). The dir is created up front
# even when Claude never runs, so `session collect` always has something non-empty
# to download.
mkdir -p "$HOME/.qa-agent/results"

# ---------- Select Xcode via DEVELOPER_DIR --------------------------------
# Bitrise images ship multiple Xcodes side-by-side under /Applications. We
# prefer DEVELOPER_DIR over `sudo xcode-select -s` so the choice is
# per-process (no sudo, no global state) and survives session restarts.
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
  log "       installed: $(ls -d /Applications/Xcode*.app 2>/dev/null | xargs -n1 basename | tr '\n' ' ')" >&2
  exit 1
fi
export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
log "using Xcode ${XCODE_VERSION} at $XCODE_PATH"

if ! xcrun simctl help >/dev/null 2>&1; then
  log "ERROR: xcrun simctl unavailable — DEVELOPER_DIR=$DEVELOPER_DIR appears broken." >&2
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

# ---------- Pre-accept Claude's bypass-permissions consent dialog ----------
# `claude --dangerously-skip-permissions` shows a one-time interactive
# consent dialog ("Yes, I accept") on first use in a given user-settings
# tree. Setting skipDangerousModePermissionPrompt=true in
# ~/.claude/settings.json suppresses it (Claude Code checks this key across
# user/local/flag/policy settings — see GQ() in the claude binary).
# The codespaces backend's claudeAIHooksSetup runs *after* this script and
# only touches .hooks.* fields via jq, so this top-level key is preserved.

mkdir -p "$HOME/.claude"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS" ] && jq empty "$CLAUDE_SETTINGS" 2>/dev/null; then
  _TMP="$(mktemp)"
  jq '. + {skipDangerousModePermissionPrompt: true}' "$CLAUDE_SETTINGS" > "$_TMP" && mv "$_TMP" "$CLAUDE_SETTINGS"
else
  echo '{"skipDangerousModePermissionPrompt": true}' | jq . > "$CLAUDE_SETTINGS"
fi

# ---------- Install the upload watcher script ------------------------------
# startup.sh forks this on every session start. It blocks until the CLI's
# `--upload` lands inside QA_WATCH_DIR (default /tmp/bitrise-ai-qa-agent),
# then launches Claude in tmux with $QA_PROMPT. Watching a dedicated
# subdirectory (rather than /tmp at large) means we don't have to filter
# noise from system temp files or the codespaces backend's own /tmp/.claude_*
# state — the directory itself is the signal.
#
# We install the watcher BEFORE the MCP-server registration below so that
# any failure in the MCP step still leaves a working watcher on disk —
# startup.sh fails fast with "watcher missing" otherwise, which masks the
# real warmup-stage failure.

log "installing upload watcher script"
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

# Phase 3: ensure the simulator is fully booted before Claude tries to
# install / launch the app. startup.sh kicked off the boot asynchronously
# so the session could reach RUNNING quickly; we pay the wait here, where
# it overlaps with whatever Claude is about to do anyway.
SIM_UDID_FILE="$HOME/.qa-agent-simulator-udid"
if [ -s "$SIM_UDID_FILE" ]; then
  SIM_UDID="$(tr -d '[:space:]' < "$SIM_UDID_FILE")"
  say "waiting for simulator $SIM_UDID to finish booting"
  if ! xcrun simctl bootstatus "$SIM_UDID" -b; then
    say "WARN: bootstatus failed; attempting one shutdown + reboot"
    xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_UDID" -b || say "WARN: simulator still not ready; Claude will see this if it tries to install"
  fi
  say "simulator $SIM_UDID booted"
fi

# Persist the resolved upload directory so the prompt / Claude can refer to
# it without re-doing the discovery dance.
printf '%s\n' "$WATCH_DIR" > "$HOME/.qa-agent/upload-path"

PROMPT_FILE="$(mktemp /tmp/.qa_prompt_XXXXXX)"
printf '%s' "$QA_PROMPT" > "$PROMPT_FILE"

START_DIR="${SESSION_WORKING_DIR:-$HOME}"
# Interactive yolo: --dangerously-skip-permissions auto-approves every tool
# call so the run never blocks on a permission prompt (no human is attached
# to approve them). We deliberately drop -p / --print so the agent leaves
# its conversation rendered in the tmux pane — `tmux attach -t qa-agent`
# from SSH then shows the live transcript instead of an already-exited shell.
# pipe-pane still mirrors the rendered pane to ~/.qa-agent/claude.log for
# offline inspection.
tmux new-session -d -s qa-agent -c "$START_DIR"
tmux pipe-pane -t qa-agent -o "cat >> $HOME/.qa-agent/claude.log"
tmux send-keys -t qa-agent "claude --dangerously-skip-permissions \"\$(cat $PROMPT_FILE)\"" Enter
say "claude launched (interactive yolo) in tmux session 'qa-agent' (prompt at $PROMPT_FILE)"

# Mirror claudeAIAutoStart's behaviour: nudge the backend with WORKING so the
# session UI doesn't sit on "idle" until the first hook event fires.
if [ -x "$HOME/.claude/notify.sh" ]; then
  echo '{}' | "$HOME/.claude/notify.sh" SESSION_NOTIFICATION_TYPE_AGENT_WORKING || true
fi
WATCHEREOF
chmod +x "$HOME/.qa-agent/watcher.sh"
log "watcher installed at $HOME/.qa-agent/watcher.sh"

# ---------- Register qa-agent MCP server -----------------------------------
# claudeAISetup has already exported PATH=$HOME/.local/bin:$PATH for this
# script, so `claude` resolves. `claude mcp add --scope user` merges the
# server entry into ~/.claude.json without disturbing the existing trust /
# onboarding fields written by claudeAISetup.
#
# `ai-qa-agent-cli mcp` runs in-VM and posts CGEvents / invokes
# `screencapture` locally. TCC matches grants against the *responsible*
# process in the attribution chain, and this MCP is launched as a
# descendant of guest-agent (guest-agent → warmup/startup → watcher →
# tmux → claude → mcp), so the kTCCService{Accessibility,PostEvent,ScreenCapture}
# grants tccSetup installs against guest-agent at session warmup cover us.
# See bitrise-codespaces/backend/CLAUDE.md "macOS session VMs — TCC permissions".
#
# We `go install` the binary up front instead of registering `go run …@latest`.
# `go run` would rebuild on every Claude MCP-client start and on a cold module
# cache downloads + compiles ~50MB of deps before serving stdio — Claude's MCP
# client times out and drops the server before the build finishes, surfacing
# as "The MCP tools aren't registered" inside the running agent. `go install`
# pays the cost once during warmup; subsequent registrations are an exec of
# a cached binary.
#
# We also drop any prior `bitrise-dev-environments` registration on the user
# scope. That MCP is still the right choice for non-QA-Agent dev environments,
# but this template no longer uses it (the in-VM server here replaces the
# round-trip through the public Codespaces backend), so a stale entry from an
# older warmup would just clutter the tool list shown to Claude.

if ! command -v claude >/dev/null 2>&1; then
  log "ERROR: claude CLI not on PATH — Claude credentials must be configured" >&2
  log "       on the session (ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN)." >&2
  exit 1
elif ! command -v go >/dev/null 2>&1; then
  log "ERROR: go not on PATH — image is missing Go ≥ 1.25, required to build the MCP server." >&2
  exit 1
elif ! command -v swiftc >/dev/null 2>&1; then
  log "ERROR: swiftc not on PATH — DEVELOPER_DIR=$DEVELOPER_DIR appears broken." >&2
  exit 1
fi

log "go install github.com/bitrise-io/ai-qa-agent-cli@latest -> \$HOME/.local/bin (one-time, may take ~30s on cold cache)"
mkdir -p "$HOME/.local/bin"
INSTALL_LOG="$HOME/.qa-agent/go-install.log"
if ! GOBIN="$HOME/.local/bin" go install github.com/bitrise-io/ai-qa-agent-cli@latest >"$INSTALL_LOG" 2>&1; then
  log "ERROR: go install failed; tail of $INSTALL_LOG:" >&2
  tail -n 30 "$INSTALL_LOG" >&2 || true
  exit 1
fi
QA_AGENT_BIN="$HOME/.local/bin/ai-qa-agent-cli"
if [ ! -x "$QA_AGENT_BIN" ]; then
  log "ERROR: go install completed without errors but $QA_AGENT_BIN is missing or not executable" >&2
  log "       contents of \$HOME/.local/bin:" >&2
  ls -la "$HOME/.local/bin" >&2 || true
  exit 1
fi
log "go install OK: $QA_AGENT_BIN ($(${QA_AGENT_BIN} --help 2>&1 | head -n 1 || echo 'help failed'))"

log "registering qa-agent MCP server (user scope) -> $QA_AGENT_BIN mcp"
claude mcp remove --scope user bitrise-dev-environments >/dev/null 2>&1 || true
claude mcp remove --scope user qa-agent >/dev/null 2>&1 || true
claude mcp add --scope user qa-agent -- "$QA_AGENT_BIN" mcp

log "warmup complete (UDID=$UDID)"
