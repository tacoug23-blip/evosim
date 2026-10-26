// Entity points. Vertex i (= entity slot) reads its cell and energy from RGBA8 textures holding
// the raw little-endian int32 slot arrays, and its sex from an R8 texture; one texel per slot.
// Negative x (dead slot) hides the point.
shader_type canvas_item;

uniform sampler2D entity_x : filter_nearest;
uniform sampler2D entity_y : filter_nearest;
uniform sampler2D entity_energy : filter_nearest;
uniform sampler2D entity_max_energy : filter_nearest;
uniform sampler2D entity_sex : filter_nearest;
uniform int tex_width = 2048;
uniform float point_px = 2.0;
// 0 = energy (red -> yellow -> green), 1 = sex (male blue, female pink).
uniform int color_mode = 0;
uniform vec4 low_energy : source_color = vec4(0.9, 0.15, 0.1, 1.0);
uniform vec4 mid_energy : source_color = vec4(0.98, 0.85, 0.2, 1.0);
uniform vec4 high_energy : source_color = vec4(0.25, 0.95, 0.35, 1.0);
uniform vec4 male_color : source_color = vec4(0.3, 0.6, 1.0, 1.0);
uniform vec4 female_color : source_color = vec4(1.0, 0.35, 0.75, 1.0);

varying vec4 point_color;

int decode(vec4 texel) {
	ivec4 b = ivec4(round(texel * 255.0));
	return b.r | (b.g << 8) | (b.b << 16) | (b.a << 24);
}

void vertex() {
	ivec2 tc = ivec2(VERTEX_ID % tex_width, VERTEX_ID / tex_width);
	int cx = decode(texelFetch(entity_x, tc, 0));
	int cy = decode(texelFetch(entity_y, tc, 0));
	VERTEX = cx < 0 ? vec2(-1.0e7) : vec2(float(cx), float(cy)) + 0.5;
	POINT_SIZE = point_px;
	if (color_mode == 1) {
		// The R8 texel holds the raw byte (0 male, 1 female), normalised to 0..1.
		point_color = texelFetch(entity_sex, tc, 0).r * 255.0 > 0.5 ? female_color : male_color;
	} else {
		float e = float(decode(texelFetch(entity_energy, tc, 0)));
		float m = max(1.0, float(decode(texelFetch(entity_max_energy, tc, 0))));
		float f = clamp(e / m, 0.0, 1.0);
		point_color = f < 0.5 ? mix(low_energy, mid_energy, f * 2.0) : mix(mid_energy, high_energy, f * 2.0 - 1.0);
	}
}

void fragment() {
	COLOR = point_color;
}
