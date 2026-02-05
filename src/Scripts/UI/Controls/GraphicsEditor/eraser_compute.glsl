#[compute]
#version 450

// Local workgroup size (8x8 threads per workgroup)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input/Output image
layout(rgba8, set = 0, binding = 0) uniform restrict image2D layer_image;

// Eraser parameters
layout(set = 0, binding = 1, std430) buffer EraserParams {
    vec2 center_position;  // Center of eraser stamp
    float radius;          // Eraser radius
    int use_selection;     // Whether to respect selection
    vec2 image_size;       // Image dimensions
    float _padding[2];
} params;

// Selection mask (optional)
layout(set = 0, binding = 2, std430) buffer SelectionMask {
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

void main() {
    ivec2 pixel_pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 image_size = ivec2(params.image_size);
    
    // Bounds check
    if (pixel_pos.x >= image_size.x || pixel_pos.y >= image_size.y) {
        return;
    }
    
    // Check selection mask
    if (!is_pixel_selected(pixel_pos)) {
        return;
    }
    
    // Calculate alpha factor based on distance from center
    float erase_factor = circle_alpha(vec2(pixel_pos), params.center_position, params.radius);
    
    if (erase_factor <= 0.01) {
        return;
    }
    
    // Read existing pixel
    vec4 existing = imageLoad(layer_image, pixel_pos);
    
    // Reduce alpha based on erase factor
    existing.a *= (1.0 - erase_factor);
    
    // Write back
    imageStore(layer_image, pixel_pos, existing);
}
