---
name: pcb-maker
description: Load a PCB board from YAML into Minerva with accurate KiCAD geometry. Use when importing boards to Minerva from pcb-architect YAML files.
argument-hint: "[yaml-file-path]"
---

## Overview
This skill acts as the bridge between a YAML-based board description and Minerva's visual PCB editor. It doesn't just "draw boxes"—it uses the `pcb-architect` toolset to extract precise pad locations, drill sizes, and body dimensions from KiCAD footprint libraries to ensure the visual representation is 1:1 with the final manufactured board.


## Prerequisites
1. **Docker:** The `pcb-architect` docker image must be available.
2. **Library Access:** If using specialized components (e.g., ESP32), the corresponding KiCAD library path must be known to mount as a volume.
3. **Volume Mounting:** All `pcb-architect` commands must mount the project directory to `/work`.
4. **Minerva:** The "Minerva" mcp server must be available with the minerva* tools available.

---

## pcb-architect Command Reference

All commands run via Docker: `docker run -v $(pwd):/work pcb-architect <command> [args]`

For ESP32/Espressif boards, always add: `-v ~/github/espressif-kicad-libraries:/espressif:ro` and `--lib-path /espressif/footprints`

| Command | Purpose | Key Flags |
|---------|---------|-----------|
| `init <file.yaml>` | Create a template board YAML | |
| `validate <file.yaml>` | Validate board definition | `--check-libs` (also verify footprint/symbol refs) |
| `libraries` | List available KiCAD libraries | `--type footprints`, `--library <name> --list-parts` |
| `check-libs <bom.yaml>` | Check BOM against libraries | `--json`, `--lib-path` |
| `generate <file.yaml>` | Generate .kicad_pcb/.sch/.pro | `--force`, `--embed`, `--no-ratsnest`, `--lib-path` |
| `footprint-geometry <file.yaml>` | Export pad geometry JSON | `--component U1,C1`, `--summary`, `--compact`, `-o file.json` |
| `trace-geometry <file.kicad_pcb>` | Export traces/vias JSON | `--net VCC,GND`, `--component U1`, `--board-yaml`, `--summary`, `--compact` |
| `route <file.kicad_pcb>` | Autoroute via Freerouting | `--single-layer`, `--passes N`, `--timeout N`, `--keep-intermediate` |
| `drc <file.kicad_pcb>` | Design rule check | `--output report.json` |
| `export-pdf <file.kicad_pcb>` | Export PDF preview | `-o file.pdf`, `--color` |
| `sync-positions <yaml> <pcb>` | Sync KiCad positions back to YAML | `--dry-run` |
| `gerbers <file.kicad_pcb>` | Generate Gerber files | `-o /work/gerbers/` |
| `pipeline <file.yaml>` | Full pipeline (generate+route+gerbers) | `--skip-route`, `--skip-gerbers` |

### Reducing Token Cost
`footprint-geometry` and `trace-geometry` support filtering to minimize output size:
- `--component U1,C1` — only specific components/nets
- `--summary` — bounding boxes only, no pad/trace arrays
- `--compact` — no JSON indentation (~40% smaller)
- Combine all three for minimal output

---

## Core Workflow

### Phase 1: File Discovery & Initialization
If no path is provided, you must locate the source of truth:
1. **Intent:** ask the user their intention (make a new board? load an existing board? If so, where is the YML?).
2. **Search:** If existing board, look for `eda/`, `pcb/`, `hardware/`, or the root directory for `.yaml` files.
3. **Validate:** Confirm the file contains `outline`, `components`, and `nets`. Optionally run:
   ```bash
   docker run -v $(pwd):/work pcb-architect validate /work/board.yaml --check-libs
   ```
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

### Adding New Components
If the user wants to add a component (e.g., "Add a USB-C port"):
1. **Find the footprint:** Use `libraries` to discover available parts:
   ```bash
   docker run -v $(pwd):/work pcb-architect libraries --type footprints
   docker run -v $(pwd):/work pcb-architect libraries --library Connector_USB --list-parts
   ```
2. **Update YAML:** Add the component and relevant nets to the `.yaml` file.
3. **Validate:** `docker run -v $(pwd):/work pcb-architect validate /work/board.yaml --check-libs`
4. **Regenerate KiCAD:** `docker run -v $(pwd):/work pcb-architect generate /work/board.yaml -o /work/output/ --force`
5. **Refresh Minerva:** Re-run the `pcb-from-yaml` workflow to sync changes.

### Using Placement Hints
Components can include placement hints for auto-placement in the YAML:
```yaml
placement:
  near: [U1, U2]          # Place near these components
  edge: top               # Place at board edge (top/bottom/left/right/center/top_left/top_right/bottom_left/bottom_right)
  min_distance: 1.0       # Minimum distance from other components (mm)
  max_distance: 5.0       # Maximum distance from 'near' components (mm)
  group: power_section    # Components with same group stay together
  align_x: C1             # Align X coordinate with C1
  align_y: C2             # Align Y coordinate with C2
```
This is useful for decoupling caps (`near: [U1]`, `max_distance: 3`), edge connectors (`edge: top`), and grouping related components (`group: power_section`).

### Syncing Manual Layout Changes
If the user manually moves components in the Minerva UI or KiCAD:
1. **Sync Back:** Run `docker run -v $(pwd):/work pcb-architect sync-positions /work/board.yaml /work/output/board.kicad_pcb`
2. **Preview first:** Add `--dry-run` to see what would change before committing.
3. This ensures the YAML (the source of truth) matches the visual layout.

