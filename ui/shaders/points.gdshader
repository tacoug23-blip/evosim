// Entity points. Vertex i reads its cell from pos_x / pos_y: RGBA8 textures holding the raw
// little-endian int32 coordinate arrays, one texel per entity. Negative x hides the point.
shader_type canvas_item;

uniform sampler2D pos_x : filter_nearest;
uniform sampler2D pos_y : filter_nearest;
uniform int tex_width = 2048;
uniform float point_px = 2.0;
uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.65, 1.0);

int decode(vec4 texel) {
	ivec4 b = ivec4(round(texel * 255.0));
	return b.r | (b.g << 8) | (b.b << 16) | (b.a << 24);
}

void vertex() {
	ivec2 tc = ivec2(VERTEX_ID % tex_width, VERTEX_ID / tex_width);
	int cx = decode(texelFetch(pos_x, tc, 0));
	int cy = decode(texelFetch(pos_y, tc, 0));
	VERTEX = cx < 0 ? vec2(-1.0e7) : vec2(float(cx), float(cy)) + 0.5;
	POINT_SIZE = point_px;
}

void fragment() {
	COLOR = tint;
}
