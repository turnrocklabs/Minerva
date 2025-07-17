shader_type canvas_item;

uniform float square_size : hint_range(0.01, 0.5) = 0.05;
uniform vec4 color1 : source_color = vec4(0.585, 0.585, 0.585, 1);
uniform vec4 color2 : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	// Work directly with pixel coordinates to ensure square proportions
	vec2 pixel_pos = FRAGCOORD.xy;

	// Convert square_size from UV space to pixel space
	float pixel_square_size = square_size * 100.0; // Adjust this multiplier as needed

	// Offset to align grid to top-left corner
	// FRAGCOORD origin is bottom-left, but we want top-left alignment
	vec2 control_size = 1.0 / TEXTURE_PIXEL_SIZE;
	pixel_pos.y = control_size.y - pixel_pos.y; // Flip Y to start from top

	// Create grid based on pixel coordinates, starting from (0,0)
	vec2 grid = floor(pixel_pos / pixel_square_size);

	// Create checkerboard pattern
	float checker = mod(grid.x + grid.y, 2.0);

	// Mix colors based on checker value
	COLOR = mix(color1, color2, checker);
}