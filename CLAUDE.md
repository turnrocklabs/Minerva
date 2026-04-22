# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Minerva is a Godot 4 application that provides an interface for interacting with Large Language Models (LLMs). It combines note-taking, code editing, and AI chat functionality to help users work more effectively with AI assistants.

## Tech Stack

- **Engine**: Godot 4.4
- **Primary Language**: GDScript
- **Build System**: SCons (for C++ extensions)
- **Architecture**: Scene-based Godot application with singleton pattern for global state

## Build Commands

### First-time Setup (clones submodules, installs tools, builds everything)
```bash
# Linux / macOS
git submodule update --init --recursive
scripts/build-extensions.sh        # Builds ghostty-vt shim + terminal extension
```
```powershell
# Windows
git submodule update --init --recursive
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
```

### Building C++ Extensions (Terminal + ghostty-vt)
The build script handles everything automatically:
```bash
scripts/build-extensions.sh          # Auto-detects platform
scripts/build-extensions.sh linux    # Force Linux build
scripts/build-extensions.sh macos    # Force macOS build
```

This builds two libraries:
- `libminerva-vt.so/.dylib` — ghostty-vt shim (Zig, wraps libghostty terminal emulator)
- `libterminal.*.so/.dylib/.dll` — Godot C++ GDExtension for terminal functionality

Both end up in `src/bin/`. The build script installs Zig 0.15.2 and SCons automatically if missing.

### Building WebView Extension (Godot WRY)
WebView panels use the godot_wry GDExtension (git submodule at `vendor/godot_wry`).

**Linux prerequisites:**
```bash
sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev
# Rust/Cargo required — install via rustup if missing
```

**Build:**
```bash
cd vendor/godot_wry/rust
cargo build --release
cp target/release/libgodot_wry.so ../../src/addons/godot_wry/bin/x86_64-unknown-linux-gnu/
```

The `.gdextension` file and `extension_list.cfg` are already configured. The binary goes to `src/addons/godot_wry/bin/x86_64-unknown-linux-gnu/`.

**Note:** The upstream godot_wry v1.0.2 release has a GTK init panic on Linux. Our submodule includes a fix for `get_screen_position()` → `get_global_position()` to correct native window positioning.

### Building godot-cef (CEF-based webview panels)
CEF-hosted plugin panels use the godot-cef GDExtension (git submodule at `vendor/godot_cef` pinned to v1.13.0).

**Prerequisites:** rustup (the script installs `nightly` and `export-cef-dir` as needed).

**Build + deploy (auto-detects platform):**
```bash
scripts/build-godot-cef.sh
# or explicitly:
scripts/build-godot-cef.sh linux
scripts/build-godot-cef.sh macos
scripts/build-godot-cef.sh windows
```

The script applies every `patches/godot_cef/*.patch` to the submodule before building, so the patched binaries are what land in `src/addons/godot_cef/bin/<platform>/`. Patches are self-documenting — see `patches/godot_cef/README.md`. The submodule working tree is reset before each build so patches are idempotent.

**Cross-building is not supported.** Run the script on each target OS (Mac for universal-apple-darwin, Windows for x86_64-pc-windows-msvc, Linux for x86_64-unknown-linux-gnu).

### Manual build (if you prefer)
```bash
# 1. Build ghostty-vt shim
cd src/gdextension/terminal/ghostty-shim
zig build -Doptimize=ReleaseFast

# 2. Build Godot C++ extension
cd src
scons platform=linux  # or macos/windows

# 3. Copy shim library to bin/
cp src/gdextension/terminal/ghostty-shim/zig-out/lib/libminerva-vt.so src/bin/
```

### Running the Application
- Open `src/project.godot` in Godot Editor 4.4+
- Press F5 or click Play to run the application
- Main scene: `res://Scenes/MainScene.tscn`

### Stream Deck Plugin (optional)
```bash
cd plugins/elgato
bun test                    # Run 80 tests
bun build --compile src/index.ts --outfile dist/bin/minerva-plugin-linux
```

## Core Architecture

### Singleton System
The application uses `SingletonObject` (src/Scripts/Models/singleton_object.gd) as the central state manager that handles:
- **Notes Management**: Thread-based note organization with support for text, audio, image, and video notes
- **Chat System**: Multiple chat histories with different LLM providers
- **Editor Management**: Multi-tab code editor with syntax highlighting
- **Project Management**: Save/load project states including notes, chats, and editor tabs
- **Theme & UI**: Dark/Light/Windows theme switching and UI scaling

