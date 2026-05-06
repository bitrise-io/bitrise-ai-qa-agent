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
# Exact match first (covers full SemVer requests like 26.3.0).
for _candidate in \
  "/Applications/Xcode-${XCODE_VERSION}.app" \
  "/Applications/Xcode_${XCODE_VERSION}.app"; do
  if [ -d "$_candidate" ]; then
    XCODE_PATH="$_candidate"; break
  fi
done
# Glob fallback: a request like "26.3" should resolve to "Xcode-26.3.0.app"
# on Bitrise stack images. Highest patch wins via `sort -V`.
if [ -z "$XCODE_PATH" ]; then
  XCODE_PATH="$(ls -d "/Applications/Xcode-${XCODE_VERSION}".*.app 2>/dev/null | sort -V | tail -n 1)"
fi
if [ -z "$XCODE_PATH" ] || [ ! -d "$XCODE_PATH" ]; then
  log "ERROR: Xcode ${XCODE_VERSION} not found at /Applications/Xcode-${XCODE_VERSION}.app or /Applications/Xcode-${XCODE_VERSION}.*.app" >&2
  log "       installed: $(ls -d /Applications/Xcode*.app 2>/dev/null | xargs -n1 basename | tr '\n' ' ')" >&2
  exit 1
fi
export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
log "using Xcode ${XCODE_VERSION} at $XCODE_PATH"

# ---------- Resolve iOS runtime --------------------------------------------
# `xcrun simctl` is slow on the FIRST invocation under a freshly-set
# DEVELOPER_DIR — CoreSimulator runs first-launch (license, runtime index)
# and it's not unusual for that to take 3–5 minutes on a beta Xcode that
# hasn't been warmed on this image. We split the work and time-stamp each
# phase so the cause of any future hang is obvious from the warmup log.

# Fast path: when IOS_VERSION is given, construct the runtime identifier
# directly. simctl create will validate it on use, so we skip the slow
# `simctl list runtimes -j` entirely.
RUNTIME_ID=""
if [ -n "$IOS_VERSION" ]; then
  _RT_MAJOR_MINOR="$(printf '%s' "$IOS_VERSION" | tr '.' '-' | cut -d'-' -f1,2)"
  RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-${_RT_MAJOR_MINOR}"
  log "using runtime (constructed from IOS_VERSION=$IOS_VERSION): $RUNTIME_ID"
fi

if [ -z "$RUNTIME_ID" ]; then
  # Slow path: enumerate to pick the highest available runtime. The first
  # `xcrun simctl ...` here pays the CoreSimulator first-launch cost.
  log "first xcrun call under DEVELOPER_DIR=$DEVELOPER_DIR (CoreSimulator first-launch can take several minutes on a cold beta Xcode)"
  if ! xcrun simctl help >/dev/null 2>&1; then
    log "ERROR: xcrun simctl unavailable — DEVELOPER_DIR=$DEVELOPER_DIR appears broken." >&2
    exit 1
  fi
  log "enumerating simulator runtimes"
  RUNTIME_ID="$(/usr/bin/python3 - <<'PY'
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
ios = [r for r in data["runtimes"] if r.get("isAvailable") and "ios" in r["name"].lower()]
if not ios:
    sys.exit("no available iOS runtimes")
ios.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")), reverse=True)
print(ios[0]["identifier"])
PY
)"
  log "using runtime (highest available): $RUNTIME_ID"
fi

# ---------- Background the simulator device creation -----------------------
# `simctl create` is the FIRST xcrun call under the freshly-set DEVELOPER_DIR,
# which pays for CoreSimulator's first-launch (license accept, runtime
# catalog load). On a non-default or beta Xcode that wait is minutes — and
# until warmup returns, the codespaces backend cannot transition the session
# to RUNNING.
#
# Move the wait off the critical path: write a tiny helper script that runs
# `simctl create` and parks the resulting UDID + exit code in known files,
# then fork it detached. Warmup proceeds (watcher install + MCP install),
# the session reaches RUNNING quickly, and the watcher (which already waits
# for the upload to land) pays for the simulator wait in parallel — usually
# overlapping with the upload itself. The user only sees a single end-to-end
# wait instead of "warmup wait" + "upload wait" serialized.

