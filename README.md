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
- [Godot Engine 4.6+](https://godotengine.org/download)
- Git
- Python 3.9+ (with pip/venv) and a C++ compiler: Xcode command line tools on
  macOS, build-essential on Linux, or Visual Studio 2022 C++ tools on Windows.

### Clone and Build (Linux / macOS)

```bash
# Clone with submodules
git clone --recursive https://github.com/turnrocklabs/Minerva.git
cd Minerva

# Build native editor dependencies (installs Zig and SCons if needed)
scripts/build-extensions.sh
```

### Clone and Build (Windows)

```powershell
# Clone with submodules
git clone --recursive https://github.com/turnrocklabs/Minerva.git
cd Minerva

# Build native editor dependencies (installs Zig and SCons if needed)
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1
```

### What the Build Scripts Do

Close Minerva and its editor before a full native rebuild. Both scripts handle:

- Git submodule initialization (godot-cpp, vendor/ghostty)
- Zig 0.15.2 download and install (user-local, no sudo/admin)
- SCons install in a local `.build-venv` if missing
- MCP JSON Schema helper build from pinned, checksum-verified jsoncons source
- ghostty-vt shim build (Zig)
- Godot C++ terminal extension build (SCons)
- Library installation to `src/bin/`
- Pinned built-in Voice runtime for the current host architecture
- FFmpeg and SQLite installation, then native dependency checks

The MCP helper is required for **all plugin startup**, including legacy plugins.
To repair just that dependency in an existing checkout:

```bash
scripts/build-extensions.sh --helper-only                 # Linux/macOS
scripts/build-extensions.sh --voice-only                  # Repair/check Voice only
scripts/build-extensions.sh --check                       # Check without rebuilding
```

```powershell
./scripts/build-extensions.ps1 -HelperOnly                 # Windows
./scripts/build-extensions.ps1 -VoiceOnly
./scripts/build-extensions.ps1 -Check
```

The check starts short-lived schema and Voice workers and loads core libraries in
isolated processes. It does not launch Godot, the Minerva project, or the
microphone. It must pass before testing plugin startup in the editor; CEF panels
and PDF remain optional checks.

CEF-hosted panels and the PDF sidecar are built separately — see
**[Docs/Building.md](Docs/Building.md)** for the complete build reference,
including per-platform prerequisites and the vendor patch system.

### Run

Open `src/project.godot` in Godot Editor 4.6+ and press F5.

### If You Already Cloned Without --recursive

```bash
git submodule update --init --recursive
scripts/build-extensions.sh          # Linux/macOS
```
```powershell
git submodule update --init --recursive
powershell -ExecutionPolicy Bypass -File scripts\build-extensions.ps1  # Windows
```

## Docket Files ##

Minerva uses [Docket](https://github.com/turnrocklabs/docket) for issue/task
tracking. Docket stores data in `.dct` files. Since `17f7778f` these are
**JSONL text** — line-oriented, diffable, and committed directly. No git
filter setup is required.

The SQLite intermediates Docket builds alongside them (`*.dct.cache*`,
`*.dct-wal`, `*.dct-shm`) are generated locally and gitignored.

**Never hand-edit a `.dct`.** Go through Docket — its app, or its MCP verbs —
so the file and its indexes stay consistent. Run a flush before `git add` to
settle pending writes.

## External Dependencies ##

| Library | Version | License | Purpose | Acquisition |
|---------|---------|---------|---------|-------------|
| [Godot Engine](https://godotengine.org) | 4.6+ | MIT | Application engine | User installs separately |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | 4.3 | MIT | C++ GDExtension bindings | Git submodule (`src/godot-cpp`) |
| [Ghostty / libghostty-vt](https://github.com/ghostty-org/ghostty) | 1.3.1 | MIT | Terminal emulator core (VT parser) | Git submodule (`vendor/ghostty`), built by `build-extensions.sh` via Zig |
| [EIRTeam.FFmpeg](https://github.com/EIRTeam/EIRTeam.FFmpeg) | 1.1.4 | MIT (wrapper) + LGPL 2.1 (ffmpeg) | Video/audio codec support | Downloaded from GitHub releases by `build-extensions.sh` |
| [Zig](https://ziglang.org) | 0.15.2 | MIT | Build tool for ghostty shim | Auto-installed by `build-extensions.sh` |
| [SCons](https://scons.org) | 4.x | MIT | Build tool for C++ extension | Auto-installed via pip by `build-extensions.sh` |
| [jsoncons](https://github.com/danielaparker/jsoncons) | Pinned `bcb44594` + Minerva patch | Boost-1.0 | Isolated MCP JSON Schema and numeric validation helper | Verified source archive; built by both extension setup scripts |
| [Bun](https://bun.sh) | 1.x | MIT | Stream Deck plugin compiler (optional) | User installs: `curl -fsSL https://bun.sh/install \| bash` |

The table lists each dependency's license. FFmpeg libraries are used unmodified and dynamically linked under LGPL 2.1.

## Acknowledgments ##

Minerva is built on the shoulders of these open-source projects:

- **Godot Engine** by Juan Linietsky, Ariel Manzur, and contributors (MIT)
- **Ghostty** by Mitchell Hashimoto and contributors (MIT) — terminal emulator core
- **EIRTeam.FFmpeg** by Alex Roman / EIRTeam (MIT) — Godot FFmpeg integration
- **FFmpeg** by the FFmpeg developers (LGPL 2.1) — audio/video codecs
- **godot-cpp** by Godot Engine contributors (MIT) — C++ GDExtension bindings