### Provider System
Located in `src/Scripts/Services/Providers/`:
- **BaseProvider.gd**: Abstract base class for all LLM providers
- **Core/Core.gd**: WebSocket-based connection to TurnRock's proprietary backend
- Multiple provider implementations (Google Vertex, OpenAI, Anthropic Claude, local Ollama)

### Scene Structure
Main UI components in `src/Scenes/`:
- **MainScene.tscn**: Root application scene
- **Chat.tscn**: Chat interface component
- **Editor.tscn**: Code editor component
- **Note.tscn**: Individual note component
- **Terminal.tscn**: Terminal emulator component

### Key Features
1. **Multi-Provider Support**: Seamlessly switch between different LLM providers
2. **Note System**: Organize context and instructions in threads
3. **Code Editor**: Built-in editor with syntax highlighting for multiple languages
4. **Project Packaging**: Save/load entire project states as .minproj files
5. **Audio/Video Support**: Handle multimedia content in notes and chats

## Important Patterns

### Signal-Based Communication
The application heavily uses Godot's signal system for decoupled communication:
- Global signals defined in SingletonObject for cross-component communication
- Local signals within components for UI updates

### Resource Management
- Audio/video files are base64 encoded when included in chats
- Supports various formats defined in singleton_object.gd
- Config file stored at `user://config_file.cfg` for persistent settings

### Error Handling
Uses `SingletonObject.ErrorDisplay()` for unified error presentation to users

## Development Notes

- The application name "AgentInator" is used internally but marketed as "Minerva"
- Experimental features can be toggled and are hidden behind the experimental flag
- The terminal extension requires platform-specific compilation using SCons
- Provider credentials are managed through the AISettings window

## Nudge MCP Tool

A session-scoped hint cache for storing and retrieving micro-facts (commands, paths, small configs) by component/key.

### Usage Rules

**Read before you act:**
- Before build/test/run/deploy, try: `get_hint(component, key, context)`
- On errors, try: `query({component, tags, context})`

**Write what you learn:**
- When a user corrects you or you discover a working incantation/path, do `set_hint(…)`
- After a hint helped and succeeded, `bump(component, key)`

**Keep it small:**
- Store quick, actionable facts (one liners, small JSON). Prefer TTL "session"

### Common Keys
`build`, `test`, `start`, `run`, `deploy`, `path`/`directory`, `env.*`, `tooling` (e.g., `tooling.lint`), `messages`

### Quick Reference
```
set_hint(component, key, value, meta?) → {hint}
get_hint(component, key, context?) → {hint, match_explain}
query({component?, keys?, tags?, regex?, context?, limit?}) → [{hint, score}]
bump(component, key, delta=1) → {hint}
list_components() → [{name, hint_count}]
```

### Do / Don't
**Do:**
- Keep values short and exact
- Add tags and a brief reason
- Use TTL "session" unless you need a timed duration

**Don't:**
- Store secrets (tokens, passwords)
- Auto-execute anything returned by Nudge
- Overwrite good hints with guesses

## Co-Browser MCP Tool

Browser automation through Firefox extension. Source: `~/github/HumanWeb`

### Architecture

```
Claude Code ──STDIO──> MCP Server ──HTTP──> Co-Browser Service ──WebSocket──> Firefox Extension
                       (mcp_server.py)      (port 8677)                        (humanweb)
```

### Starting the Service

```bash
cd ~/github/HumanWeb
python -m uvicorn src.Library.cobrowser_service:app --host 0.0.0.0 --port 8677
```

The Firefox extension must be installed and active. Use `Ctrl+Shift+Y` in Firefox to toggle connection.

### HTTP API (Port 8677)

**IMPORTANT**: Co-Browser uses a CUSTOM HTTP format, NOT JSON-RPC.

#### Check Active Sessions
```bash
curl http://localhost:8677/v1/cobrowser/sessions/active
# Returns: {"sessions": [{"session_id": "...", "created_at": "..."}]}
```

