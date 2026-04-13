# ClaudeNotch — Full Documentation

A native macOS SwiftUI app that renders a Dynamic-Island-style widget flush against the MacBook notch, showing live state of every Claude Code session on the machine: status, current tool, todos, subagents, token usage, and blocking permission prompts.

- **Platform:** macOS 13+
- **Language:** Swift 5.9, SwiftUI + AppKit
- **Build:** SwiftPM only (no Xcode project), two executable targets
- **Bundle ID:** `com.ahmed.claudenotch`
- **Version:** 0.1.0
- **Source tree:** ~4,000 lines across 13 Swift files

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [Repository layout](#2-repository-layout)
3. [Build & run](#3-build--run)
4. [High-level architecture](#4-high-level-architecture)
5. [Data flow — hooks, sockets, UI](#5-data-flow--hooks-sockets-ui)
6. [File-by-file reference](#6-file-by-file-reference)
7. [External integrations](#7-external-integrations)
8. [Smart UI behaviours](#8-smart-ui-behaviours)
9. [State machines & data model](#9-state-machines--data-model)
10. [Permission request flow (blocking hook)](#10-permission-request-flow-blocking-hook)
11. [Usage / rate-limit fetching](#11-usage--rate-limit-fetching)
12. [Sound system](#12-sound-system)
13. [Install, uninstall, launch-at-login](#13-install-uninstall-launch-at-login)
14. [Development conventions](#14-development-conventions)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. What it does

ClaudeNotch watches every Claude Code session on the machine in real-time and renders a floating widget pinned to the MacBook notch. There are two visual states, mimicking Apple's Dynamic Island:

- **Collapsed (~300 pt pill):** pixel-art avatars for each active session + a usage badge (`✦ 5h 23%`).
- **Expanded (~560 pt dashboard, adaptive height):** full dashboard per session — status, tool-in-flight, todos, subagents, conversation card, and dynamic permission buttons.

Auto-expand is triggered by `PermissionRequest` and `Stop` hooks; auto-collapse is driven by a 10 s timer, app-focus changes, or manual click.

Beyond display, the app is **interactive**: when Claude Code asks the user for permission to run a tool, ClaudeNotch can answer the prompt for them (Deny / Allow Once / Always Allow / Bypass) without the user touching the terminal, because the bridge helper blocks on a Unix socket until the UI sends a decision.

---

## 2. Repository layout

```
ClaudeNotch/
├── Package.swift                  # SwiftPM manifest — 2 executable targets
├── build.sh                       # swift build + assemble .app + ad-hoc codesign
├── run.sh                         # build + pkill old + open .app
├── Resources/
│   ├── Info.plist                 # LSUIElement=true (menu-bar only app)
│   └── Sounds/
│       ├── openpeon.json          # sound-pack manifest (Clean Chimes from Peon)
│       └── sounds/                # CC_Start.wav, CC_Complete.wav, …
├── Sources/
│   ├── ClaudeNotch/               # main GUI app (AppDelegate, SwiftUI, …)
│   │   ├── AppDelegate.swift
│   │   ├── ClaudeNotchApp.swift
│   │   ├── ClaudeWatcher.swift    # session discovery + state (~1200 LOC)
│   │   ├── FocusMonitor.swift
│   │   ├── HookInstaller.swift    # writes ~/.claude/settings.json
│   │   ├── HookServer.swift       # UDS listener for hook events
│   │   ├── KeychainReader.swift   # reads Claude Code OAuth tokens
│   │   ├── Logger.swift
│   │   ├── NotchPanel.swift       # borderless NSPanel flush to top
│   │   ├── NotchView.swift        # the whole SwiftUI tree (~1200 LOC)
│   │   ├── SessionLauncher.swift  # focus terminal tab by TTY
│   │   ├── SoundManager.swift
│   │   └── UsageFetcher.swift
│   └── ClaudeNotchBridge/
│       └── main.swift             # tiny hook helper — stdin → UDS
├── ClaudeNotch.app/               # build output (gitignored via *.app)
└── reference/
    └── claude-code-source/        # local Claude Code source snapshot (gitignored)
```

`.claude/`, `.build/`, `*.app`, `*.log`, `reference/` are all gitignored.

---

## 3. Build & run

```bash
./build.sh      # swift build -c release → assemble ClaudeNotch.app → codesign -
./run.sh        # build + pkill -x ClaudeNotch + open ClaudeNotch.app
```

### What `build.sh` does

1. `swift build -c release --product ClaudeNotch`
2. `swift build -c release --product ClaudeNotchBridge`
3. Create fresh `ClaudeNotch.app/Contents/{MacOS,Resources,Helpers}`
4. Copy `ClaudeNotch` → `Contents/MacOS/ClaudeNotch`
5. Copy `ClaudeNotchBridge` → `Contents/Helpers/claudenotch-bridge`
6. Copy `Resources/Info.plist` and `Resources/Sounds/`
7. Ad-hoc codesign (`codesign --force --deep --sign -`) so Gatekeeper accepts it locally

### Important rules

- **Never `swift run` the app.** `HookInstaller.bridgePath` resolves the helper relative to `Bundle.main.executablePath` (`…/Contents/Helpers/claudenotch-bridge`). Running outside the `.app` bundle will install hook entries that point to a non-existent path.
- **Always `pkill -x ClaudeNotch` before rebuilding.** The Unix socket at `~/Library/Application Support/ClaudeNotch/bridge.sock` is held exclusively by the running process. `run.sh` does this for you.
- No test suite, no linter, no CI.

---

## 4. High-level architecture

Two SwiftPM executable targets:

### `ClaudeNotch` — the GUI app
- `LSUIElement=true` (no dock icon, menu-bar only).
- On launch, `AppDelegate`:
  1. Starts `FocusMonitor`, `ClaudeWatcher`, `UsageFetcher`.
  2. Installs the SwiftUI `NotchView` inside a borderless `NotchPanel`.
  3. Starts `HookServer` (Unix socket listener).
  4. Calls `HookInstaller.install()` + `installStatusLine()` to merge hook entries into `~/.claude/settings.json`.
  5. Creates the menu-bar status item (`◆` glyph).

### `ClaudeNotchBridge` — the hook helper
A ~140-line CLI binary installed at `ClaudeNotch.app/Contents/Helpers/claudenotch-bridge`. Claude Code hooks `exec` it — one process per hook firing. It:

1. Drains stdin (the JSON hook payload).
2. Discovers its own TTY by walking up the process tree with `ps -o tty=,ppid=` (same approach as Vibe Island).
3. Injects `_bridge_tty` into the JSON payload.
4. Connects to the Unix socket and sends the payload + `\n`.
5. For non-`PermissionRequest`: `shutdown(SHUT_WR)` and exit 0 — fire-and-forget.
6. For `PermissionRequest`: `shutdown(SHUT_WR)` (so the server sees EOF) but keeps the read side open, then blocks on `recv()` until the GUI writes the decision back, and writes that decision to stdout so Claude Code can act on it.
7. **If the GUI is not running** (socket doesn't exist or `connect()` fails), it exits 0 silently. Hooks must never block Claude Code.

Why a separate binary and not a daemon in-process? Because Claude Code invokes hooks as child processes — the bridge has to be a CLI-style executable that reads stdin, not a long-lived server.

---

## 5. Data flow — hooks, sockets, UI

```
Claude Code CLI
      │
      │ fires a hook from ~/.claude/settings.json
      ▼
claudenotch-bridge  (child process, stdin = JSON event)
      │
      │ write one \n-framed JSON line
      ▼
Unix domain socket: ~/Library/Application Support/ClaudeNotch/bridge.sock
      │
      ▼
HookServer (background accept loop)
      │
      │ parse → HookServer.Event → DispatchQueue.main.async
      ▼
ClaudeWatcher.applyHookEvent(event)           SoundManager.playForEvent(...)
      │
      │ mutates @Published sessions, autoExpandCounter, …
      ▼
SwiftUI NotchView re-renders

        ── PermissionRequest only ───────────────────────────
        The bridge stays blocked on recv(). pendingApprovals[sid] = clientFd.
        User clicks a button → AppDelegate.resolvePermission(sid, decision)
        → HookServer.resolvePermission writes the decision JSON back on clientFd
        → the bridge writes it to stdout, Claude Code reads it and proceeds.
```

Sub-100 ms latency is the design goal for real-time status; the 2 s disk poll only fills in sessions that started before `HookInstaller` ran or that never triggered a hook.

---

## 6. File-by-file reference

### `ClaudeNotchApp.swift` (14 LOC)
Trivial `@main` entry point; sets `AppDelegate` and calls `NSApplication.shared.run()`.

### `AppDelegate.swift` (199 LOC)
Composition root. Wires everything on `applicationDidFinishLaunching`:

- `signal(SIGPIPE, SIG_IGN)` — writing to a closed bridge socket must not crash the app.
- Spawns `ClaudeWatcher`, `FocusMonitor`, `UsageFetcher`, `NotchPanel`, `HookServer`.
- `HookServer` handler routes every event to `ClaudeWatcher.applyHookEvent` and `SoundManager.playForEvent`. On `PostToolUse`/`Stop` it calls `UsageFetcher.refreshIfStale(maxAge: 30)` because every finished turn nudges Anthropic-side counters. On `Stop` it clears `pendingApprovals[sid]` to dismiss the permission card if the user approved from the terminal.
- Calls `HookInstaller.install()` and `installStatusLine()` idempotently.
- Builds the menu-bar item (`◆`) with: Hide/Show Notch, Uninstall Claude Code Hooks, Launch at Login (via `SMAppService.mainApp`), Quit.
- Exposes `resolvePermission(sessionId:decision:)` called from `NotchView`'s buttons.

### `ClaudeWatcher.swift` (~1200 LOC) — *the single source of UI truth*

**Types defined here:**

- `SessionStatus` enum — `working`, `compacting`, `awaitingApproval`, `interrupted`, `idle` (+ `isBusy`).
- `UsageStats` — `contextTokens`, `outputTokens`.
- `DiffPreview` — Edit/Write diff preview shown in permission cards (old/new strings capped at ~500 chars, full content at ~1000).
- `CurrentTool` — name, detail, description, diffPreview, `hasAlwaysAllow` (populated from `permission_suggestions` non-emptiness).
- `Subagent` — id, agentType, description, startedAt, status, currentTool.
- `TodoItem` — id (content hash), content, status.
- `ClaudeSession` — the full published struct with `with(status:)`, `with(currentTool:)`, etc. `with(...)` methods for immutable updates.

**Responsibilities:**

- `@MainActor`, `ObservableObject`, `@Published private(set) var sessions: [ClaudeSession]`.
- 2 s polling loop over `~/.claude/projects/*/` for `.jsonl` files (filters `agent-*` subagent files); 48 h active window, UI then splits into active (<20 min or hook-alive) vs. inactive (compact row).
- `autoExpandCounter: Int` + `autoExpandFocusedSession: String?` — a monotonically increasing counter so SwiftUI's `.onChange` fires even when the same session triggers twice.
- Caches parsed `UsageStats` and TodoItem lists per file URL, keyed by mtime.
- `hookAliveSessions: [String: String]` — SessionStart adds, SessionEnd removes, any event marks alive.
- `sessionSubagents: [String: [Subagent]]`, `sessionTodos: [String: [TodoItem]]`, `taskCounter`, `pendingAgentType`/`pendingAgentDesc`.
- `hookStatus: [String: (status, at)]` — status overrides from hook events with a **90 s TTL** so a stuck `awaitingApproval` recovers if the approving hook is lost.
- `approvalIdleThreshold = 2.5 s` — if a `tool_use` is the last assistant entry and the file has been idle longer than this, the session is reclassified from `working` to `awaitingApproval`.
- `applyHookEvent(_:)` is the big switch that implements all state transitions.

### `HookInstaller.swift` (249 LOC)

Merges ClaudeNotch entries into `~/.claude/settings.json` with timestamped backups, preserving every non-ClaudeNotch entry (so Vibe Island, `osascript` notifications, etc. keep working in parallel). Also installs a StatusLine shim that dumps `rate_limits` JSON to `/tmp/claudenotch-rl.json` on every assistant message — zero API calls.

**Events subscribed (11 total):**

| Event              | Matcher | Timeout |
|--------------------|---------|---------|
| UserPromptSubmit   | no      | —       |
| PreToolUse         | `*`     | —       |
| PostToolUse        | `*`     | —       |
| PermissionRequest  | `*`     | 86400 s |
| Notification       | `*`     | —       |
| Stop               | no      | —       |
| SessionStart       | no      | —       |
| SessionEnd         | no      | —       |
| SubagentStart      | no      | —       |
| SubagentStop       | no      | —       |
| PreCompact         | no      | —       |

`PermissionRequest` is the only one with a matcher + 24 h timeout because the bridge blocks for the user's decision.

**Bridge path resolution** (`HookInstaller.bridgePath`): walks up from `Bundle.main.executablePath` to find `Contents/Helpers/claudenotch-bridge`. Dev fallback: `/Users/ahmed/ClaudeNotch/ClaudeNotch.app/Contents/Helpers/claudenotch-bridge`. **This is why you cannot `swift run` the app.**

### `HookServer.swift` (344 LOC)

- `@MainActor` wrapper around a Unix-domain stream socket at `~/Library/Application Support/ClaudeNotch/bridge.sock`.
- Socket is `chmod 0600` so only the current user can connect.
- Accept loop runs on a background `DispatchQueue.global(qos: .userInitiated)`; parsed events are dispatched back to the main actor via `DispatchQueue.main.async`.
- `Event` struct: `hookEventName`, `sessionId`, `cwd`, `transcriptPath`, `toolName`, `toolInput`, `permissionSuggestions`, `raw`.
- `pendingApprovals: [String: Int32]` — open client fds for blocking `PermissionRequest` keyed by session ID. `SO_NOSIGPIPE` is set per-fd as belt-and-braces on top of the global `SIGPIPE` ignore.
- `sessionTTY: [String: String]` — extracted from `_bridge_tty` in the payload. Used by `SessionLauncher` to focus the right terminal tab.
- `resolvePermission(sessionId:decision:)` builds the response JSON and writes it back on the stored fd:
  - `"bypass"` → top-level `{"decision": "approve"}`
  - `"deny"` → `{"behavior": "deny", "message": "Denied via ClaudeNotch"}`
  - `"always_allow"` → `{"behavior": "allow", "remember": true}`
  - `"allow"` → `{"behavior": "allow"}`
  - All except bypass are wrapped in `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": ...}}`
- `clearPendingApproval(sessionId:)` — called from `Stop` so the permission card disappears if the user approved from the terminal and the bridge is already gone.

### `NotchPanel.swift` (61 LOC)

Borderless `NSPanel` with `.nonactivatingPanel` so it never steals focus. Constants:

- `panelWidth = 600 pt`
- `visibleContentHeight = 380 pt`
- Plus `NSScreen.main?.safeAreaInsets.top` (the physical notch height) added at the top and hidden behind the cutout.

### `NotchView.swift` (~1200 LOC)

The whole SwiftUI tree. Two major states (collapsed pill, expanded dashboard) plus per-session rows, conversation cards, dynamic permission buttons, todos, subagent cards. Observes:

- `ClaudeWatcher.sessions`, `.autoExpandCounter`, `.autoExpandFocusedSession`
- `UsageFetcher` for the header usage badge
- `FocusMonitor.appSwitchCounter`, `.isTerminalFocused`

Owns the smart-suppression logic (see §8). The permission card reads `CurrentTool.hasAlwaysAllow` to decide 3-button vs. 4-button layouts.

### `SoundManager.swift` (104 LOC)

Bundled Clean Chimes pack (via `openpeon.json`). 7 sound categories + spam detection:

| Category          | File            | Trigger                                                            |
|-------------------|-----------------|--------------------------------------------------------------------|
| `sessionStart`    | CC_Start        | `SessionStart`                                                     |
| `taskAcknowledge` | CC_Acknowledge  | `UserPromptSubmit` (unless spam)                                   |
| `taskComplete`    | CC_Complete     | `Stop`                                                             |
| `taskError`       | CC_Error        | Tool failure (called from `applyHookEvent`)                        |
| `inputRequired`   | CC_InputNeeded  | `PermissionRequest`                                                |
| `resourceLimit`   | CC_Warning      | `PreCompact`                                                       |
| `userSpam`        | CC_Spam         | ≥3 `UserPromptSubmit` in 10 s (then the window resets)             |

Volume fixed at 0.6. Falls back to the repo path (`/Users/ahmed/ClaudeNotch/Resources/Sounds/sounds/...`) if the bundled copy is missing (dev convenience).

### `FocusMonitor.swift` (72 LOC)

`NSWorkspace.didActivateApplicationNotification` → updates `isTerminalFocused` by matching bundle IDs:

```
com.apple.Terminal, com.googlecode.iterm2, net.kovidgoyal.kitty,
com.github.wez.wezterm, dev.warp.Warp-Stable, com.mitchellh.ghostty,
io.alacritty, org.alacritty, com.microsoft.VSCode,
com.todesktop.230313mzl4w4u92   // Cursor
```

Increments `appSwitchCounter` when the user switches *away from* a terminal to something else — `NotchView` observes this to collapse manual expansions.

### `SessionLauncher.swift` (253 LOC)

Click-to-focus for session rows. Strategy cascade:

1. **Hook TTY** — `HookServer.sessionTTY[sid]` (most precise, injected by the bridge).
2. **Process TTY** — walk live processes, find a `claude` process whose cwd matches the session, grab its TTY.
3. **Fallback** — open a fresh Terminal window at the project's cwd via AppleScript.

TTY-to-tab focus uses AppleScript window-title matching. Requires `NSAppleEventsUsageDescription` in `Info.plist` — macOS prompts the user once to allow the automation.

### `UsageFetcher.swift` (242 LOC)

Two-tier usage data source with `@Published` output consumed by `NotchView`:

- **Primary** (zero API cost): reads `/tmp/claudenotch-rl.json` every 5 s. The file is written by the StatusLine shim `HookInstaller` installs.
- **Fallback**: `GET https://api.anthropic.com/api/oauth/usage` every ~10 min, authenticated with the Claude Code OAuth token from `KeychainReader`. `Utilization` struct mirrors `reference/claude-code-source/src/services/api/usage.ts`.
- `refreshIfStale(maxAge:)` is called from the hook handler on `PostToolUse`/`Stop` to pull fresh numbers right after a turn ends.

### `KeychainReader.swift` (65 LOC)

Reads `Claude Code-credentials` from the login keychain. First access triggers the macOS keychain prompt; subsequent reads are silent. Decodes:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1775399088269,
    "scopes": ["..."],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_5x"
  }
}
```

`OAuthTokens.isValid` checks `expiresAt > now + 60 s`.

### `Logger.swift` (29 LOC)
`CNLog.log(...)` — thin wrapper around `NSLog` with a `ClaudeNotch: ` prefix.

### `ClaudeNotchBridge/main.swift` (~142 LOC)
See §4 above. The interesting part is `discoverTTY()` — it walks up to 10 levels up the process tree with `ps -o tty=,ppid= -p <pid>` until it finds a real TTY (not `??`). This is how the GUI learns which terminal tab a hook came from.

---

## 7. External integrations

| System                          | How it's used                                                                 |
|---------------------------------|-------------------------------------------------------------------------------|
| `~/.claude/settings.json`       | `HookInstaller` merges hook entries + StatusLine shim                         |
| `~/.claude/projects/*/`         | `ClaudeWatcher` polls `.jsonl` transcripts every 2 s                          |
| `/tmp/claudenotch-rl.json`      | `UsageFetcher` primary data source (written by StatusLine shim)               |
| Unix socket `bridge.sock`       | `HookServer` ↔ `ClaudeNotchBridge`                                            |
| `api.anthropic.com/api/oauth/usage` | `UsageFetcher` fallback (every ~10 min)                                   |
| Login keychain `Claude Code-credentials` | `KeychainReader` reads the OAuth token                               |
| AppleScript → Terminal/iTerm    | `SessionLauncher` focuses tabs; declared via `NSAppleEventsUsageDescription`  |
| `SMAppService.mainApp`          | Launch-at-login toggle from the menu bar                                      |

---

## 8. Smart UI behaviours

These are subtle and easy to break — verify all four when touching `NotchView` or `ClaudeWatcher`.

1. **`PermissionRequest` always expands the panel** — even if a terminal is frontmost. The user needs to see the diff and click a button.
2. **`Done` / `Stop` expansion is suppressed** when the frontmost app is the terminal tab belonging to the *same* session (matched by TTY or window title). The user is already looking at the output; no need to pop a notification card over it.
3. **Auto-expanded popups are NOT collapsed by app-switching.** Only the internal 10 s "Done" timer collapses them.
4. **Manually-hovered expansions ARE collapsed by app-switching** — a user drag-peek vanishes when they alt-tab away.

Plus:

- **Active vs. inactive rows:** `<20 min` since last modification OR hook-alive → full detailed row. Otherwise → compact single-line row.
- **48 h window:** anything older than 48 h is dropped from the list entirely.

---

## 9. State machines & data model

### `SessionStatus`

```
          UserPromptSubmit / tool activity
                    │
                    ▼
    ┌──────────▶ working ◀─────────── PostToolUse
    │               │
    │               │ PreCompact
    │               ▼
    │           compacting
    │               │
    │               │ PostCompact
    │               ▼
    │           working ──── tool_use + idle > 2.5 s ──▶ awaitingApproval
    │                                                             │
    │◀── PermissionRequest decision or PostToolUse ───────────────┘
    │
    │   [Request interrupted]
    ├──────▶ interrupted
    │
    │   Stop
    └──────▶ idle
```

Hook-driven overrides in `hookStatus` expire after **90 s** so a lost hook can't permanently freeze the UI — the parseTail-derived status takes over.

### `CurrentTool`
Populated by `PreToolUse`, cleared by `PostToolUse`. `hasAlwaysAllow = !permission_suggestions.isEmpty`.

### `ClaudeSession`
Immutable struct with `.with(status:)`, `.with(currentTool:)`, `.with(subagents:)`, `.with(todos:)` copy-helpers so applying a hook event produces a new value (SwiftUI-friendly).

### Session discovery (dual source)
- **File-based:** 48 h window, `.jsonl` files in `~/.claude/projects/*/` (skipping `agent-*` subagent transcripts).
- **Hook-based:** `hookAliveSessions` — `SessionStart` adds, `SessionEnd` removes; any event marks alive. A session can be hook-alive even if its file hasn't been touched in a while (e.g. waiting for user input).

---

## 10. Permission request flow (blocking hook)

The most intricate flow in the app. Ordinary hooks are fire-and-forget; `PermissionRequest` is different because Claude Code reads the bridge's stdout to learn the decision.

```
1. Claude Code is about to run a tool (e.g. Bash).
2. It fires PermissionRequest with a 24 h timeout (per HookInstaller config).
3. Claude Code execs  claudenotch-bridge  with JSON on stdin.
4. Bridge connects to bridge.sock, writes the payload + "\n".
5. Bridge shuts down the write side (SHUT_WR) — server sees EOF.
6. Bridge blocks on recv() on the same socket.
7. Server side:
     HookServer parses the event, stashes clientFd in pendingApprovals[sid],
     fires the handler which calls ClaudeWatcher.applyHookEvent →
     ClaudeWatcher flips status to .awaitingApproval, bumps autoExpandCounter →
     NotchView re-renders, shows the permission card with dynamic buttons.
8. User clicks a button in NotchView.
9. NotchView → AppDelegate.resolvePermission(sid, "allow") → HookServer.resolvePermission
10. HookServer serializes the decision JSON (see §6 HookServer for the shapes)
    and send()s it back on clientFd, then close()s the fd.
11. Bridge's blocked recv() returns; it writes the decision to stdout; exits 0.
12. Claude Code reads stdout, proceeds with (or skips) the tool call.
13. A PostToolUse event eventually arrives; ClaudeWatcher clears the in-flight tool.
14. If the user approved from the terminal instead of from the notch, Stop arrives
    while the fd is still in pendingApprovals. AppDelegate.Stop handler calls
    HookServer.clearPendingApproval(sid) to dismiss the stale card.
```

**Dynamic permission buttons:**

| `permission_suggestions` | Buttons rendered                                       |
|--------------------------|--------------------------------------------------------|
| Non-empty                | Deny · Allow Once · Always Allow · Bypass              |
| Empty                    | Deny · Allow Once · Bypass                             |

When editing this, keep the mapping consistent across three places:

- `HookServer.parseEvent` — forwards `permission_suggestions` verbatim.
- `ClaudeWatcher.applyHookEvent` — derives `CurrentTool.hasAlwaysAllow`.
- `NotchView` — renders the 3- or 4-button card.

---

## 11. Usage / rate-limit fetching

Two-tier design, primary first:

### Primary — StatusLine shim (zero API calls)
`HookInstaller.installStatusLine()` appends a one-liner to the user's existing `statusLine.command` in `~/.claude/settings.json`. That one-liner saves `.rate_limits` from Claude Code's StatusLine JSON to `/tmp/claudenotch-rl.json` on every assistant message. `UsageFetcher` polls this file every 5 s. **Free data, real-time.**

### Fallback — Anthropic private API
`GET https://api.anthropic.com/api/oauth/usage` every ~10 min, authenticated with the OAuth access token read via `KeychainReader`. Response shape mirrors `reference/claude-code-source/src/services/api/usage.ts`:

```swift
Utilization {
    five_hour: Limit?         // { utilization, resets_at }
    seven_day: Limit?
    seven_day_opus: Limit?
    seven_day_sonnet: Limit?
    extra_usage: ExtraUsage?  // { is_enabled, monthly_limit, used_credits, utilization }
}
```

`refreshIfStale(maxAge: 30)` is called from the hook handler on `PostToolUse`/`Stop` so the badge updates right after a turn ends.

---

## 12. Sound system

Clean Chimes pack from Peon, stored at `Resources/Sounds/sounds/*.wav`. Playback:

- `AVAudioPlayer` at volume 0.6.
- Spam detector: ≥3 `UserPromptSubmit` in 10 s plays `CC_Spam` once and resets the window.
- `toggle()` / `isMuted` support a menu-bar mute toggle (hook in `AppDelegate` if you expose a menu item for it).
- Bundle lookup first, then dev-path fallback `/Users/ahmed/ClaudeNotch/Resources/Sounds/sounds/<name>.wav`.

---

## 13. Install, uninstall, launch-at-login

### Install
`HookInstaller.install()` runs on every launch and is idempotent. It:

1. Reads `~/.claude/settings.json` (creating `{}` if absent).
2. Walks each of the 11 events, adds a hook entry pointing at `claudenotch-bridge` if one isn't already there.
3. Returns `(added, skipped)` counts — `AppDelegate` logs it.
4. Writes a timestamped backup to `~/.claude/settings.json.bak.<ts>` only if mutations were made.

`installStatusLine()` does the same for the StatusLine shim.

### Uninstall
Menu bar → *Uninstall Claude Code Hooks*. `HookInstaller.uninstall()` walks each event, removes any hook entry whose command contains `claudenotch-bridge`, writes a backup, shows an `NSAlert` with the result.

### Launch at login
Menu bar → *Launch at Login*. Uses `SMAppService.mainApp.register()` / `.unregister()`. The menu item's checkmark mirrors `SMAppService.mainApp.status == .enabled`.

---

## 14. Development conventions

- **Comments & docstrings in English.** User-facing strings can be multilingual.
- **Commit messages:** no emojis, no "Generated with Claude Code" footer, conventional-commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`).
- **Shell commands:** prefer single-line `&&` chains; avoid backslash line-continuations in commit messages or scripts.
- **`NotchView` and `ClaudeWatcher` are large by design.** Prefer editing in place over splintering them unless there's a clear reason.
- This is a fast-moving personal project; the target user (Ahmed) frequently sends Vibe Island screenshots as UI specs, so changes land iteratively.

---

## 15. Troubleshooting

| Symptom                                               | Likely cause & fix                                                                               |
|-------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| App launches but no sessions show                     | Check `~/.claude/projects/` exists; check `NSLog` in Console.app for `ClaudeNotch:` lines.        |
| Hooks don't trigger anything                          | `~/.claude/settings.json` missing entries, or bridge path stale. Rebuild and `HookInstaller` will re-add. |
| `socket() failed` on startup                          | Previous instance still holds `bridge.sock`. `pkill -x ClaudeNotch` and relaunch.                 |
| Permission card never dismisses                       | Lost `PostToolUse`. The 90 s `hookStatusTTL` in `ClaudeWatcher` recovers automatically.           |
| Usage badge shows `—`                                 | `/tmp/claudenotch-rl.json` missing AND keychain prompt denied. Re-approve keychain access.        |
| Click-to-focus opens a new terminal instead of focusing | No TTY known for that session (hooks weren't installed when it started). Expected behaviour.     |
| Build succeeds but app crashes on launch              | Running outside `.app` bundle. Always `./build.sh && open ClaudeNotch.app`, never `swift run`.    |
| Panel appears but not flush with notch                | `NSScreen.main?.safeAreaInsets.top` is 0 on non-notch displays. Expected — panel just sits at top. |
