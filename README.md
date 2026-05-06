# Bitrise AI QA Agent

RDE (Remote Development Environment) template that turns a Bitrise codespaces
session into an autonomous iOS QA tester. The CLI in
[`bitrise-io/ai-qa-agent-cli`](https://github.com/bitrise-io/ai-qa-agent-cli)
creates a session from this template, uploads the app under test, and a
headless Claude Code agent inside the VM drives the iOS Simulator using the
[`bitrise-dev-environments`](https://github.com/bitrise-io/bitrise-mcp-dev-environments)
MCP server (screenshots, clicks, scrolls).

## Repository layout

```
template/
├── warmup.sh    # one-time VM provisioning (simulator device, MCP server, watcher)
└── startup.sh   # per-session-start (boot simulator, fork upload watcher)
```

## How a run unfolds

1. **CLI → backend**: `ai-qa-agent-cli session create` calls `CreateSession`
   on bitrise-codespaces with this template, the QA prompt, session inputs,
   and a local iOS app path.
2. **Warmup** (once, on initial creation): `warmup.sh` pre-creates the
   `bitrise-qa-agent` simulator device, registers `bitrise-dev-environments`
   as a Claude MCP server, and writes the upload watcher to
   `~/.qa-agent/watcher.sh`.
3. **Startup** (every boot, including the first): `startup.sh` boots the
   simulator, publishes `/tmp/.qa-agent-info.json` with `{udid, session_id,
   workspace_id}`, and forks the watcher (`setsid nohup bash …`).
4. **Session reaches RUNNING**, CLI uploads the iOS binary to
   `/tmp/<basename>` via the codespaces signed-URL flow.
5. **Watcher** detects the new file under `/tmp`, waits for its size to
   stabilize, then launches Claude in a `qa-agent` tmux session as
   `claude -p --dangerously-skip-permissions "<QA_PROMPT>"`.
6. **Claude** reads `/tmp/.qa-agent-info.json` and `~/.qa-agent/upload-path`,
   installs the app on the simulator (`xcrun simctl install`), launches it,
   and drives the UI via the MCP tools until the prompt is satisfied. Output
   streams into `~/.qa-agent/claude.log`; the run is observable live via
   `tmux attach -t qa-agent`.

This avoids the codespaces backend's `claudeAIAutoStart` path (which would
launch Claude immediately at warmup with `$AI_PROMPT` and burn tokens
polling for the upload from inside its own loop). Claude only starts once
there is something to act on.

## Image and machine requirements

The template is designed to run on a macOS RDE image that already has:

- **Xcode** with at least one iOS Simulator runtime installed (`xcrun simctl`
  must work). The runtime version is selected at warmup; if the requested
  `IOS_VERSION` is missing the warmup hard-fails.
- **Go ≥ 1.25** on `PATH` — the bitrise-dev-environments MCP server is
  invoked via `go run github.com/bitrise-io/bitrise-mcp-dev-environments@latest`.
- **Claude Code CLI** — installed automatically by the codespaces backend's
  `claudeAIWarmupSetup` if Anthropic credentials are present on the session.
- **`tmux`, `python3`, `setsid`** — `tmux` is installed by the same backend
  step; `python3` and `setsid` ship with current macOS images.

`linux` images are not supported — the warmup exits 1.

## Template configuration

When you create the template via the codespaces API / MCP / UI, configure
the following.

### Template variables (set once by the template author)

| Key | Secret | Required | Purpose |
|---|---|---|---|
| `BITRISE_TOKEN` | yes | yes | PAT used by the in-VM MCP server (`bitrise-dev-environments`) to call back to codespaces against this same session |
| `BITRISE_WORKSPACE_ID` | no | yes | Workspace slug for the same MCP server |

> ⚠️ Without these two, `warmup.sh` exits 1 — the in-VM agent has no way to
> drive the session.

### Session inputs (passed by the CLI per run)

All session inputs must have **`expose_as_env_var: true`** so the watcher
sees them.

| Key | Required | Default | Purpose |
|---|---|---|---|
| `QA_PROMPT` | yes | — | Prompt sent to `claude -p`. Should reference `~/.qa-agent/upload-path` (the resolved app path) and `/tmp/.qa-agent-info.json` (`{udid, session_id, workspace_id}`). |
| `DEVICE_TYPE` | no | `iPhone 15` | `xcrun simctl create` device type |
| `IOS_VERSION` | no | highest available | iOS runtime version, e.g. `17.5` |
| `QA_WATCH_DIR` | no | `/tmp` | Directory the watcher polls for the upload |
| `QA_WATCH_TIMEOUT_SEC` | no | `1800` | Seconds to wait for the upload before the watcher exits 1 |
| `QA_WATCH_POLL_SEC` | no | `2` | Watcher poll interval |

### Anthropic credentials

The codespaces backend looks for `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` (template variable or session input) and, if
present, installs Claude Code, writes `~/.claude.json`, and configures
notification hooks. Wire one of them up — typically as a saved input that
the user references on session create.

### Things the CLI must (not) do

- ✅ Pass `--upload <local-app>` so the binary lands at
  `/tmp/<basename(local-app)>`.
- ✅ Pass `--input QA_PROMPT="…"`. The prompt may reference
  `{{REMOTE_PATH}}`; the CLI substitutes that with the resolved upload path
  before submission.
- ❌ **Do not** pass `--ai-prompt`. That sets `req.AiPrompt`, which makes
  the codespaces backend's `claudeAIAutoStart` launch Claude at warmup with
  a different tmux session — racing the watcher and producing two Claude
  runs. The CLI must rely on `QA_PROMPT` only.

## Files written inside the VM

| Path | Owner | Written by | Purpose |
|---|---|---|---|
| `~/.qa-agent-simulator-udid` | session user | warmup | UDID of the QA simulator device (single line) |
| `~/.qa-agent/watcher.sh` | session user | warmup | Background upload watcher script |
| `~/.qa-agent/baseline` | session user | watcher | Snapshot of `QA_WATCH_DIR` at watcher start |
| `~/.qa-agent/upload-path` | session user | watcher | Absolute path of the detected upload, for the prompt to `cat` |
| `~/.qa-agent/watcher.log` | session user | watcher | Watcher run log |
| `~/.qa-agent/claude.log` | session user | tmux pipe-pane | Live capture of the Claude run's stdout |
| `/tmp/.qa-agent-info.json` | session user | startup | `{udid, session_id, workspace_id}` for the prompt |
| `/tmp/.qa_prompt_XXXXXX` | session user | watcher | Temp prompt file passed to `claude -p` |

## Debugging a session

```bash
# attach to the live run
tmux attach -t qa-agent

# watcher progress
tail -f ~/.qa-agent/watcher.log

# claude stdout
tail -f ~/.qa-agent/claude.log

# simulator state
xcrun simctl list devices | grep bitrise-qa-agent
```

## Open items

- The CLI still ships `--ai-prompt`; it must move to `--input
  QA_PROMPT=…` for this template to work as designed.
- The Bundle ID for `simctl launch` isn't exposed yet — the prompt has to
  derive it from the uploaded `.app`'s `Info.plist` or the user supplies it
  inline. Worth a `BUNDLE_ID` session input if this becomes a recurring
  source of friction.
- macOS Sequoia 15.0+ shows a periodic "window picker" consent dialog on
  any process using Screen Recording; the underlying screencapture call
  still succeeds. See bitrise-codespaces backend `script_builder.go`'s
  `tccSetup` doc for context. Out of scope here.
