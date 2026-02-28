# Supervisor Pattern & Skills System — Thought Paper

**Status:** Early concept / Design exploration
**Date:** 2026-02-27
**Context:** Emerged from discussion about adding a skills system to Minerva and the question of how skills get orchestrated across execution boundaries.

---

## 1. The Problem

Minerva's agentic chats can already execute complex multi-step workflows. They can call MCP tools (CodeTools, cobrowser, PCB editor), invoke the autocoder over the service bus, instance other agents, and even spin up Claude Code as a provider. Execution capability is not the bottleneck.

The problem is **drift**. As a chat session accumulates context — research tangents, debugging detours, tool output — the agent loses its grip on the original goal. In automatic mode this is especially dangerous: there's no human checkpoint pulling things back on track. Chats are excellent for *exploration and planning* but unreliable for *sustained execution against a fixed intent over time*.

A second problem is **skills**. Minerva needs a way to package reusable tool capabilities (instructions + executables) that agents can discover and invoke, that span the local/service-bus boundary, and that can be installed, updated, composed, and removed over time. Skills need an orchestrator that understands *when* and *why* to invoke them, not just *how*.

These two problems converge: the thing that orchestrates skills must also be the thing that preserves intent. That thing is the **supervisor**.

---

## 2. Guiding Scenario: PCB Design-to-Firmware Pipeline

This scenario grounds the discussion in a concrete, real workflow.

### Context

- **pcb-architect**: A Docker-based CLI tool (`~/gitlab/ccsandbox`) that takes a BOM and board constraints, runs placement/routing, and outputs a PCB definition.
- **Minerva's PCB Editor**: Built into Minerva — loads, visualizes, annotates, and refines PCB layouts via MCP tools.
- **Cobrowser**: MCP tool for shared web browsing between user and AI agent.
- **CodeTools**: MCP tool that lets Minerva agents write and run scripts locally.

### The Workflow

**Step 1: Research & BOM Creation** *(Chat + Cobrowser + Spreadsheet)*

Open Minerva, start a chat with cobrowser enabled. Collaboratively browse supplier sites (Mouser, DigiKey, LCSC) to find components for a sensor board — ESP32, I2C sensors, voltage regulators, connectors. The agent records parts into a Minerva Spreadsheet: part numbers, footprints, quantities, prices. Output: a structured BOM as a live spreadsheet. No skills involved — just chat + cobrowser + spreadsheet.

**Step 2: BOM-to-PCB** *(pcb-maker skill)*

Invoke the **pcb-maker skill**. Under the hood:
- Reads the BOM spreadsheet from Minerva (skill instructions tell the agent how to extract/format data)
- Calls pcb-architect CLI inside its Docker container (`pcb-architect generate --bom bom.csv --constraints board-spec.yaml`)
- Loads the output PCB definition into Minerva's PCB Editor

The user annotates the board layout ("move USB to the edge," "keep RF traces short," "ground plane under RF section"). The agent interprets annotations, tweaks the definition, re-runs pcb-architect, loads updated designs. Iterate until the layout is solid.

**Step 3: Firmware Generation** *(Autocoder)*

With PCB design finalized, kick off an autocoder session. The autocoder can see the PCB definition (pin assignments, peripherals, bus mappings). Prompt: "Write firmware — init I2C sensors, read at 10Hz, expose over BLE." Planning, Q&A, code generation, review. A review agent might invoke a **compile-check skill** running `pio build` in a PlatformIO container to verify compilation.

**Step 4: Flash & Test** *(Local skill)*

Invoke a **local flash-and-test skill**. Runs on the local machine (needs USB access for the dev board serial port). Calls `pio run --target upload`, then `pio device monitor`. The agent interprets serial output — boot messages, sensor readings, errors ("I2C sensor at 0x68 not responding — check wiring or try 0x69"). Suggests firmware tweaks.

### What This Reveals

| Aspect | pcb-maker | compile-check | flash-and-test |
|--------|-----------|---------------|----------------|
| **Runs where** | Local Docker | Local or container | Local machine |
| **Invoked by** | Agent / chat | Review agent (autocoder) | Agent / chat |
| **Needs** | pcb-architect CLI, BOM data | PlatformIO, firmware source | USB access, PlatformIO |
| **Input from Minerva** | Spreadsheet data | Generated source files | Compiled firmware |
| **Output to Minerva** | PCB definition | Pass/fail + compiler errors | Serial output + test results |

---

## 3. Skill Lifecycle Management

Skills aren't static. They need full lifecycle management, and they can originate from multiple sources.

### Operations

