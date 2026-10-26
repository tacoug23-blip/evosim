## The sampled environment pass: moisture, fertility, and flora (spec sections 2.5, 3).
##
## Each tick a fixed share of cells (env.sample_fraction) is updated; nothing touches all
## 16.7M cells. A sampled land cell:
##   1. moisture  relaxes toward its climate target (low-res climate grid + season + recent
##                rain) and diffuses toward its 4 neighbours. Water cells stay at 255, so they
##                act as sources.
##   2. fertility relaxes toward the natural level for its substrate and moisture.
##   3. flora     grows (rate x daylight share x season x moisture x fertility x stall), or wilts
##                or starves, may die (annual mortality), consumes fertility, and when mature
##                may drop a seed on a random cell within seed_spread_radius.
## Rates are per day; each update applies the expected interval since the cell's last update
## (cells / samples ticks), so results do not depend on the sample rate except through noise.
##
## Determinism with threads: the map is split into env.bands horizontal bands. Even bands run
## in parallel, then odd bands. A band writes only its own cells, and its only reads outside
## itself (moisture neighbours on its edge rows) hit bands that are idle in that pass. Seeds are
## collected per band and applied sequentially afterwards. Each band draws from its own xorshift
## sequence seeded by hash(seed, tick, band). The band layout is a parameter, not derived from
## the thread count, so results are identical for any thread count.
##
## Not thread-safe: call harvest/plant/apply_brush only between ticks or from a sequential
## phase.
extends RefCounted

const Rng := preload("res://sim/core/rng.gd")
const Parallel := preload("res://sim/core/parallel.gd")
const TerrainGen := preload("res://sim/world/terrain_gen.gd")

const STREAM_SAMPLE := "env.sample"
const STREAM_WEATHER := "env.weather"
const STREAM_FLORA_INIT := "flora.init"
const SEASONS := 4
const SUBSTRATE_SLOTS := 256
const BYTE_MAX := 255
const MASK32 := 0xFFFFFFFF
## Growth factors are fixed point with this many fractional bits.
const Q_SHIFT := 10
const Q := 1 << Q_SHIFT
## Random rolls compare 24-bit draws against thresholds.
const ROLL_BITS := 24
const ROLL_ONE := 1 << ROLL_BITS
const ROLL_MASK := ROLL_ONE - 1
## Initial flora placement gives up after this many tries per plant (retry budget).
const INIT_ATTEMPTS_PER_PLANT := 4

enum Stat { GROWTH, DEATHS, BIOMASS_DELTA, COVER_DELTA }
const STAT_KINDS := 4
## Trailing slots in a band's stats array: samples, moisture sum, fertility sum.
const ENV_SLOTS := 3

enum Brush { HARVEST, PLANT }

var world: RefCounted
var subs: RefCounted
var flora: RefCounted
var items: RefCounted
var time: RefCounted
var enabled := true

## Live totals per flora type id, kept incrementally (index 0 unused).
var coverage := PackedInt64Array()
var biomass := PackedInt64Array()
## Land cells each type may grow on (for coverage percentages).
var plantable := PackedInt64Array()
## Accumulated since the last take_period_stats().
var period_growth := PackedInt64Array()
var period_births := PackedInt64Array()
var period_deaths := PackedInt64Array()
var period_harvested := PackedInt64Array()
var period_samples := 0
var period_moisture_sum := 0
var period_fertility_sum := 0
var period_ticks := 0
## Low-res climate grid: base moisture target (0..255) per block.
var climate := PackedByteArray()
var climate_w := 0
var climate_h := 0
## Microseconds spent in tick() since the last reset.
var timing_usec := 0
## Cells updated per tick and days of growth each update stands for.
var samples_per_tick := 0
var dt_days := 0.0