mkdir -p "$HOME/.qa-agent"
SIM_CREATE_SCRIPT="$HOME/.qa-agent/create-simulator.sh"
SIM_CREATE_EXIT="$HOME/.qa-agent/sim-create.exit"
SIM_CREATE_LOG="$HOME/.qa-agent/sim-create.log"
rm -f "$SIM_CREATE_EXIT" "$UDID_FILE"
cat > "$SIM_CREATE_SCRIPT" <<CREATEEOF
#!/usr/bin/env bash
# Forked from warmup.sh. Inherits DEVELOPER_DIR + PATH from the parent.
set -u
exec >>"$SIM_CREATE_LOG" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S UTC')] simctl create $SIM_NAME ($DEVICE_TYPE / $RUNTIME_ID) under DEVELOPER_DIR=\$DEVELOPER_DIR"
if UDID="\$(xcrun simctl create '$SIM_NAME' '$DEVICE_TYPE' '$RUNTIME_ID')" && [ -n "\$UDID" ]; then
  printf '%s\n' "\$UDID" > "$UDID_FILE"
  echo 0 > "$SIM_CREATE_EXIT"
  echo "[\$(date '+%Y-%m-%d %H:%M:%S UTC')] OK \$UDID"
else
  RC=\$?
  echo "\$RC" > "$SIM_CREATE_EXIT"
  echo "[\$(date '+%Y-%m-%d %H:%M:%S UTC')] FAILED rc=\$RC"
fi
CREATEEOF
chmod +x "$SIM_CREATE_SCRIPT"

log "forking simctl create in background (CoreSimulator first-launch overlaps with watcher install + MCP install + upload)"
if command -v setsid >/dev/null 2>&1; then
  setsid nohup bash "$SIM_CREATE_SCRIPT" </dev/null >/dev/null 2>&1 &
else
  nohup bash "$SIM_CREATE_SCRIPT" </dev/null >/dev/null 2>&1 &
  disown
fi

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

log "installing wait-for-deps and launcher scripts"
mkdir -p "$HOME/.qa-agent"

# wait-for-deps.sh — Claude calls this as its first action. It blocks until
# the simulator is created + booted and the app upload has stabilised, then
# writes /tmp/.qa-agent-info.json with the resolved udid + session_id.
# Idempotent: running it twice is harmless once everything is ready.
cat > "$HOME/.qa-agent/wait-for-deps.sh" <<'DEPSEOF'
#!/usr/bin/env bash
set -u
mkdir -p "$HOME/.qa-agent"
LOG="$HOME/.qa-agent/wait-for-deps.log"
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S UTC'; }
say() { echo "[$(ts)] [wait-for-deps] $*"; }

WATCH_DIR="${QA_WATCH_DIR:-/tmp/bitrise-ai-qa-agent}"
TIMEOUT_SEC="${QA_WATCH_TIMEOUT_SEC:-1800}"
POLL_SEC="${QA_WATCH_POLL_SEC:-2}"

SIM_UDID_FILE="$HOME/.qa-agent-simulator-udid"
SIM_CREATE_EXIT="$HOME/.qa-agent/sim-create.exit"

# Phase 0: wait for the background simctl create kicked off by warmup.sh.
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))
say "waiting for background simctl create"
while true; do
  if [ -s "$SIM_CREATE_EXIT" ]; then
    SIM_RC="$(tr -d '[:space:]' < "$SIM_CREATE_EXIT")"
    if [ "$SIM_RC" = "0" ] && [ -s "$SIM_UDID_FILE" ]; then
      break
    fi
    say "ERROR: background simctl create failed (rc=$SIM_RC). See $HOME/.qa-agent/sim-create.log"
    exit 1
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    say "ERROR: timed out waiting for sim-create after ${TIMEOUT_SEC}s; tail of sim-create.log:"
    tail -n 20 "$HOME/.qa-agent/sim-create.log" 2>/dev/null || true
    exit 1
  fi
  sleep "$POLL_SEC"
done
SIM_UDID="$(tr -d '[:space:]' < "$SIM_UDID_FILE")"
say "simulator created: $SIM_UDID"

# Kick the boot off NOW (non-blocking) so it warms while we wait for the upload.
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true

