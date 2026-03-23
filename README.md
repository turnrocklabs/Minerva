# Minerva #
Minerva is the Roman goddess of Inspiration.  This project, codename Minerva, will also be an app that helps you explore and automate stuff.

## Problem statement ##
We have LLM based AIs now.  They all kind of suck.  They're good at chatting, but not really doing stuff, and their error rate is high.  Hallucinations, catastrophic forgetting, and incorrect past weights plague their repsonses.  If you've ever tried to write modern Godot 4 with ChatGPT or even write python for modern Blender, you'll quickly see the errors.

This is not just in code writing -- the problems are everyplace in LLMs.  Even if you write a story, or try and create a CAD model, these mistakes happen.  They are generic problems.

## How Minerva helps ##
Minerva adds a note-taking system and (hopefully) some editors and task runners.  With Minerva, you can take some notes on how to correct the LLM, then ask the LLM to do something.  You can then manage the results from the LLM -- either by putting those into notes, or by putting them into your work product. 

## Features ##
- Cloud Light -- minimize interactions with the cloud / cloud services as much as possible.  Save files locally, use local resources, etc.
- Note area, with selectable notes.  (Only selected notes are submitted to the LLM, the rest are just for the human)
- Multi-provider support (Google Vertex, OpenAI, Anthropic Claude, OpenRouter, local Ollama, and more)
- Built-in terminal with libghostty-vt integration
- Autocoder for LLM-driven code generation with review agents
- Stream Deck integration for hardware controls (PTT, audio device switching)
- Voice support: push-to-talk, TTS, always-listening mode

## Getting Started ##

### Prerequisites
- [Godot Engine 4.4+](https://godotengine.org/download)
- Git

### Clone and Build (Linux / macOS)

```bash
# Clone with submodules
git clone --recursive https://github.com/turnrocklabs/Minerva.git
cd Minerva

# Set up git filters (required — see "Docket Files" section below)
scripts/setup-git-filters.sh

# Build all C++ extensions (installs Zig and SCons if needed)
scripts/build-extensions.sh
```

### Clone and Build (Windows)

```powershell
# Clone with submodules
git clone --recursive https://github.com/turnrocklabs/Minerva.git
cd Minerva

# Build all C++ extensions (installs Zig and SCons if needed)
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
```

### What the Build Scripts Do

Both scripts automatically handle:
- Git submodule initialization (godot-cpp, vendor/ghostty)
- Zig 0.15.2 download and install (user-local, no sudo/admin)
- SCons install via pip
- ghostty-vt shim build (Zig)
- Godot C++ terminal extension build (SCons)
- Library installation to `src/bin/`

### Run

Open `src/project.godot` in Godot Editor 4.4+ and press F5.

### If You Already Cloned Without --recursive

```bash
git submodule update --init --recursive
scripts/build-extensions.sh          # Linux/macOS
```
```powershell
git submodule update --init --recursive
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1  # Windows
```

## Docket Files (SQLite Clean/Smudge Filters) ##

Minerva uses [Docket](https://github.com/turnrocklabs/docket) for issue/task tracking. Docket stores data in `.dct` files, which are SQLite databases. Since binary SQLite files corrupt easily when merged across branches or machines (WAL mode conflicts), we use **git clean/smudge filters** to store them as text SQL dumps in git.

**How it works:**
- **On commit (clean filter):** SQLite binary → SQL text dump (diffable, mergeable)
- **On checkout (smudge filter):** SQL text dump → SQLite binary (usable by Docket)

**Setup (required once per clone):**
```bash
scripts/setup-git-filters.sh
```

This registers the filters in your local git config. Without it, `.dct` files will be committed as raw binary and may corrupt on pull. The `.gitattributes` file tells git which files use the filter:
```
*.dct filter=sqlite3 diff=sqlite3
```

**Troubleshooting:**
- If a `.dct` file shows as modified after checkout, that's normal — the smudge filter rebuilds the binary from SQL text, and the binary may differ byte-for-byte from the original.
- If Docket can't open a `.dct` file after a pull, try: `git checkout -- Docs/minerva.dct` to re-trigger the smudge filter.