var _w := 0
var _h := 0
var _cells := 0
var _types := 0
var _water := 0
var _workers := 1
var _bands := 2
var _band_c0 := PackedInt64Array()
var _band_cells := PackedInt64Array()
var _band_n := PackedInt64Array()
var _band_stats: Array[PackedInt64Array] = []
var _band_seeds: Array[PackedInt32Array] = []
var _stride := 1
var _seed32 := 0
var _weather_seed32 := 0
var _block := 1
var _diff_q := 0
var _relax_q := 0
var _regen_q := 0
var _season_moist := PackedInt32Array()
var _rain_enabled := false
var _rain_threshold := 0
var _rain_memory := 1
var _rain_bytes := 0
var _seedling := 1
var _drain_q := 0
var _starve_f := 0
## Seed failure chance per same-type neighbour, as a 24-bit roll threshold.
var _crowd_roll := 0
var _fresp := PackedInt32Array()
var _fert_target := PackedByteArray()
var _stall_q := PackedInt32Array()
var _mresp := PackedInt32Array()
var _wilt_m := PackedInt32Array()
var _consume_q := PackedInt32Array()
var _max_b := PackedInt32Array()
var _mature_b := PackedInt32Array()
var _radius := PackedInt32Array()
var _mort_roll := PackedInt32Array()
var _wilt_loss := PackedInt32Array()
var _starve_loss := PackedInt32Array()
# Per-tick values (begin_tick).
var _tick := 0
var _season := 0
var _base_q := PackedInt64Array()
var _seed_roll := PackedInt32Array()
var _moist_offset := 0
var _rain_day := -1
var _rain_offset := 0


func setup(p_world: RefCounted, p_subs: RefCounted, p_flora: RefCounted, p_items: RefCounted,
		p_time: RefCounted,
		params: RefCounted, rngs: RefCounted) -> void:
	world = p_world
	subs = p_subs
	flora = p_flora
	items = p_items
	time = p_time
	enabled = params.get_bool("env.enabled")
	_w = world.width
	_h = world.height
	_cells = world.cell_count
	_types = flora.count()
	_stride = _types + 1
	_water = subs.id_of("water")
	_workers = Parallel.resolve_workers(params.get_int("sim.worker_threads"))
	_seed32 = rngs.stream_seed32(STREAM_SAMPLE)
	_weather_seed32 = rngs.stream_seed32(STREAM_WEATHER)
	_setup_bands(params)
	_setup_climate(params, rngs)
	_setup_tables(params)
	coverage = _zeros64(_stride)
	biomass = _zeros64(_stride)
	plantable = _zeros64(_stride)
	period_growth = _zeros64(_stride)
	period_births = _zeros64(_stride)
	period_deaths = _zeros64(_stride)
	period_harvested = _zeros64(_stride)
	_base_q = _zeros64(_stride)
	_seed_roll = _zeros32(_stride)
	for t in range(1, _stride):
		for s in subs.count():
			if flora.allowed[t * SUBSTRATE_SLOTS + s] == 1:
				plantable[t] += world.substrate.count(s)
	_rain_day = -1
	begin_tick(0)


func _setup_bands(params: RefCounted) -> void:
	_bands = clampi(params.get_int("env.bands"), 1, _h)
	var target := maxi(1, roundi(params.get_float("env.sample_fraction") * _cells))
	_band_c0.resize(_bands)
	_band_cells.resize(_bands)
	_band_n.resize(_bands)
	_band_stats.clear()
	_band_seeds.clear()
	samples_per_tick = 0
	for b in _bands:
		@warning_ignore("integer_division")
		var r0 := b * _h / _bands
		@warning_ignore("integer_division")
		var r1 := (b + 1) * _h / _bands
		_band_c0[b] = r0 * _w
		_band_cells[b] = (r1 - r0) * _w
		@warning_ignore("integer_division")
		_band_n[b] = (target * _band_cells[b] + _cells / 2) / _cells
		samples_per_tick += _band_n[b]
		var st := PackedInt64Array()
		st.resize(STAT_KINDS * _stride + ENV_SLOTS)
		_band_stats.append(st)
		_band_seeds.append(PackedInt32Array())
	samples_per_tick = maxi(samples_per_tick, 1)
	dt_days = float(_cells) / samples_per_tick / time.ticks_per_day