# Phase 1: wait for the upload directory to exist and contain at least one file.
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))
say "waiting for upload at $WATCH_DIR"
while true; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    say "ERROR: timed out waiting for $WATCH_DIR after ${TIMEOUT_SEC}s"
    exit 1
  fi
  if [ -d "$WATCH_DIR" ] && [ "$(find "$WATCH_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    say "$WATCH_DIR appeared with $(find "$WATCH_DIR" -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"
    break
  fi
  sleep "$POLL_SEC"
done

# Phase 2: wait for the recursive total size to stabilise across two reads.
PREV=-1
while true; do
  CURR="$(find "$WATCH_DIR" -type f -exec stat -f%z {} + 2>/dev/null | awk 'BEGIN{s=0} {s+=$1} END{print s}')"
  if [ "$CURR" != "0" ] && [ "$CURR" = "$PREV" ]; then
    break
  fi
  PREV="$CURR"
  sleep 1
done
say "upload stabilized at ${CURR} bytes"
printf '%s\n' "$WATCH_DIR" > "$HOME/.qa-agent/upload-path"

# Phase 3: simulator must be fully booted before the install attempt.
say "waiting for simulator $SIM_UDID to finish booting"
if ! xcrun simctl bootstatus "$SIM_UDID" -b; then
  say "WARN: bootstatus failed; attempting one shutdown + reboot"
  xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM_UDID" -b || say "WARN: simulator still not ready"
fi
say "simulator $SIM_UDID booted"

# Phase 4: publish the manifest. session_id comes from the backend-injected
# webhook URL — see bitrise-codespaces session_start.go.
SESSION_ID=""
if [ -n "${CODESPACES_NOTIFICATIONS_URL:-}" ]; then
  SESSION_ID="$(printf '%s' "$CODESPACES_NOTIFICATIONS_URL" \
    | sed -n 's|.*/sessions/\([^/]*\)/notifications.*|\1|p')"
fi
INFO_FILE="/tmp/.qa-agent-info.json"
umask 077
/usr/bin/python3 - "$SIM_UDID" "$SESSION_ID" > "$INFO_FILE" <<'PY'
import json, sys
udid, session_id = sys.argv[1], sys.argv[2]
print(json.dumps({"udid": udid, "session_id": session_id}, indent=2))
PY
say "ready: udid=$SIM_UDID session_id=$SESSION_ID upload=$WATCH_DIR (manifest at $INFO_FILE)"
DEPSEOF
chmod +x "$HOME/.qa-agent/wait-for-deps.sh"

# launcher (still named watcher.sh for backwards-compat with startup.sh) —
# spawns tmux + claude immediately so the codespaces UI's attach probe sees
# the session right away. The dependency waits happen later, as Claude's
# first Bash tool call into wait-for-deps.sh.
cat > "$HOME/.qa-agent/watcher.sh" <<'WATCHEREOF'
#!/usr/bin/env bash
# QA Agent launcher. Forked by startup.sh; runs detached for the session
# lifetime. Inherits QA_PROMPT, BITRISE_*, DEVELOPER_DIR, and PATH from the
# parent startup environment.
#
# Single responsibility: spawn Claude in tmux ASAP. The dependency waits
# (simctl create, upload arrival, simctl bootstatus, info.json write) are
# done by ~/.qa-agent/wait-for-deps.sh, which Claude calls as its first
# Bash tool action. Doing it that way keeps the tmux session attachable
# from the moment startup returns, which the codespaces UI's "open Claude
# session" probe depends on.
set -u

mkdir -p "$HOME/.qa-agent"
LOG="$HOME/.qa-agent/launcher.log"
exec >>"$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S UTC'; }
say() { echo "[$(ts)] $*"; }

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

PROMPT_FILE="$(mktemp /tmp/.qa_prompt_XXXXXX)"
printf '%s' "$QA_PROMPT" > "$PROMPT_FILE"

START_DIR="${SESSION_WORKING_DIR:-$HOME}"
# Interactive yolo: --dangerously-skip-permissions auto-approves every tool
# call so the run never blocks on a permission prompt (no human is attached
# to approve them). We deliberately drop -p / --print so the agent leaves
# its conversation rendered in the tmux pane — the codespaces UI's "open
# Claude session" probe (TerminalCard.tsx) looks for a tmux session named
# `claude-auto`, renames it to `claude-{tabId}` on first attach, and
# probes for that name on every reload. Match the convention so the UI's
# attach-existing-session path works for our run.
# pipe-pane still mirrors the rendered pane to ~/.qa-agent/claude.log for
# offline inspection.
TMUX_SESSION="claude-auto"
tmux new-session -d -s "$TMUX_SESSION" -c "$START_DIR"
tmux pipe-pane -t "$TMUX_SESSION" -o "cat >> $HOME/.qa-agent/claude.log"
tmux send-keys -t "$TMUX_SESSION" "claude --dangerously-skip-permissions \"\$(cat $PROMPT_FILE)\"" Enter
say "claude launched (interactive yolo) in tmux session '$TMUX_SESSION' (prompt at $PROMPT_FILE; codespaces UI will rename to claude-<tabId> on first attach)"

# Mirror claudeAIAutoStart's behaviour: nudge the backend with WORKING so the
# session UI doesn't sit on "idle" until the first hook event fires.
if [ -x "$HOME/.claude/notify.sh" ]; then
  echo '{}' | "$HOME/.claude/notify.sh" SESSION_NOTIFICATION_TYPE_AGENT_WORKING || true
fi
WATCHEREOF
chmod +x "$HOME/.qa-agent/watcher.sh"
log "wait-for-deps and launcher installed in $HOME/.qa-agent/"

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

log "warmup complete; simctl create still running in background (UDID will land in $UDID_FILE)"
