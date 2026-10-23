## Seeded procedural terrain: elevation + moisture noise -> substrate, moisture, fertility.
##
## Noise images come from FastNoiseLite (native, normalized to 0..255). Each output layer is a
## pure function of (elevation byte, moisture byte), so we precompute three 64K-entry lookup
## tables and do a single pass over the map. That keeps the GDScript per-cell work to three
## table reads, which matters at 16.7M cells.
extends RefCounted

const Registry := preload("res://sim/params/registry.gd")
const Rng := preload("res://sim/core/rng.gd")
const Substrates := preload("res://sim/world/substrates.gd")
const World := preload("res://sim/world/world.gd")

const STREAM := "terrain"
const BYTE_MAX := 255


## Fills world.substrate, world.moisture, world.fertility. Returns stats for logging/tests.
static func generate(world: World, params: Registry, rngs: Rng,
		subs: Substrates) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var rng: RandomNumberGenerator = rngs.stream(STREAM)
	var longest := maxi(world.width, world.height)
	# Mask to 31 bits: FastNoiseLite seeds are 32-bit signed.
	var elev := _noise_bytes(rng.randi() & 0x7FFFFFFF, params, "terrain.elevation", longest,
			world.width, world.height)
	var moist := _noise_bytes(rng.randi() & 0x7FFFFFFF, params, "terrain.moisture", longest,
			world.width, world.height)
	var t_noise := Time.get_ticks_usec()

	var luts := build_luts(params, subs)
	var lut_sub: PackedByteArray = luts[0]
	var lut_moist: PackedByteArray = luts[1]
	var lut_fert: PackedByteArray = luts[2]

	var sub: PackedByteArray = world.substrate
	var mo: PackedByteArray = world.moisture
	var fe: PackedByteArray = world.fertility
	for i in world.cell_count:
		var k := (elev[i] << 8) | moist[i]
		sub[i] = lut_sub[k]
		mo[i] = lut_moist[k]
		fe[i] = lut_fert[k]
	var t_end := Time.get_ticks_usec()

	var fractions := {}
	for id in subs.count():
		fractions[subs.names[id]] = float(sub.count(id)) / world.cell_count
	return {
		"noise_ms": (t_noise - t0) / 1000.0,
		"classify_ms": (t_end - t_noise) / 1000.0,
		"total_ms": (t_end - t0) / 1000.0,
		"fractions": fractions,
	}


static func _noise_bytes(seed_value: int, params: Registry, prefix: String, longest: int,
		w: int, h: int) -> PackedByteArray:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.seed = seed_value
	n.frequency = params.get_float(prefix + ".features_per_map") / float(longest)
	n.fractal_octaves = params.get_int(prefix + ".octaves")
	n.fractal_lacunarity = params.get_float(prefix + ".lacunarity")
	n.fractal_gain = params.get_float(prefix + ".gain")
	# normalize=true stretches the image min..max to 0..255, so the thresholds below act as
	# quantiles-ish regardless of map size or octave count.
	return n.get_image(w, h, false, false, true).get_data()


## Returns [substrate_lut, moisture_lut, fertility_lut], each indexed by (elev << 8) | moist.
static func build_luts(params: Registry, subs: Substrates) -> Array:
	var water := subs.id_of("water")
	var soil := subs.id_of("soil")
	var sand := subs.id_of("sand")
	var mud := subs.id_of("mud")
	var rock := subs.id_of("rock")
	assert(water >= 0 and soil >= 0 and sand >= 0 and mud >= 0 and rock >= 0,
			"terrain generator needs water, soil, sand, mud, rock substrates")

	var sea := params.get_float("terrain.sea_level")
	var beach := sea + params.get_float("terrain.beach_width")
	var rock_level := params.get_float("terrain.rock_level")
	var lake_m := params.get_float("terrain.lake_moisture")
	var lake_e := params.get_float("terrain.lake_max_elevation")
	var marsh_m := params.get_float("terrain.marsh_moisture")
	var marsh_e := params.get_float("terrain.marsh_max_elevation")
	var desert_m := params.get_float("terrain.desert_moisture")
	var coast_bonus := params.get_float("terrain.coast_moisture_bonus")
	var coast_falloff := params.get_float("terrain.coast_moisture_falloff")
	var fert_w := params.get_float("terrain.fertility_moisture_weight")

	var lut_sub := PackedByteArray()
	var lut_moist := PackedByteArray()
	var lut_fert := PackedByteArray()
	for arr: PackedByteArray in [lut_sub, lut_moist, lut_fert]:
		arr.resize(256 * 256)
	for e in 256:
		var ef := e / float(BYTE_MAX)
		for m in 256:
			var mf := m / float(BYTE_MAX)
			var s: int
			if ef < sea:
				s = water
			elif ef > rock_level:
				s = rock
			elif mf > lake_m and ef < lake_e:
				s = water
			elif ef < beach:
				s = mud if mf > marsh_m else sand
			elif mf < desert_m:
				s = sand
			elif mf > marsh_m and ef < marsh_e:
				s = mud
			else:
				s = soil
			var mo: float
			if s == water:
				mo = 1.0
			else:
				var coast := maxf(0.0, 1.0 - (ef - sea) / coast_falloff)
				mo = clampf(mf + coast_bonus * coast, 0.0, 1.0)
			var fert := subs.fertility_base[s] * ((1.0 - fert_w) + fert_w * mo)
			var k := (e << 8) | m
			lut_sub[k] = s
			lut_moist[k] = roundi(mo * BYTE_MAX)
			lut_fert[k] = roundi(clampf(fert, 0.0, 1.0) * BYTE_MAX)
	return [lut_sub, lut_moist, lut_fert]