## Climate grid: the terrain's moisture noise sampled every climate_block cells, mapped onto
## [climate_moisture_min, climate_moisture_max]. Regenerated from the seed, never saved.
func _setup_climate(params: RefCounted, rngs: RefCounted) -> void:
	_block = params.get_int("env.climate_block")
	climate_w = ceili(float(_w) / _block)
	climate_h = ceili(float(_h) / _block)
	var seeds := TerrainGen.noise_seeds(rngs.master_seed)
	var raw := TerrainGen.noise_bytes(seeds[1], params, "terrain.moisture", maxi(_w, _h),
			climate_w, climate_h, _block)
	var lo: float = params.get_float("env.climate_moisture_min") * BYTE_MAX
	var hi: float = params.get_float("env.climate_moisture_max") * BYTE_MAX
	climate.resize(raw.size())
	for i in raw.size():
		climate[i] = clampi(roundi(lo + (hi - lo) * raw[i] / float(BYTE_MAX)), 0, BYTE_MAX)


func _setup_tables(params: RefCounted) -> void:
	var dt := dt_days
	_diff_q = roundi(minf(params.get_float("env.moisture_diffusion") * dt, 1.0) * Q)
	_relax_q = roundi(minf(params.get_float("env.moisture_relax") * dt, 1.0) * Q)
	_regen_q = roundi(minf(params.get_float("env.fertility_regen") * dt, 1.0) * Q)
	_season_moist.resize(SEASONS)
	for s in SEASONS:
		_season_moist[s] = roundi(params.get_float("env.season_moisture." + time.SEASON_NAMES[s]) * BYTE_MAX)
	_rain_enabled = params.get_bool("env.rain_enabled")
	_rain_threshold = roundi(params.get_float("env.rain_chance") * MASK32)
	_rain_memory = params.get_int("env.rain_memory_days")
	_rain_bytes = roundi(params.get_float("env.rain_moisture") * BYTE_MAX)
	_seedling = params.get_int("flora.seedling_biomass")
	_drain_q = roundi(params.get_float("flora.harvest_fertility_drain") * Q)
	_starve_f = roundi(params.get_float("flora.starve_fertility") * BYTE_MAX)
	_crowd_roll = roundi(params.get_float("flora.crowding_penalty") * ROLL_ONE)

	# Fertility response, shared by all types: linear up to the saturation level.
	var sat := maxf(params.get_float("flora.fertility_saturation") * BYTE_MAX, 1.0)
	_fresp.resize(256)
	for f in 256:
		_fresp[f] = roundi(minf(1.0, f / sat) * Q)

	# Natural fertility level per (substrate, moisture), as in terrain generation.
	var w_m: float = params.get_float("terrain.fertility_moisture_weight")
	_fert_target.resize(subs.count() * SUBSTRATE_SLOTS)
	for s in subs.count():
		for m in 256:
			var v: float = subs.fertility_base[s] * ((1.0 - w_m) + w_m * m / float(BYTE_MAX))
			_fert_target[s * SUBSTRATE_SLOTS + m] = clampi(roundi(v * BYTE_MAX), 0, BYTE_MAX)

	# Growth-stall hook by structure material (spec section 8). Phase 7 fills this from
	# config/materials.json flora_stall; until then every material is 1.0 (no stall).
	_stall_q.resize(256)
	_stall_q.fill(Q)

	var wilt_frac: float = params.get_float("flora.wilt_fraction")
	var wilt_rate: float = params.get_float("flora.wilt_rate")
	var starve_rate: float = params.get_float("flora.starve_rate")
	_wilt_m = _zeros32(_stride)
	_consume_q = _zeros32(_stride)
	_max_b = _zeros32(_stride)
	_mature_b = _zeros32(_stride)
	_radius = _zeros32(_stride)
	_mort_roll = _zeros32(_stride)
	_wilt_loss = _zeros32(_stride)
	_starve_loss = _zeros32(_stride)
	_mresp = _zeros32(_stride * 256)
	for t in range(1, _stride):
		var need: float = maxf(flora.moisture_need[t] * BYTE_MAX, 1.0)
		for m in 256:
			_mresp[t * 256 + m] = roundi(minf(1.0, m / need) * Q)
		_wilt_m[t] = roundi(need * wilt_frac)
		_consume_q[t] = roundi(flora.fertility_consumption[t] * Q)
		_max_b[t] = flora.max_biomass[t]
		_mature_b[t] = maxi(1, roundi(flora.maturity[t] * flora.max_biomass[t]))
		_radius[t] = flora.seed_spread_radius[t]
		var p_die := 1.0 - pow(1.0 - flora.mortality[t], dt / time.days_per_year)
		_mort_roll[t] = roundi(p_die * ROLL_ONE)
		_wilt_loss[t] = maxi(1, roundi(wilt_rate * flora.max_biomass[t] * dt))
		_starve_loss[t] = maxi(1, roundi(starve_rate * flora.max_biomass[t] * dt))