### Manual Placement in KiCad
For complex boards where manual placement in KiCad is preferred:
1. **Generate without ratsnest:** `docker run -v $(pwd):/work pcb-architect generate /work/board.yaml -o /work/output/ --force --no-ratsnest`
2. **Open in KiCad** and manually place/rotate components (KiCad shows the real ratsnest as you work).
3. **Sync back:** `docker run -v $(pwd):/work pcb-architect sync-positions /work/board.yaml /work/output/board.kicad_pcb`
4. **Regenerate:** `docker run -v $(pwd):/work pcb-architect generate /work/board.yaml -o /work/output/ --force`

### Finalizing for Manufacturing
Once the layout is approved in Minerva:

**Option A — Step by step:**
1. **Auto-Route:** `docker run -v $(pwd):/work pcb-architect route /work/output/board.kicad_pcb`
   - For single-layer boards: add `--single-layer` (prefers F.Cu only; vias may still appear if needed)
   - For complex designs: `--passes 50 --timeout 900 -v` for more attempts
2. **DRC:** `docker run -v $(pwd):/work pcb-architect drc /work/output/board_routed.kicad_pcb --output /work/output/drc.json`
3. **Export PDF Preview:** `docker run -v $(pwd):/work pcb-architect export-pdf /work/output/board_routed.kicad_pcb -o /work/output/preview.pdf --color`
4. **Generate Gerbers:** `docker run -v $(pwd):/work pcb-architect gerbers /work/output/board_routed.kicad_pcb -o /work/output/gerbers/`

**Option B — Full pipeline (one command):**
```bash
docker run -v $(pwd):/work pcb-architect pipeline /work/board.yaml -o /work/output/
```
This runs generate → route → gerbers in sequence. Use `--skip-route` or `--skip-gerbers` to skip steps.

### Importing Routed Traces into Minerva
After autorouting, you can visualize the traces in Minerva:
1. **Export trace geometry:**
   ```bash
   docker run -v $(pwd):/work pcb-architect trace-geometry /work/output/board_routed.kicad_pcb -o /work/traces.json
   ```
   Use filtering to reduce output size: `--net VCC,GND` or `--component U1 --board-yaml /work/board.yaml`
2. **Import into Minerva:** Read `traces.json` and call `minerva_pcb_import_trace_geometry(editor_name, trace_data)`.

### Verifying Pin Positions
Use `minerva_pcb_get_pin_position` to check a pin's world coordinates before creating route hints. On error (pin not found), it returns `available_pins` so you can self-correct.

---

## Board YAML Format Reference

```yaml
name: my-board
version: "1.0"
description: "Board description"
author: "Your Name"

outline:
  width: 50      # mm
  height: 50     # mm
  corner_radius: 2

layers: 2  # 1, 2, 4, 6, or 8

components:
  - id: U1
    part: MCU
    value: ESP32-S3
    footprint: RF_Module:ESP32-S3-WROOM-1
    symbol_lib: RF_Module:ESP32-S3-WROOM-1
    position:
      x: 25
      y: 25
      rotation: 0
      layer: F.Cu
    placement:          # Optional placement hints
      edge: center
      group: main_mcu
    pins:
      GPIO8: '12'       # symbolic: 'pad_number'
      VCC: '2'

  - id: C1
    part: C
    value: 100nF
    footprint: Capacitor_SMD:C_0402_1005Metric
    symbol_lib: Device:C
    placement:
      near: [U1]
      max_distance: 3
      group: decoupling

nets:
  - name: VCC
    pins:
      - U1.VCC
      - C1.1
  - name: GND
    pins:
      - U1.GND
      - C1.2

constraints:
  trace_width: 0.25       # Default trace width (mm)
  clearance: 0.2          # Copper clearance
  via_diameter: 0.8
  via_drill: 0.4
  diff_pair_gap: 0.15
  diff_pair_width: 0.2
```

---

## Verification Checklist
- [ ] Do SMD components show surface pads (no drill holes) after geometry import?
- [ ] Are horizontal connectors (like USB or JST) oriented correctly relative to the board edge?
- [ ] Are the `VCC` and `GND` nets visible in the ratsnest?
- [ ] Does the board outline in Minerva match the `width` and `height` specified in the YAML?
- [ ] Is the ratsnest showing pin-to-pin connections (not star patterns)?
- [ ] Are component positions unchanged after geometry import?

## Tips for Success
- **Start simple**: Begin with fewer components, add complexity gradually.
- **Use explicit positions**: For fine-tuning, use `position: {x, y, rotation}` instead of `placement` constraints.
- **Use --no-ratsnest**: When manually placing in KiCad, skip the static ratsnest lines.
- **Sync positions**: After manual placement, use `sync-positions` to save your work.
- **Board size matters**: Dense designs (ESP32 + USB-C) may need larger boards or 4 layers.
- **Single-layer boards**: Use `--single-layer` with route. If vias still appear, spread components or use 0-ohm jumpers.
- **Iterate quickly**: The generate → export-pdf → review loop is fast.
- **Validate early**: Run `validate --check-libs` before generating to catch missing footprints.
- **Use DRC**: Run `drc` after routing to catch clearance violations before manufacturing.

## Examples

**Command:** `/pcb-maker eda/main_board.yaml`
**Action:** Loads the specified file, extracts geometry via Docker, and populates the Minerva PCB editor.

**Command:** `/pcb-maker`
**Action:** Searches for YAML files. If `sensor_v1.yaml` is found, it asks: "I found sensor_v1.yaml in the root. Should I load this into the PCB editor?"
