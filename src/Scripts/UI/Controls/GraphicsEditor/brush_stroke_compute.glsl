#[compute]
#version 450

// Local workgroup size (8x8 threads per workgroup)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/Output image buffers
layout(rgba8, set = 0, binding = 0) uniform restrict image2D stroke_buffer;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image2D layer_backup;
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D output_image;

// Brush stroke parameters
layout(set = 0, binding = 3, std430) buffer BrushParams {
    vec4 brush_color;      // Brush color with alpha
    vec2 center_position;  // Center of brush stamp
    float radius;          // Brush radius
    int operation;         // 0=stamp, 1=composite, 2=clear
    vec2 image_size;       // Image dimensions
    int use_selection;     // Whether to respect selection
    float _padding;
} params;

// Selection mask (optional)
layout(set = 0, binding = 4, std430) buffer SelectionMask {
    uint selection_data[];  // Packed bits: 32 pixels per uint
} selection;

// Check if pixel is selected
bool is_pixel_selected(ivec2 pos) {
    if (params.use_selection == 0) return true;
    
    int pixel_index = pos.y * int(params.image_size.x) + pos.x;
    int uint_index = pixel_index / 32;
    int bit_index = pixel_index % 32;
    
    uint mask_value = selection.selection_data[uint_index];
    return ((mask_value >> bit_index) & 1u) == 1u;
}

// Calculate alpha for antialiased circle
float circle_alpha(vec2 pos, vec2 center, float radius) {
    float dist = distance(pos, center);
    
    if (dist > radius) {
        return 0.0;
    }
    
    // Antialiasing: smooth edge over 1 pixel
    if (dist > radius - 1.0) {
        return 1.0 - (dist - (radius - 1.0));
    }
    
    return 1.0;
}

// Blend colors using alpha compositing
vec4 blend_colors(vec4 bottom, vec4 top) {
    if (top.a >= 0.99) {
        return top;
    }
    if (top.a <= 0.01) {
        return bottom;
    }
    
    float one_minus_top_a = 1.0 - top.a;
    float bottom_factor = bottom.a * one_minus_top_a;
    float a = 1.0 - one_minus_top_a * (1.0 - bottom.a);
    
    if (a < 0.01) {
        return vec4(0.0);
    }
    
    float inv_a = 1.0 / a;
    vec3 rgb = (top.rgb * top.a + bottom.rgb * bottom_factor) * inv_a;
    
    return vec4(rgb, a);
}

void main() {
    ivec2 pixel_pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = ivec2(params.image_size);
    
    // Bounds check
    if (pixel_pos.x >= image_size.x || pixel_pos.y >= image_size.y) {
        return;
    }
    
    // Operation 0: Brush stamp
    if (params.operation == 0) {
        // Check selection mask
        if (!is_pixel_selected(pixel_pos)) {
            return;
        }
        
        // Calculate alpha factor based on distance from center
        float alpha_factor = circle_alpha(vec2(pixel_pos), params.center_position, params.radius);
        
        if (alpha_factor <= 0.01) {
            return;
        }
        
        // Read existing pixel from stroke buffer
        vec4 existing = imageLoad(stroke_buffer, pixel_pos);
        
        // Use MAX alpha to prevent accumulation within stroke
        float stamp_alpha = params.brush_color.a * alpha_factor;
        if (stamp_alpha > existing.a) {
            // Store coverage alpha (use white placeholder)
            imageStore(stroke_buffer, pixel_pos, vec4(1.0, 1.0, 1.0, stamp_alpha));
        }
    }
    // Operation 1: Composite stroke buffer to output
    else if (params.operation == 1) {
        vec4 buffer_pixel = imageLoad(stroke_buffer, pixel_pos);
        
        if (buffer_pixel.a > 0.01) {
            // Apply brush color with stored alpha
            vec4 stroke_color = params.brush_color;
            stroke_color.a *= buffer_pixel.a;
            
            // Blend with backup layer
            vec4 existing_color = imageLoad(layer_backup, pixel_pos);
            vec4 blended = blend_colors(existing_color, stroke_color);
            
            imageStore(output_image, pixel_pos, blended);
        } else {
            // No stroke here, copy from backup
            vec4 backup_color = imageLoad(layer_backup, pixel_pos);
            imageStore(output_image, pixel_pos, backup_color);
        }
    }
    // Operation 2: Clear stroke buffer
    else if (params.operation == 2) {
        imageStore(stroke_buffer, pixel_pos, vec4(0.0));
    }
}
