# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Quick Start

```bash
bd ready --json              # Check for ready work
bd create "Title" -t bug|feature|task -p 0-4 --json  # Create issue
bd update bd-42 --status in_progress --json          # Claim task
bd close bd-42 --reason "Done" --json                # Complete task
```

### Workflow

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task**: `bd update <id> --status in_progress`
3. **Work on it**: Implement, test, document
4. **Discover new work?** `bd create "Found bug" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`
6. **Commit together**: Always commit `.beads/issues.jsonl` with code changes

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Rules

- Always use `--json` flag for programmatic use
- Run `bd <cmd> --help` to discover available flags
- Do NOT create markdown TODO lists

## Project Overview

Minerva is a Godot 4 application that provides an interface for interacting with Large Language Models (LLMs). It combines note-taking, code editing, and AI chat functionality to help users work more effectively with AI assistants.

## Tech Stack

- **Engine**: Godot 4.4
- **Primary Language**: GDScript
- **Build System**: SCons (for C++ extensions)
- **Architecture**: Scene-based Godot application with singleton pattern for global state

## Build Commands

### Building C++ Extensions (Terminal functionality)
```bash
cd src
scons platform=linux  # For Linux
scons platform=windows  # For Windows
```

### Running the Application
- Open `src/project.godot` in Godot Editor 4.4
- Press F5 or click Play to run the application
- Main scene: `res://Scenes/MainScene.tscn`

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