---
name: pcb-maker
description: Load a PCB board from YAML into Minerva with accurate KiCAD geometry. Use when importing boards to Minerva from pcb-architect YAML files.
argument-hint: "[yaml-file-path]"
---

## Overview
This skill acts as the bridge between a YAML-based board description and Minerva’s visual PCB editor. It doesn't just "draw boxes"—it uses the `pcb-architect` toolset to extract precise pad locations, drill sizes, and body dimensions from KiCAD footprint libraries to ensure the visual representation is 1:1 with the final manufactured board.


## Prerequisites
1. **Docker:** The `pcb-architect` docker image must be available.
2. **Library Access:** If using specialized components (e.g., ESP32), the corresponding KiCAD library path must be known to mount as a volume.
3. **Volume Mounting:** All `pcb-architect` commands must mount the project directory to `/work`.
4. **Minerva:** The "Minerva" mcp server must be available with the minerva* tools available.

---

## Core Workflow

### Phase 1: File Discovery & Initialization
If no path is provided, you must locate the source of truth:
1. ** Intent:** ask the user their intention (make a new board? load an existing board? If so, where is the YML?).
2. **Search:** If existing board, look for `eda/`, `pcb/`, `hardware/`, or the root directory for `.yaml` files.
3. **Validate:** Confirm the file contains `outline`, `components`, and `nets`.
4. **If Missing:** If no YAML exists, switch to the **"PCB From Scratch"** workflow:
   - Ask for requirements (MCU, sensors, connectors, dimensions).
   - Use `docker run -v $(pwd):/work pcb-architect init /work/board.yaml` to create a template.
   - Edit the template based on the user's requirements before proceeding.

### Phase 2: Minerva Editor Initialization
1. **Read Dimensions:** Extract `width` and `height` from the `outline` section.
2. **Create Editor:** Call `minerva_create_pcb_editor(name, width, height)`.

### Phase 3: Component Mapping & Initial Placement
Iterate through the `components` list in the YAML. You must map KiCAD footprint names to Minerva's internal component types for proper rendering:
- **Pin Headers/Sockets:** `Connector_PinHeader_*` or `Connector_PinSocket_*` → `HEADER`
- **DIP ICs:** `Package_DIP:*` → `IC_DIP`
- **Surface Mount:** `*_SMD:*` or `*_SMT:*` → Select appropriate `SMD` type.
- **Buttons:** `Button_Switch_*` → `SWITCH`
- **Modules:** `ESP32*`, `Ams_Radio:*`, etc. → `MODULE`
- **Mechanical:** `MountingHole:*` → `MOUNTING_HOLE`

**Tool Call:** `minerva_pcb_add_component(editor_name, id, footprint, x, y, rotation, pin_count, pin_names, value)`

> **IMPORTANT:** Do NOT pass symbolic `pin_names` to components. The geometry import will provide pad data with numerical IDs from KiCAD. Symbolic names will cause net/pad mismatch and break pin-to-pin ratsnest display.

### Phase 4: Netlist Synchronization
Extract the `nets` section and establish logical connections.

> **CRITICAL - Use Numerical Pin IDs:** The YAML `pins` section maps symbolic names to numerical IDs:
> ```yaml
> pins:
>   GPIO8: '12'   # Use '12', not 'GPIO8'
>   VCC: '2'      # Use '2', not 'VCC'
> ```
> When calling `minerva_pcb_connect_net`, always use the **numerical value** (right side), not the symbolic key (left side). Using symbolic names will cause the ratsnest to show star patterns instead of pin-to-pin connections.

- **Tool Call:** `minerva_pcb_connect_net(editor_name, net_name, pins)`

### Phase 5: Geometric Precision (Critical Step)
Minerva's default footprints are placeholders. You **must** run the `footprint-geometry` command to fetch real dimensions from KiCAD libraries.

1. **Execute Docker Command:**
   ```bash
   docker run -v $(pwd):/work pcb-architect footprint-geometry /work/board.yaml -o /work/geometry.json
   ```
   *Note: If ESP32 libraries are used, add: `-v ~/github/espressif-kicad-libraries:/espressif:ro --lib-path /espressif/footprints`*

2. **Import Data:** Read `geometry.json` and pass the data to Minerva.
   - **Tool Call:** `minerva_pcb_import_footprint_geometry(editor_name, geometry_data)`

> **Pin Names:** The geometry export includes symbolic pin names from the YAML's `pins:` section (e.g., `"name": "3V3"` for pad number "1"). These are used by Minerva's Select Pin tool to display meaningful labels instead of just pad numbers.

> **WARNING:** Do NOT use `position_is_center: true`. pcb-architect YAML positions are footprint origins (pin 1 location), not geometric centers. Using this flag will shift component positions incorrectly.

---

## Prescriptive Instructions for Modification

### Adding New Componentsf
If the user wants to add a component (e.g., "Add a USB-C port"):
1. **Update YAML:** Add the component and relevant nets to the `.yaml` file.
2. **Regenerate KiCAD:** `docker run -v $(pwd):/work pcb-architect generate /work/board.yaml -o /work/output/ --force`.
3. **Refresh Minerva:** Re-run the `pcb-from-yaml` workflow to sync changes.

### Syncing Manual Layout Changes
If the user manually moves components in the Minerva UI or KiCAD:
1. **Sync Back:** Run `docker run -v $(pwd):/work pcb-architect sync-positions /work/board.yaml /work/output/board.kicad_pcb`.
2. This ensures the YAML (the source of truth) matches the visual layout.

### Finalizing for Manufacturing
Once the layout is approved in Minerva:
1. **Auto-Route:** `docker run -v $(pwd):/work pcb-architect route /work/output/board.kicad_pcb`.
2. **Export PDF Preview:** `docker run -v $(pwd):/work pcb-architect export-pdf /work/output/board_routed.kicad_pcb -o /work/output/preview.pdf --color`.
3. **Generate Gerbers:** `docker run -v $(pwd):/work pcb-architect gerbers /work/output/board_routed.kicad_pcb -o /work/output/gerbers/`.

---

## Verification Checklist
- [ ] Do SMD components show surface pads (no drill holes) after geometry import?
- [ ] Are horizontal connectors (like USB or JST) oriented correctly relative to the board edge?
- [ ] Are the `VCC` and `GND` nets visible in the ratsnest?
- [ ] Does the board outline in Minerva match the `width` and `height` specified in the YAML?
- [ ] Is the ratsnest showing pin-to-pin connections (not star patterns)?
- [ ] Are component positions unchanged after geometry import?

## Examples

**Command:** `/pcb-from-yaml eda/main_board.yaml`
**Action:** Loads the specified file, extracts geometry via Docker, and populates the Minerva PCB editor.

**Command:** `/pcb-from-yaml`
**Action:** Searches for YAML files. If `sensor_v1.yaml` is found, it asks: "I found sensor_v1.yaml in the root. Should I load this into the PCB editor?"