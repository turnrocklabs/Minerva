# OBS Controller Plugin

Controls OBS Studio from Minerva via WebSocket. Lets you and LLMs switch scenes, position the webcam overlay, and manage recordings.

## Quick Start

1. **Start OBS Studio** with WebSocket server enabled (Tools > WebSocket Server Settings > Enable)
2. **Connect**: `minerva_obs_controller_connect` (defaults to localhost:4455, pass `password` if set)
3. **Check status**: `minerva_obs_controller_get_status` — always works, shows connection state

## Configuring the Camera

Before using `set_camera_position`, you need to tell the plugin which OBS source is your webcam:

1. `minerva_obs_controller_list_sources` — shows all sources in the current scene with their names
2. `minerva_obs_controller_configure` with `camera_source` set to the webcam source name (e.g., "Brio", "Webcam", "Video Capture Device")
3. Now `minerva_obs_controller_set_camera_position` will work

## Camera Positioning (Semantic Grid)

Instead of pixel coordinates, use a 3x3 grid:

- **row**: `top`, `middle`, `bottom`
- **column**: `left`, `center`, `right`
- **size**: `small` (15%), `medium` (25%, default), `large` (35%)

Example: `set_camera_position({row: "bottom", column: "right", size: "medium"})` puts the webcam overlay in the bottom-right corner at 25% of canvas width.

## Scene Management

- `minerva_obs_controller_list_scenes` — get all scene names and which is current
- `minerva_obs_controller_switch_scene` with `scene` — switch to a named scene

## Recording

- `minerva_obs_controller_start_recording` — starts OBS recording
- `minerva_obs_controller_stop_recording` — stops recording, returns the output file path
- `minerva_obs_controller_list_recordings` — lists video files in the output directory (newest first)

## Configuration

`minerva_obs_controller_configure` saves settings to disk. Fields:

- `obs_host` (default: "localhost")
- `obs_port` (default: 4455)
- `obs_password` — OBS WebSocket password
- `camera_source` — name of the webcam source in OBS (required for camera positioning)
- `output_directory` — where OBS saves recordings (auto-detected from OBS if empty)
- `auto_connect` (default: true) — connect to OBS automatically when the plugin starts

## Live State

The plugin pushes state updates to Minerva whenever something changes (scene switch, recording start/stop, camera move). Query with `minerva_plugin_state({id: "obs_controller"})`.

State shape:
```json
{
  "connected": true,
  "scene": "Pip-screen",
  "recording": false,
  "camera": {"row": "bottom", "column": "right", "size": "medium"}
}
```

## Common Workflows

**"Set up for a talking-head recording":**
1. `connect` → `list_sources` → `configure` camera_source
2. `switch_scene` to your pip scene
3. `set_camera_position` bottom-right medium
4. `start_recording`

**"Move camera out of the way for a demo":**
1. `set_camera_position` top-left small

**"Switch to fullscreen and back":**
1. `switch_scene` to "DesktopOnly" (or your fullscreen scene name)
2. When done: `switch_scene` back to your pip scene
