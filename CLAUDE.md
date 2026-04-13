# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ClaudeNotch is a native macOS SwiftUI app that shows a Dynamic-Island-style widget flush against the MacBook notch, visualising live Claude Code sessions (status, tool, todos, subagents, usage, permission prompts). It is a SwiftPM package — no Xcode project.

Target: macOS 13+, Swift 5.9, SwiftUI + AppKit (NSPanel).

## Build / Run

```bash
./build.sh      # swift build -c release, assemble ClaudeNotch.app, ad-hoc codesign
./run.sh        # build, pkill -x ClaudeNotch, open ClaudeNotch.app
```

There is no test suite and no linter. Do not `swift run` — the app must live inside a `.app` bundle because `HookInstaller` resolves `Contents/Helpers/claudenotch-bridge` relative to `Bundle.main.executablePath`.

After a rebuild you must kill the old instance (`pkill -x ClaudeNotch`) or `./run.sh` does it for you — the Unix socket at `~/Library/Application Support/ClaudeNotch/bridge.sock` is held by the previous process otherwise.

## Architecture

Two SwiftPM executable targets:

- **`ClaudeNotch`** — the GUI app (menu-bar + floating NSPanel).
- **`ClaudeNotchBridge`** — a tiny helper binary installed as `Contents/Helpers/claudenotch-bridge`. Claude Code hooks `exec` it; it reads one JSON event from stdin, forwards it over the Unix socket, and exits. For `PermissionRequest` it blocks on `recv()` until the GUI writes a decision back to stdout (Claude Code reads that to allow/deny without the user touching the terminal). If the GUI isn't running it exits 0 silently — hooks must never block Claude Code.

### Data flow (real-time path)

```
Claude Code  ──hook──▶  claudenotch-bridge  ──UDS──▶  HookServer  ──▶  ClaudeWatcher  ──@Published──▶  NotchView
                                                          │
                                                          └─ PermissionRequest: fd kept open in `pendingApprovals`,
                                                             decision written back when user clicks a button.
```

- **`HookInstaller`** merges ClaudeNotch hook entries into `~/.claude/settings.json` with timestamped backups and leaves every non-ClaudeNotch entry intact (so Vibe Island etc. keep working). Subscribes to 11 events: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest` (24h timeout — blocks on the bridge), `Notification`, `Stop`, `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PreCompact`. Also installs a StatusLine shim that dumps `.rate_limits` to `/tmp/claudenotch-rl.json` on every assistant message — this is the primary (zero-API-call) usage source.
- **`HookServer`** (`@MainActor`) is the Unix-domain-socket listener. Each connection delivers exactly one `\n`-framed JSON line, gets parsed into `HookServer.Event`, and is handed to the watcher. Tracks `pendingApprovals` (open client fds for blocking `PermissionRequest`) and `sessionTTY` (TTY discovered by the bridge via `ps`, used for focus-based suppression and terminal-tab focus).
- **`ClaudeWatcher`** is the single source of UI truth. `@MainActor`, 2 s polling loop for on-disk session discovery (tails `.jsonl` files in `~/.claude/projects/*`, 48 h window, filters `agent-*` subagent files), plus hooks for sub-100 ms real-time status. Owns the `SessionStatus` state machine (`working`, `compacting`, `awaitingApproval`, `interrupted`, `idle`), `CurrentTool` (cleared on `PostToolUse`), `Subagent` map, `TodoItem`s, and `hookAliveSessions` (a set maintained by `SessionStart`/`SessionEnd`). Active = `<20 min` since last activity OR hook-alive → full row. Otherwise → compact single-line row.
- **`NotchView`** (~1200 lines) is the whole SwiftUI tree: collapsed pill (≈300 pt pixel-art avatars + usage badge), expanded dashboard (≈560 pt adaptive height), markdown conversation cards, dynamic permission buttons, todos, subagent cards. `NotchPanel` is a borderless `.nonactivatingPanel` NSPanel sized `600 × (380 + notchHeight)`, flush against the top of the screen so its top strip is hidden behind the physical notch cutout.
- **`UsageFetcher`**: PRIMARY source is `/tmp/claudenotch-rl.json` (StatusLine shim, polled every 5 s, zero API cost). FALLBACK is `GET https://api.anthropic.com/api/oauth/usage` every ~10 min, authenticated via the OAuth token read by `KeychainReader` from the Claude Code CLI keychain entry. `Utilization` shape mirrors `reference/claude-code-source/src/services/api/usage.ts`.
- **`FocusMonitor`** tracks `NSWorkspace.frontmostApplication` for the smart-suppression rules (see below).
- **`SessionLauncher`** focuses the correct Terminal tab for a session via AppleScript window-title matching, and/or the TTY discovered by the bridge (`ps -o tty=,ppid=` walking up from the bridge's PID, Vibe Island-style).
- **`SoundManager`** plays the Clean Chimes pack from `Resources/Sounds/`, with 7 categories and spam detection (≥3 in 10 s → muted).
- **`AppDelegate`** wires it all together and owns the menu-bar `NSStatusItem`.

### Smart suppression rules (important — easy to accidentally break)

- **PermissionRequest**: ALWAYS expands the panel, even if a terminal is frontmost.
- **Done / Stop**: SUPPRESSED if the frontmost app is the terminal tab belonging to the *same* session (window-title / TTY match).
- **Auto-expanded popups** (from a hook): NOT collapsed by app-switching — only by the 10 s "Done" timer.
- **Manually hovered** expansions: collapsed on app-switch.

### Permission buttons (dynamic)

The buttons rendered in the permission card are driven by `permission_suggestions` in the `PermissionRequest` payload:

- Non-empty → 4 buttons: Deny · Allow Once · Always Allow · Bypass
- Empty → 3 buttons: Deny · Allow Once · Bypass

When editing this, keep the mapping consistent between `ClaudeWatcher` (parses suggestions into `CurrentTool.hasAlwaysAllow`), `HookServer` (forwards `permission_suggestions` verbatim), and `NotchView` (renders the buttons).

## Reference source tree

`reference/claude-code-source/` is a checked-out Claude Code source snapshot kept locally for research (it's gitignored). When you need ground-truth hook payload shapes, StatusLine behaviour, or the exact usage API response, look there before guessing — several structs in this project (e.g. `Utilization`) cite specific files in that tree.

## Conventions

- All code comments and docstrings are in English. The target user (Ahmed) speaks Arabic but code stays English.
- Commit messages: no emojis, no "Generated with Claude Code" footer, conventional-commit prefixes (`feat:`, `fix:`, `refactor:`, …).
- `NotchView` and `ClaudeWatcher` are already large — prefer editing in place over splintering them, unless you have a clear reason.
- This is a fast-moving personal project; Ahmed frequently sends Vibe Island screenshots as UI specs.