- **Install**: Pull a skill from a source (GitHub repo, local directory, tarball) and register it with Minerva.
- **Update**: New versions of tools land (pcb-architect gets better autorouting). Update the installed skill, flag downstream impacts if formats change.
- **Create**: Build a skill from scratch during a session. Example: write a custom RF trace router together, then install it immediately.
- **Compose**: Chain skills into pipelines. The PCB workflow becomes: `pcb-architect generate` -> `rf-router optimize` -> `pcb-architect drc`. Insert, reorder, remove pipeline steps.
- **Remove**: Clean up a skill when no longer needed. Minerva's registration is removed; the underlying tool on the system is untouched.

### Skill Definition (Manifest)

A skill needs:
- **Instructions**: What the skill does, when/how to invoke it, how to interpret results. This is what the AI reads.
- **Execution commands**: The actual CLI/binary/pipeline to run.
- **Boundary affinity**: Does this run local-side (MCP/CodeTools), service-side (autocoder container), or either?
- **Inputs/outputs**: What data it needs from Minerva, what it produces back.
- **Dependencies**: Other tools, Docker images, system requirements.

### Skill Management UI

A dedicated surface (skill manager panel or preferences section) where the user can:
- Browse installed skills
- Install from source (URL, local path)
- Enable/disable skills (controls agent visibility)
- Configure skill parameters
- View/edit pipeline compositions
- Update or remove skills

---

## 4. The Supervisor

### What It Is

The supervisor is a **new concept in Minerva** — not a chat with extra features, but a fundamentally different mode of operation. Where a chat is reactive and conversational, the supervisor is goal-driven and persistent. It has a mission that outlives any single conversation turn.

The closest existing analogy is the autocoder session (session ID, persistent state across phases, stored in agent memory, progresses through a workflow), but the autocoder is a specific pipeline. The supervisor is a general-purpose orchestrator.

### The Clipboard-and-Eraser Model

The supervisor pattern was derived from observing how Claude Code functions as an executor when managing Minerva sessions:

