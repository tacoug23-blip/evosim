// One u8 world layer stored as an R8 texture, one texel per cell.
// mode 0: the value is an index into `palette` (e.g. substrate id -> color).
// mode 1: the value 0..1 maps onto ramp_low -> ramp_high.
shader_type canvas_item;

uniform int mode = 0;
uniform sampler2D palette : filter_nearest;
uniform vec4 ramp_low : source_color = vec4(0.0);
uniform vec4 ramp_high : source_color = vec4(1.0);
uniform float opacity = 1.0;
uniform vec2 cells = vec2(4096.0);

uniform int max_taps = 4;
const float PALETTE_SIZE = 256.0;

vec4 shade(float v) {
	if (mode == 0) {
		return textureLod(palette, vec2((v * 255.0 + 0.5) / PALETTE_SIZE, 0.5), 0.0);
	}
	return mix(ramp_low, ramp_high, v);
}

void fragment() {
	// Zoomed out, one screen pixel covers several cells. Average an n x n grid of samples
	// across the pixel footprint rather than point-sampling one cell, so panning does not
	// shimmer. Zoomed in, n = 1 and this is a plain nearest lookup.
	vec2 duv = fwidth(UV);
	float span = max(duv.x * cells.x, duv.y * cells.y);
	int n = int(clamp(ceil(span), 1.0, float(max_taps)));
	vec4 acc = vec4(0.0);
	for (int j = 0; j < n; j++) {
		for (int i = 0; i < n; i++) {
			vec2 o = (vec2(float(i), float(j)) + 0.5) / float(n) - 0.5;
			acc += shade(textureLod(TEXTURE, UV + o * duv, 0.0).r);
		}
	}
	COLOR = acc / float(n * n);
	COLOR.a *= opacity;
}
