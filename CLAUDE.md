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