## Recompute the per-tick factors (season, daylight share, weather).
func begin_tick(tick_number: int) -> void:
	_tick = tick_number
	_season = time.season(tick_number)
	var share: float = time.daylight_share[_season]
	for t in range(1, _stride):
		var light: float = share * flora.day_growth[t] + (1.0 - share) * flora.night_growth[t]
		var sg: float = flora.seasonal_growth[t * SEASONS + _season]
		_base_q[t] = roundi(flora.growth_rate[t] * dt_days * light * sg * Q)
		var p_seed := 1.0 - pow(1.0 - flora.seed_chance[t], dt_days)
		_seed_roll[t] = roundi(p_seed * ROLL_ONE) if sg > 0.0 else 0
	var day: int = time.day(tick_number)
	if day != _rain_day:
		_rain_day = day
		_rain_offset = roundi(_rain_bytes * rain_share(day)) if _rain_enabled else 0
	_moist_offset = _season_moist[_season] + _rain_offset


## Whether `day` was rainy (map-wide weather; stateless in the day number).
func is_rainy(day: int) -> bool:
	return Rng.hash3(_weather_seed32, day, 0) < _rain_threshold


## Share of rainy days among the rain_memory_days ending at `day`.
func rain_share(day: int) -> float:
	var n := 0
	for d in range(day - _rain_memory + 1, day + 1):
		if is_rainy(d):
			n += 1
	return float(n) / _rain_memory


func tick(tick_number: int) -> void:
	if not enabled:
		return
	var t0 := Time.get_ticks_usec()
	begin_tick(tick_number)
	for layer: StringName in [&"moisture", &"fertility", &"flora_type", &"flora_biomass"]:
		Parallel.ensure_unique(world, layer)
	@warning_ignore("integer_division")
	var even := (_bands + 1) / 2
	@warning_ignore("integer_division")
	var odd := _bands / 2
	Parallel.for_each(even, _band_task.bind(0, tick_number), _workers)
	Parallel.for_each(odd, _band_task.bind(1, tick_number), _workers)
	_merge_and_seed()
	timing_usec += Time.get_ticks_usec() - t0


func _band_task(i: int, parity: int, tick_number: int) -> void:
	_process_band(i * 2 + parity, tick_number)


