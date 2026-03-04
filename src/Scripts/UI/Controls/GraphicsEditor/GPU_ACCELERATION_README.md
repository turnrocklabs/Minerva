# GPU Acceleration for Graphics Editor

This document describes the GPU compute shader optimizations implemented for the Minerva graphics editor stroke rendering.

## Overview

The graphics editor's drawing tools (brush, eraser) have been optimized using Godot 4's compute shaders to offload pixel-intensive operations from the CPU to the GPU. This can provide significant performance improvements, especially for:

- Large brush sizes
- High-resolution canvases
- Pressure-sensitive drawing with many stroke points
- Real-time drawing feedback

## Architecture

### Components

1. **Compute Shaders** (`.glsl` files)
   - `brush_stroke_compute.glsl` - Handles brush stroke rendering with anti-aliasing and alpha blending
   - `eraser_compute.glsl` - Optimized eraser operations

2. **GPU Renderer Classes** (`.gd` files)
   - `GPUBrushRenderer.gd` - Manages GPU resources for brush rendering
   - `GPUEraserRenderer.gd` - Manages GPU resources for eraser operations

3. **Modified Tools**
   - `DrawingTool.gd` - Enhanced with GPU acceleration option

### How It Works

#### CPU Path (Original)
```
User Input → GDScript Loop → Image.set_pixel() × N → Visual Update
```
- Each stroke point requires iteration over all pixels in the brush radius
- Uses `Image.get_pixel()` and `Image.set_pixel()` which are slow
- Alpha blending done in GDScript per-pixel

#### GPU Path (Optimized)
```
User Input → Upload Parameters → GPU Compute Shader → Download Result → Visual Update
```
- Parallel processing of all pixels in the brush simultaneously
- Hardware-accelerated alpha blending
- Stroke buffer prevents alpha accumulation within a single stroke
- Selection mask support for masked painting

## Features

### Brush Stroke Compute Shader

**Operations:**
- `STAMP` - Draw circular brush stamp with anti-aliasing
- `COMPOSITE` - Composite stroke buffer to final image
- `CLEAR` - Clear stroke buffer

**Features:**
- Anti-aliased circle rendering
- Pressure-sensitive brush size (handled by host)
- Alpha compositing with proper blending
- Selection mask support (packed bit array for efficiency)
- Stroke buffer to prevent alpha accumulation

### Eraser Compute Shader

**Features:**
- Anti-aliased circular eraser
- Multiplicative alpha reduction (preserves color, reduces opacity)
- Selection mask support
- Direct image modification (no separate stroke buffer needed)

## Performance Characteristics

### When GPU Acceleration Helps Most
- Brush radius > 20 pixels
- Canvas resolution > 1024×1024
- Many stroke points per second (fast drawing)
- Complex selection masks

### When CPU May Be Faster
- Very small brush sizes (< 5 pixels)
- Small canvas resolution (< 512×512)
- Single clicks or very short strokes
- GPU transfer overhead exceeds compute savings

## Usage

### Enabling GPU Acceleration

In `DrawingTool.gd`:
```gdscript
@export var use_gpu_acceleration: bool = true
```

Set this to `true` (default) to enable GPU acceleration, or `false` to use CPU rendering.

### Automatic Fallback

The system automatically falls back to CPU rendering if:
- GPU compute is not available
- Shader compilation fails
- Buffer initialization fails
- RenderingDevice creation fails

## Implementation Details

### Buffer Management

1. **Stroke Buffer** - RGBA8 texture storing brush coverage
2. **Layer Backup** - Copy of original layer for compositing
3. **Output Image** - Final composited result
4. **Parameters Buffer** - Structured buffer with brush parameters
5. **Selection Buffer** - Packed bit array (32 pixels per uint32)

### Shader Parameters

#### Brush Stroke
```glsl
struct BrushParams {
    vec4 brush_color;      // RGBA color
    vec2 center_position;  // Brush center in pixels
    float radius;          // Brush radius in pixels
    int operation;         // Operation type
    vec2 image_size;       // Canvas dimensions
    int use_selection;     // Selection mask enable
};
```

#### Eraser
```glsl
struct EraserParams {
    vec2 center_position;  // Eraser center in pixels
    float radius;          // Eraser radius in pixels
    int use_selection;     // Selection mask enable
    vec2 image_size;       // Canvas dimensions
};
```

### Memory Considerations

- Each canvas layer requires GPU textures when drawing
- Selection masks are uploaded once per stroke
- Buffers are freed immediately after stroke completes
- No persistent GPU memory between strokes

## Future Optimizations

Potential areas for further optimization:

1. **Persistent GPU Buffers** - Keep buffers alive between strokes
2. **Async Compute** - Non-blocking GPU operations
3. **Batch Drawing** - Multiple brush stamps per dispatch
4. **Smudge Tool** - GPU-accelerated pixel sampling and blending
5. **Bucket Fill** - GPU flood-fill algorithm
6. **Filter Effects** - Real-time GPU filters (blur, sharpen, etc.)

## Testing

### Validation

To verify GPU acceleration is working:

1. Enable debug logging in `GPUBrushRenderer._init()`:
   ```gdscript
   print("GPU Brush Renderer initialized successfully")
   ```

2. Check for fallback messages:
   ```
   "Failed to initialize GPU brush renderer, falling back to CPU"
   ```

3. Performance comparison:
   - Draw complex strokes with large brush sizes
   - Monitor frame time with Performance Monitor
   - Compare with `use_gpu_acceleration = false`

### Troubleshooting

**Problem:** Shader compilation errors
- **Solution:** Check shader syntax, ensure Godot 4.4+ compatibility

**Problem:** Black or corrupted output
- **Solution:** Verify buffer formats match (RGBA8), check blend modes

**Problem:** Selection mask not working
- **Solution:** Verify bit packing in `_build_selection_mask()`

**Problem:** Performance worse than CPU
- **Solution:** Disable GPU acceleration for small brushes/canvases

## Technical Requirements

- Godot 4.4 or later
- GPU with compute shader support (Vulkan/Metal/DirectX 12)
- Local RenderingDevice support

## References

- [Godot Compute Shaders Documentation](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html)
- [RenderingDevice Class Reference](https://docs.godotengine.org/en/stable/classes/class_renderingdevice.html)