- **Clipboard (persistent structured state)**: A todo/task list that survives context changes. This is the intent anchor — no matter how much context churns, the task list says what needs doing.
- **Eraser (compaction/selective forgetting)**: Aggressive context management. Summarize and store details before they're lost, then compact. This is *protective* against drift — a system that remembers everything weights old tangents equally with current goals.
- **Protected items (things the eraser can't touch)**: The intent document, task list, decision log. These are the ground truth the supervisor returns to.

### Supervisor Components

**Intent Document** *(protected, set at creation)*
The "why" — goals, constraints, success criteria. Created during a planning chat, then handed to the supervisor. The supervisor never overrides user-stated intent. Example: "Build a sensor board with ESP32, I2C sensors, BLE, from this BOM. PCB must have continuous ground plane under RF section."

**Task List** *(persistent, hierarchical, survives compaction)*
The "what" — tracks progress across steps. Hierarchical with awareness of intent level:
```
Build sensor board              (user intent — sacred)
├── Design PCB                  (derived, high-level)
│   ├── Research parts          (derived, tactical)
│   └── Route RF section        (derived, tactical)
├── Write firmware              (derived, high-level)
│   └── Initialize I2C sensors  (derived, detail)
└── Flash and test              (derived, high-level)
```
User-stated intent is sacred. Derived intent can be revised. Tactical items are disposable.

**Decision Journal** *(append-only, protected)*
The "why we chose how" — short records of decisions and rationale. Not detailed — just "chose ESP32 over STM32 because BLE stack is more mature." Protected from compaction because later steps may need to revisit earlier decisions.

**Cold Storage** *(proactive, searchable)*
The supervisor's extended mind. Before compaction, sweep active context and store anything that might matter later — intermediate results, failed approaches, environmental observations. Tagged and indexed for retrieval by relevance (vector search). The supervisor writes before it forgets and reads before it acts.

Backed by Minerva's storage service on the service bus (already supports state, documents, vector search). This represents Minerva using its own service infrastructure for itself — a meaningful architectural shift from Minerva's historically standalone design.

**Skill Registry** *(queryable)*
What skills are available, what they do, where they run. The supervisor consults this when deciding how to execute a step.

### Supervisor Behavior

The supervisor has a distinct identity/system prompt that establishes different behavioral priorities than a regular agent:

| Behavior | Regular Agent | Supervisor |
|----------|--------------|------------|
| Gets a task | Does the work | Decides who does the work |
| Encounters ambiguity | Best guess or asks user | Checks intent document, then decides or escalates |
| Context growing | Keeps going until limit | Proactively stores to cold storage, compacts early |
| Step completes | Reports result | Evaluates result against intent, updates tasks, dispatches next |
| Something unexpected | Reacts to it | Assesses impact on overall plan, adjusts if needed |
| Tool use | Uses tools directly | Dispatches scoped work packets to agents/skills |

### Scoped Dispatch

When the supervisor dispatches work to an agent or skill, it sends three things:
1. **The scoped task**: "Route traces for the RF section"
2. **Relevant context**: Retrieved from cold storage — board constraints, why the RF section matters
3. **Success criteria**: From the intent document — "traces must not cross, ground plane continuous under RF"

Sub-agents return two things:
1. **The result**: The routing output, build log, test results
2. **Structured signals**: Flags, warnings, observations that might affect the broader plan ("couldn't meet constraint X," "noticed Y," "recommend Z")

Sub-agents don't need to know they're talking to a supervisor. They need to know they should **report concerns, not just results**. This is a behavioral instruction in their dispatch prompt. The supervisor uses these signals to evaluate whether the step served the intent or whether the plan needs adjustment.

---

## 5. Execution Boundaries

### Two Boundaries

| Boundary | Protocol | What lives there | Example |
|----------|----------|-----------------|---------|
| **Service bus** (WebSocket) | Minerva message protocol | Autocoder orchestrator, review agents (at runtime), cloud services | Autocoder on AWS generates code |
| **Local/MCP** | MCP tool calls | CodeTools, cobrowser, PCB editor, Claude Code instances, local tools | CodeTools runs `pio build` locally |

### The Middle Ground

Review agents are defined locally in Minerva's UI but get shipped to the autocoder container to execute. Their definition crosses the boundary. This works for the autocoder's specific case but is a bespoke bridge, not a general pattern.

### How Skills Span Boundaries

A skill's manifest declares its **boundary affinity** (local, service-side, or either). The supervisor doesn't need to know the mechanics of each boundary — it dispatches to the skill, and the skill system routes to the correct executor:

- **Local skills**: Executed via MCP tools (CodeTools for scripts, or dedicated skill runner)
- **Service-side skills**: Executed via service bus messages (similar to how the autocoder orchestrates OpenCode)
- **Flexible skills**: Can run in either location; the skill system chooses based on availability and configuration

The supervisor orchestrates *what* happens. The skill system handles *where* it runs.

---

## 6. Minerva Architectural Implications

### Historical Context

Minerva is a **chat client that grew up**. It started as a standalone app talking REST to LLM providers. Everything since — the service bus, autocoder, agents, MCP tools, storage service — has been added organically as specific needs arose. Each addition solved a concrete problem:
- model-chat: Chat with ollama from a laptop without VRAM by bridging through AWS
- Autocoder: AI code generation with planning/review pipeline
- MCP tools: Local execution, browsing, editing capabilities

### The Shift

The supervisor pattern requires Minerva to **use its own service bus infrastructure for itself**. The storage service exists and works — but it serves downstream services, not Minerva the client. The supervisor needs Minerva to become a client of its own ecosystem:
- Storage service for cold storage (state, documents, vector search)
- Potentially agent memory for supervisor session state
- Service bus for dispatching to service-side skills

This is the biggest conceptual shift: Minerva the chat client becoming Minerva the platform that uses its own services.

### What's New vs. What Exists

| Component | Exists today? | What's needed |
|-----------|--------------|---------------|
| Chat/agent infrastructure | Yes | Supervisor mode/identity (new system prompt, different behavior) |
| MCP tool execution | Yes | Skill-aware dispatch (wrap skill invocation around existing CodeTools) |
| Service bus messaging | Yes | Skill dispatch protocol (new message types for skill invocation) |
| Storage service | Yes (for other services) | Minerva client integration (new — Minerva uses storage for itself) |
| Agent memory | Yes (autocoder uses it) | Supervisor session state (extend existing patterns) |
| Skill registry | No | New — skill manifest storage, discovery, lifecycle management |
| Skill manager UI | No | New — install/update/remove/compose interface |
| Supervisor mode | No | New — identity, intent management, context management, dispatch |
| Cold storage behavior | No | New — proactive write-before-forget, query-before-act patterns |

---

## 7. Open Questions

1. **Supervisor creation flow**: Does the user explicitly "start a supervisor session" from a planning chat, or does a chat naturally promote itself to supervisor mode when conditions are met (like a plan is finalized)?

2. **Supervisor lifetime**: Is a supervisor session bounded (one project, then done) or can it be long-lived (ongoing project management across days/weeks)?

3. **Multiple supervisors**: Can multiple supervisor sessions coexist (one for the PCB project, one for a web app project), or is there one active supervisor at a time?

4. **User interaction model**: How does the user interact with an active supervisor? Observe progress? Intervene? Override decisions? Pause/resume?

5. **Skill packaging format**: What does a skill manifest actually look like on disk? A directory with a manifest file? A git repo with conventions? A single config file?

6. **Skill discovery**: Can skills be discovered from a registry (like a package manager) or only installed from known sources?

7. **Failure recovery**: When a step fails and the supervisor has already compacted the detailed context around that step, how does it recover? Retrieve from cold storage? Ask the user? Re-run with more detail?

8. **Claude Code integration**: When Claude Code is available, should it register as a skill provider? Act as a supervisor peer? Or remain the informal "power user executor" role it plays today?