func _process_band(b: int, tick_number: int) -> void:
	var w := _w
	var h := _h
	var c0 := _band_c0[b]
	var cells := _band_cells[b]
	var stride := _stride
	var stats := _band_stats[b]
	stats.fill(0)
	var seeds := _band_seeds[b]
	seeds.resize(0)
	if cells <= 0:
		return
	var sub: PackedByteArray = world.substrate
	var mo: PackedByteArray = world.moisture
	var fe: PackedByteArray = world.fertility
	var ft: PackedByteArray = world.flora_type
	var fb: PackedByteArray = world.flora_biomass
	var smat: PackedByteArray = world.structure_material
	var clim := climate
	var cw := climate_w
	var blk := _block
	var water := _water
	var diff_q := _diff_q
	var relax_q := _relax_q
	var regen_q := _regen_q
	var moff := _moist_offset
	var fert_target := _fert_target
	var fresp := _fresp
	var stall_q := _stall_q
	var mresp := _mresp
	var wilt_m := _wilt_m
	var consume_q := _consume_q
	var max_b := _max_b
	var mature_b := _mature_b
	var radius := _radius
	var mort_roll := _mort_roll
	var wilt_loss := _wilt_loss
	var starve_loss := _starve_loss
	var starve_f := _starve_f
	var base_q := _base_q
	var seed_roll := _seed_roll
	var moist_sum := 0
	var fert_sum := 0
	var sampled := 0
	var x := Rng.hash3(_seed32, tick_number, b) | 1
	for k in _band_n[b]:
		x ^= (x << 13) & MASK32
		x ^= x >> 17
		x ^= (x << 5) & MASK32
		var c := c0 + x % cells
		var s := sub[c]
		if s == water:
			continue
		var cx := c % w
		@warning_ignore("integer_division")
		var cy := c / w

		# Moisture: relax toward climate target, diffuse toward neighbours.
		var m := mo[c]
		var nsum := (mo[c - 1] if cx > 0 else m) + (mo[c + 1] if cx < w - 1 else m) \
				+ (mo[c - w] if cy > 0 else m) + (mo[c + w] if cy < h - 1 else m)
		@warning_ignore("integer_division")
		var target := clampi(clim[(cy / blk) * cw + cx / blk] + moff, 0, BYTE_MAX)
		m = clampi(m + ((diff_q * (nsum - 4 * m) + 4 * relax_q * (target - m) + 2048) >> 12), 0, BYTE_MAX)

		# Fertility: relax toward the natural level for this substrate and moisture.
		var f := fe[c]
		f = clampi(f + ((regen_q * (fert_target[s * SUBSTRATE_SLOTS + m] - f) + 512) >> Q_SHIFT), 0, BYTE_MAX)

		var t := ft[c]
		if t != 0:
			var bio := fb[c]
			var nb := bio
			if m < wilt_m[t]:
				nb -= wilt_loss[t]
			elif f < starve_f:
				nb -= starve_loss[t]
			else:
				var g := ((base_q[t] * mresp[t * 256 + m] >> Q_SHIFT) * fresp[f] >> Q_SHIFT) \
						* stall_q[smat[c]] >> Q_SHIFT
				x ^= (x << 13) & MASK32
				x ^= x >> 17
				x ^= (x << 5) & MASK32
				var inc := (g >> Q_SHIFT) + (1 if (x & (Q - 1)) < (g & (Q - 1)) else 0)
				inc = mini(inc, max_b[t] - nb)
				if inc > 0:
					nb += inc
					stats[Stat.GROWTH * stride + t] += inc
					f = maxi(0, f - ((inc * consume_q[t] + 512) >> Q_SHIFT))
			x ^= (x << 13) & MASK32
			x ^= x >> 17
			x ^= (x << 5) & MASK32
			if (x & ROLL_MASK) < mort_roll[t]:
				nb = 0
			if nb <= 0:
				ft[c] = 0
				fb[c] = 0
				stats[Stat.DEATHS * stride + t] += 1
				stats[Stat.COVER_DELTA * stride + t] -= 1
				stats[Stat.BIOMASS_DELTA * stride + t] -= bio
			else:
				fb[c] = nb
				stats[Stat.BIOMASS_DELTA * stride + t] += nb - bio
				if nb >= mature_b[t] and seed_roll[t] > 0:
					x ^= (x << 13) & MASK32
					x ^= x >> 17
					x ^= (x << 5) & MASK32
					if (x & ROLL_MASK) < seed_roll[t]:
						var r := radius[t]
						var span := 2 * r + 1
						x ^= (x << 13) & MASK32
						x ^= x >> 17
						x ^= (x << 5) & MASK32
						var tx := cx + x % span - r
						@warning_ignore("integer_division")
						var ty := cy + (x / span) % span - r
						if tx >= 0 and ty >= 0 and tx < w and ty < h and (tx != cx or ty != cy):
							seeds.append(ty * w + tx)
							seeds.append(t)
		mo[c] = m
		fe[c] = f
		sampled += 1
		moist_sum += m
		fert_sum += f
	var env0 := STAT_KINDS * stride
	stats[env0] = sampled
	stats[env0 + 1] = moist_sum
	stats[env0 + 2] = fert_sum