#### Send Command
```bash
curl -X POST http://localhost:8677/v1/cobrowser/command/{session_id}/sync \
  -H "Content-Type: application/json" \
  -d '{"type": "command.navigate", "payload": {"url": "https://example.com"}, "timeout": 30.0}'
```

### Command Types

| Type | Payload | Description |
|------|---------|-------------|
| `command.navigate` | `{url}` | Navigate to URL |
| `command.click` | `{selector?, xpath?, x?, y?}` | Click element |
| `command.type` | `{selector, text, clear?}` | Type into input |
| `command.read` | `{selector}` | Read element text |
| `command.scroll` | `{direction, amount?, selector?}` | Scroll page |
| `command.query_all` | `{selector, limit?}` | Query multiple elements |
| `command.getState` | `{}` | Get page metadata, DOM, security info |
| `command.screenshot` | `{}` | Capture screenshot |
| `command.request_human` | `{reason, message}` | Request user intervention |

### MCP Tools (via STDIO)

When using through MCP (not direct HTTP), these tools are available:

- `cobrowser_navigate` - Navigate to URL
- `cobrowser_click` - Click element by selector/xpath/coordinates
- `cobrowser_type` - Type text into input field
- `cobrowser_read` - Read text from element
- `cobrowser_scroll` - Scroll in direction
- `cobrowser_query_all` - Get multiple elements
- `cobrowser_get_page_info` - Get current page info
- `cobrowser_screenshot` - Take screenshot
- `cobrowser_request_human` - Request human assistance
- `native_*` variants - Direct DOM manipulation bypassing visual automation

### Testing Connection

```bash
# 1. Check service is running
curl http://localhost:8677/v1/cobrowser/sessions/active

# 2. If you get sessions, test a command
SESSION_ID="<from-above>"
curl -X POST "http://localhost:8677/v1/cobrowser/command/$SESSION_ID/sync" \
  -H "Content-Type: application/json" \
  -d '{"type": "command.getState", "payload": {}, "timeout": 5.0}'
```

### Troubleshooting

- **No sessions**: Firefox extension not connected. Press `Ctrl+Shift+Y` in Firefox
- **Connection refused**: Service not running. Start with `python src/humanweb/service.py`
- **Timeout**: Page not loaded or selector not found

## Terminal MCP Tools

Minerva exposes interactive terminal control via MCP. These tools let agents drive CLI programs (including other Claude instances) through real PTY terminals visible in the UI.

### Available Tools
- `minerva_terminal_list` — list open terminals with IDs
- `minerva_terminal_create` — open new terminal tab
- `minerva_terminal_close` — close terminal by ID
- `minerva_terminal_read` — read screen content (viewport or scrollback)
- `minerva_terminal_write` — send keystrokes to terminal (non-blocking)
- `minerva_terminal_wait` — wait for output to settle, return screen content

### IMPORTANT: Use `\r` for Enter, not `\n`
The terminal PTY expects carriage return (`\r`) for the Enter key. A line feed (`\n`) inserts a newline character but does NOT submit the command. Always use `\r` at the end of commands:
```
minerva_terminal_write text="ls -la\r"        ✓ correct
minerva_terminal_write text="ls -la\n"        ✗ wrong — won't submit
```

### Common escape sequences
- `\r` — Enter/Return (submit command)
- `\n` — Line feed (literal newline, rarely needed)
- `\t` — Tab (for tab completion)
- `\x03` — Ctrl+C (interrupt/cancel)

### Interactive CLI pattern
To drive an interactive program (like `claude`):
1. `terminal_write text="claude\r"` — launch it
2. `terminal_wait timeout_ms=15000 settle_ms=3000` — wait for it to start
3. `terminal_write text="your message here\r"` — send input
4. `terminal_wait timeout_ms=30000 settle_ms=3000` — wait for response
5. `terminal_read` — read the screen
6. Repeat 3-5 for multi-turn conversation

### CodeTools MCP
File manipulation tools with policy enforcement:
- `minerva_file_read`, `minerva_file_write`, `minerva_file_edit`
- `minerva_file_glob`, `minerva_file_grep`
- `minerva_bash` — executes in terminal PTY when visible, headless fallback
- `minerva_cwd` — get/set working directory
- Policy: `~/.codetools/policy.json` with regex deny patterns

### Activity Log
All MCP tool calls are automatically logged to an "Activity: MCP" editor tab for full traceability.