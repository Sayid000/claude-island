# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Quick start commands

Prerequisites (from README): macOS 15.6+ and the Claude Code CLI installed.

- Open the project in Xcode
  - xed .
- Debug build (CLI)
  - xcodebuild -scheme ClaudeIsland -configuration Debug -destination "platform=macOS" build
- Clean
  - xcodebuild -scheme ClaudeIsland clean
- Release build + export app bundle
  - ./scripts/build.sh
- Notarize, create DMG, Sparkle-sign, and (optionally) create a GitHub release
  - ./scripts/create-release.sh
- Generate Sparkle keys (one-time, before shipping auto-updates)
  - ./scripts/generate-keys.sh

Notes
- No SwiftLint/SwiftFormat config is present.
- No test target or test files are present; xcodebuild test is not configured.

## High-level architecture

Claude Island is a macOS menu bar (LSUIElement) app that surfaces Dynamic Island-style UI for Claude Code sessions. The app auto-installs a hook script into ~/.claude/hooks, listens on a Unix domain socket for session events, and renders a notch UI that can approve or deny tool executions.

Key flow (end-to-end)
1) Hook installation (first launch)
   - Services/Hooks/HookInstaller.swift copies Resources/claude-island-state.py to ~/.claude/hooks and amends ~/.claude/settings.json to invoke it on Claude events.
2) Event ingress
   - The Python hook (Resources/claude-island-state.py) sends JSON to a Unix socket at /tmp/claude-island.sock for events like UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Notification, Stop, etc. For PermissionRequest it waits for a response.
   - Services/Hooks/HookSocketServer.swift starts a non-blocking AF_UNIX socket server, parses events, correlates tool_use_id across PreToolUse/PermissionRequest, and keeps sockets open while waiting for an approval decision.
3) State management
   - Services/State/SessionStore.swift is the single source of truth (actor). All mutations go through process(_:) and it publishes a Combine stream consumed by the UI.
   - It tracks sessions, phases (idle/processing/waiting_for_approval/compacting), chat history items, tool tracking and subagent tool activity, and reconciles state with JSONL logs.
   - Services/Session/*: JSONLInterruptWatcher detects Ctrl+C-style interrupts; ConversationParser parses Claude’s JSONL conversation files; AgentFileWatcher loads per-agent (subagent) logs to populate Task tool details.
4) Permissions
   - When the user approves/denies in the notch UI, ClaudeSessionMonitor calls HookSocketServer.respondToPermission(...), which writes a JSON decision back to the waiting socket.
5) UI and windowing
   - App/AppDelegate.swift initializes Sparkle (SPUUpdater) and Mixpanel, installs hooks, and sets up the notch window via App/WindowManager.swift.
   - Core/NotchViewModel.swift owns notch state, geometry (Core/NotchGeometry.swift), and transitions between instances/menu/chat views. EventMonitors provide global mouse events for hover/click behavior.
   - UI/Window/* implements a frameless, click-through NSWindow that expands/collapses above the physical notch; UI/Views/* and UI/Components/* are SwiftUI views for the header, chat, tool results, pickers, etc.
6) Integrations and environment
   - Services/Tmux/* maps Claude sessions to tmux targets and can send keystrokes for approval flows.
   - Services/Window/YabaiController.swift focuses the corresponding terminal window when yabai is available (optional; falls back gracefully when missing).
   - Services/Shared/* provides lightweight process execution, process-tree scanning, and terminal-app detection.
   - Sparkle is configured in Info.plist (SUFeedURL, SUPublicEDKey) and managed at runtime by NotchUserDriver.
   - Mixpanel tracks basic lifecycle metrics (see AppDelegate).

Repository layout (top level of ClaudeIsland/)
- App: lifecycle (AppDelegate, ClaudeIslandApp), window setup, screen observation.
- Core: notch geometry + view model and shared selectors.
- Models: session, tool, and chat data types.
- Services: Hooks (install/socket), State (SessionStore), Session (parsers/watchers), Tmux, Window (focus/yabai), Chat, Shared utilities.
- UI: SwiftUI views/components and NSWindow bridge.
- Events: global input monitors.
- Resources: entitlements and the bundled hook script.

Operational considerations
- Hooks live under ~/.claude; HookInstaller.isInstalled()/uninstall() provide programmatic checks/cleanup used by the app.
- The AF_UNIX socket path is /tmp/claude-island.sock; ensure nothing else binds to it.
- Yabai is optional; without it, focusing terminal windows may be limited.
- Release automation relies on Xcode’s archive/export, Apple notarization (keychain profile), Sparkle signing tools from the Sparkle SPM artifact, and an optional website repo (CLAUDE_ISLAND_WEBSITE env) for appcast updates.

## Important bits from README
- Requirements: macOS 15.6+, Claude Code CLI.
- Install/build (source): xcodebuild -scheme ClaudeIsland -configuration Release build
- Features: Notch UI, live session monitoring, permission approvals, chat history, auto-setup of hooks.
- Analytics: Mixpanel collects anonymous app/OS version and session-start events; no conversation content is collected.