## Sequential, in band order: fold band stats into the totals and plant collected seeds.
func _merge_and_seed() -> void:
	var stride := _stride
	var sub: PackedByteArray = world.substrate
	var mo: PackedByteArray = world.moisture
	var ft: PackedByteArray = world.flora_type
	var fb: PackedByteArray = world.flora_biomass
	var allowed: PackedByteArray = flora.allowed
	var seedling := _seedling
	var env0 := STAT_KINDS * stride
	var w := _w
	var h := _h
	var crowd := _crowd_roll
	# One xorshift sequence for the whole (sequential) seed step.
	var x := Rng.hash3(_seed32, _tick, _bands) | 1
	for b in _bands:
		var st := _band_stats[b]
		for t in range(1, stride):
			period_growth[t] += st[Stat.GROWTH * stride + t]
			period_deaths[t] += st[Stat.DEATHS * stride + t]
			biomass[t] += st[Stat.BIOMASS_DELTA * stride + t]
			coverage[t] += st[Stat.COVER_DELTA * stride + t]
		period_samples += st[env0]
		period_moisture_sum += st[env0 + 1]
		period_fertility_sum += st[env0 + 2]
		var seeds := _band_seeds[b]
		for i in range(0, seeds.size(), 2):
			var c := seeds[i]
			var t := seeds[i + 1]
			if ft[c] != 0 or allowed[t * SUBSTRATE_SLOTS + sub[c]] != 1 or mo[c] < _wilt_m[t]:
				continue
			# Janzen-Connell: each same-type neighbour (of 8) adds crowding_penalty to the
			# chance the seed fails. Keeps any one type from monopolising shared habitat.
			var cx := c % w
			@warning_ignore("integer_division")
			var cy := c / w
			var same := 0
			for dy in range(-1, 2):
				var yy := cy + dy
				if yy < 0 or yy >= h:
					continue
				for dx in range(-1, 2):
					var xx := cx + dx
					if (dx != 0 or dy != 0) and xx >= 0 and xx < w and ft[yy * w + xx] == t:
						same += 1
			if same > 0:
				x ^= (x << 13) & MASK32
				x ^= x >> 17
				x ^= (x << 5) & MASK32
				if (x & ROLL_MASK) < same * crowd:
					continue
			ft[c] = t
			fb[c] = seedling
			coverage[t] += 1
			biomass[t] += seedling
			period_births[t] += 1
	period_ticks += 1


## Place the initial plants of a freshly generated world (flora.init stream).
func seed_initial(rngs: RefCounted) -> void:
	var rng: RandomNumberGenerator = rngs.stream(STREAM_FLORA_INIT)
	var sub: PackedByteArray = world.substrate
	var mo: PackedByteArray = world.moisture
	var ft: PackedByteArray = world.flora_type
	var fb: PackedByteArray = world.flora_biomass
	for t in range(1, _stride):
		var want := roundi(flora.initial_cover[t] * plantable[t])
		var placed := 0
		var attempts := 0
		while placed < want and attempts < want * INIT_ATTEMPTS_PER_PLANT:
			attempts += 1
			var c := rng.randi_range(0, _cells - 1)
			if ft[c] == 0 and flora.allowed[t * SUBSTRATE_SLOTS + sub[c]] == 1 and mo[c] >= _wilt_m[t]:
				var b := rng.randi_range(_seedling, _max_b[t])
				ft[c] = t
				fb[c] = b
				coverage[t] += 1
				biomass[t] += b
				placed += 1


## Harvest up to `amount` biomass from `cell`. Yield scales with the type's seasonal_yield for
## the current season; fertility is drained per biomass removed; a plant harvested to zero
## dies. Returns {item, name, qty, nutrition, removed, type}.
func harvest(cell: int, amount: int) -> Dictionary:
	var t: int = world.flora_type[cell]
	var removed := harvest_removed(cell, amount)
	if removed == 0:
		return {"item": 0, "name": "", "qty": 0, "nutrition": 0.0, "removed": 0, "type": 0}
	var qty := yield_qty(t, removed)
	var item: int = flora.harvest_item[t]
	return {"item": item, "name": items.names[item], "qty": qty,
			"nutrition": qty * items.nutrition[item], "removed": removed, "type": t}


## Item quantity that `removed` biomass of type t yields this season.
func yield_qty(t: int, removed: int) -> int:
	return roundi(removed * flora.seasonal_yield[t * SEASONS + _season])


## harvest() without building a Dictionary, for callers in hot loops (entities eating).
## Same effects; returns the biomass removed. Read the flora type before calling, and get
## the item quantity from yield_qty().
func harvest_removed(cell: int, amount: int) -> int:
	var ft: PackedByteArray = world.flora_type
	var fb: PackedByteArray = world.flora_biomass
	var t := ft[cell]
	if t == 0 or amount <= 0:
		return 0
	var bio := fb[cell]
	var removed := mini(amount, bio)
	var nb := bio - removed
	var fe: PackedByteArray = world.fertility
	fe[cell] = maxi(0, fe[cell] - ((removed * _drain_q + Q / 2) >> Q_SHIFT))
	period_harvested[t] += removed
	biomass[t] -= removed
	if nb == 0:
		ft[cell] = 0
		coverage[t] -= 1
		period_deaths[t] += 1
	fb[cell] = nb
	return removed


