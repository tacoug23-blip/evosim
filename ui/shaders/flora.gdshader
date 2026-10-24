// Flora: type_tex = flora_type (R8, one texel per cell), biomass_tex = flora_biomass (R8).
// (The sprite texture is the same type texture; it only sizes the quad.)
// palette: rgb = type color, a = max_biomass / 255. Opacity rises with biomass relative to
// the type's max; empty cells are transparent. season_tint.a blends toward season_tint.rgb.
shader_type canvas_item;

uniform sampler2D type_tex : filter_nearest;
uniform sampler2D biomass_tex : filter_nearest;
uniform sampler2D palette : filter_nearest;
uniform vec2 cells = vec2(4096.0);
uniform int max_taps = 4;
uniform float opacity = 0.9;
uniform vec4 season_tint = vec4(1.0, 1.0, 1.0, 0.0);

const float PALETTE_SIZE = 256.0;
// Even a seedling shows at this share of full opacity.
const float MIN_FILL = 0.25;

vec4 plant(vec2 uv) {
	float t = textureLod(type_tex, uv, 0.0).r;
	if (t < 0.5 / 255.0) {
		return vec4(0.0);
	}
	vec4 p = textureLod(palette, vec2((t * 255.0 + 0.5) / PALETTE_SIZE, 0.5), 0.0);
	float fill = clamp(textureLod(biomass_tex, uv, 0.0).r / max(p.a, 1.0 / 255.0), 0.0, 1.0);
	vec3 rgb = mix(p.rgb, season_tint.rgb, season_tint.a);
	float a = opacity * mix(MIN_FILL, 1.0, fill);
	return vec4(rgb * a, a);  // premultiplied, so averaging empty and full cells blends right
}

void fragment() {
	vec2 duv = fwidth(UV);
	float span = max(duv.x * cells.x, duv.y * cells.y);
	int n = int(clamp(ceil(span), 1.0, float(max_taps)));
	vec4 acc = vec4(0.0);
	for (int j = 0; j < n; j++) {
		for (int i = 0; i < n; i++) {
			vec2 o = (vec2(float(i), float(j)) + 0.5) / float(n) - 0.5;
			acc += plant(UV + o * duv);
		}
	}
	acc /= float(n * n);
	COLOR = acc.a > 0.0 ? vec4(acc.rgb / acc.a, acc.a) : vec4(0.0);
}