## Put a plant of `type` with `bio` biomass on an empty cell. Respects substrate rules unless
## force. Returns whether a plant was placed.
func plant(cell: int, type: int, bio: int, force: bool = false) -> bool:
	var ft: PackedByteArray = world.flora_type
	if type < 1 or type > _types or ft[cell] != 0:
		return false
	if not force and flora.allowed[type * SUBSTRATE_SLOTS + world.substrate[cell]] != 1:
		return false
	var b := clampi(bio, 1, _max_b[type])
	ft[cell] = type
	world.flora_biomass[cell] = b
	coverage[type] += 1
	biomass[type] += b
	period_births[type] += 1
	return true


## Debug brush: harvest everything, or plant mature `type`, in a disc of `radius` cells.
## Returns the number of cells changed.
func apply_brush(cx: int, cy: int, brush_radius: int, mode: Brush, type: int = 0) -> int:
	var changed := 0
	for y in range(maxi(0, cy - brush_radius), mini(_h - 1, cy + brush_radius) + 1):
		for x in range(maxi(0, cx - brush_radius), mini(_w - 1, cx + brush_radius) + 1):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) > brush_radius * brush_radius:
				continue
			var c := y * _w + x
			if mode == Brush.HARVEST:
				if harvest(c, BYTE_MAX)["removed"] > 0:
					changed += 1
			elif plant(c, type, _max_b[type] if type > 0 else 1):
				changed += 1
	return changed


## Growth-stall multiplier for a cell, read from its structure material (spec section 8;
## phase 2 scope item 7). Stub: 1.0 for every material until Phase 7 fills the table from
## config/materials.json. The sampled pass reads the same table inline.
func growth_stall(cell: int) -> float:
	return _stall_q[world.structure_material[cell]] / float(Q)


## Counters accumulated since the last call, plus current totals. Resets the period.
func take_period_stats() -> Dictionary:
	var out := {
		"ticks": period_ticks,
		"coverage": coverage.duplicate(),
		"biomass": biomass.duplicate(),
		"growth": period_growth.duplicate(),
		"births": period_births.duplicate(),
		"deaths": period_deaths.duplicate(),
		"harvested": period_harvested.duplicate(),
		"mean_moisture": float(period_moisture_sum) / maxi(period_samples, 1) / BYTE_MAX,
		"mean_fertility": float(period_fertility_sum) / maxi(period_samples, 1) / BYTE_MAX,
	}
	period_growth.fill(0)
	period_births.fill(0)
	period_deaths.fill(0)
	period_harvested.fill(0)
	period_samples = 0
	period_moisture_sum = 0
	period_fertility_sum = 0
	period_ticks = 0
	return out


## Recompute coverage and biomass totals from the layers (tests, and loading old saves).
func recount() -> void:
	coverage.fill(0)
	biomass.fill(0)
	var ft: PackedByteArray = world.flora_type
	var fb: PackedByteArray = world.flora_biomass
	for t in range(1, _stride):
		coverage[t] = ft.count(t)
	var sums := biomass
	for c in _cells:
		var t := ft[c]
		if t != 0:
			sums[t] += fb[c]


func get_counters() -> Dictionary:
	return {"coverage": Array(coverage), "biomass": Array(biomass)}


func set_counters(d: Dictionary) -> bool:
	var cov: Array = d.get("coverage", [])
	var bio: Array = d.get("biomass", [])
	if cov.size() != _stride or bio.size() != _stride:
		return false
	for t in _stride:
		coverage[t] = int(cov[t])
		biomass[t] = int(bio[t])
	return true


func current_season() -> int:
	return _season


func type_count() -> int:
	return _types



static func _zeros64(n: int) -> PackedInt64Array:
	var a := PackedInt64Array()
	a.resize(n)
	a.fill(0)
	return a


static func _zeros32(n: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(0)
	return a
