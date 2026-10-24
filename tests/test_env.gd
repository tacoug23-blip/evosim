## The sampled environment pass: substrate rules, determinism, seasons, harvest, fertility,
## moisture.
extends "res://tests/test_base.gd"

const Parallel := preload("res://sim/core/parallel.gd")
const EnvSystem := preload("res://sim/env/env_system.gd")

const WINTER := 3


func _run(core: RefCounted, ticks: int) -> void:
	for i in ticks:
		core.step()


func _plant_cells(core: RefCounted, type: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ft: PackedByteArray = core.world.flora_type
	for c in core.world.cell_count:
		if ft[c] == type:
			out.append(c)
	return out


func test_flora_only_on_allowed_substrates() -> void:
	var core := make_core("test_tiny", {"world.seed": 3})
	_run(core, 3000)
	var w: RefCounted = core.world
	var bad := 0
	var wet_water := true
	var water: int = core.substrates.id_of("water")
	for c in w.cell_count:
		var t: int = w.flora_type[c]
		if t != 0 and core.flora.allowed[t * 256 + w.substrate[c]] != 1:
			bad += 1
		if w.substrate[c] == water and w.moisture[c] != 255:
			wet_water = false
	check_eq(bad, 0, "no plant on a disallowed substrate")
	check(wet_water, "water cells stay saturated")
	var total := 0
	for t in range(1, core.flora.count() + 1):
		total += core.env.coverage[t]
	check(total > 0, "flora present")


func test_counters_match_recount() -> void:
	var core := make_core("test_tiny", {"world.seed": 4})
	_run(core, 2500)
	core.env.apply_brush(100, 100, 6, EnvSystem.Brush.HARVEST)
	core.env.apply_brush(60, 60, 4, EnvSystem.Brush.PLANT, core.flora.id_of("grass"))
	var cov: PackedInt64Array = core.env.coverage.duplicate()
	var bio: PackedInt64Array = core.env.biomass.duplicate()
	core.env.recount()
	check_eq(core.env.coverage, cov, "incremental coverage matches recount")
	check_eq(core.env.biomass, bio, "incremental biomass matches recount")


func test_same_result_for_any_thread_count() -> void:
	var hashes := []
	for threads in [1, 3, 8]:
		var core := make_core("test_tiny", {"world.seed": 5, "sim.worker_threads": threads})
		_run(core, 1500)
		hashes.append(core.full_hash())
	check_eq(hashes[1], hashes[0], "3 threads match 1 thread")
	check_eq(hashes[2], hashes[0], "8 threads match 1 thread")


func test_render_snapshots_do_not_change_results() -> void:
	var plain := make_core("test_tiny", {"world.seed": 6})
	var watched := make_core("test_tiny", {"world.seed": 6})
	for i in 1200:
		plain.step()
		watched.step()
		if i % 7 == 0:
			var snap: Dictionary = watched.render_snapshot(PackedStringArray(
					["flora_type", "flora_biomass", "fertility", "moisture"]))
			check_eq((snap["layers"]["flora_type"] as PackedByteArray).size(),
					watched.world.cell_count, "snapshot layer copied")
	check_eq(watched.full_hash(), plain.full_hash(), "snapshots taken mid-run leave results unchanged")


func test_winter_stall_matches_config() -> void:
	var core := make_core("test_tiny", {"world.seed": 7})
	var time: RefCounted = core.time
	var per_season := []
	core.env.take_period_stats()
	for s in 4:
		# A season's ticks are those whose season_count is s; stop before the next season's first.
		while time.season_count(core.tick + 1) == s:
			core.step()
		per_season.append(core.env.take_period_stats())
	var winter: Dictionary = per_season[WINTER]
	for t in range(1, core.flora.count() + 1):
		var cfg: float = core.flora.seasonal_growth[t * 4 + WINTER]
		if cfg == 0.0:
			check_eq(winter["growth"][t], 0, "%s: no winter growth (config stall)" % core.flora.names[t])
			check_eq(winter["births"][t], 0, "%s: no winter seeding (config stall)" % core.flora.names[t])
		else:
			check(winter["growth"][t] > 0, "%s: some winter growth (config %.2f)" % [core.flora.names[t], cfg])
		check(per_season[0]["growth"][t] > 0, "%s grows in spring" % core.flora.names[t])


func test_harvest_api() -> void:
	var core := make_core("test_tiny", {"world.seed": 8})
	var env: RefCounted = core.env
	var berry: int = core.flora.id_of("berry_bush")
	var cells := _plant_cells(core, berry)
	if not check(cells.size() > 0, "a berry bush exists"):
		return
	var c := cells[0]
	core.world.flora_biomass[c] = 100
	env.biomass[berry] += 100 - env.biomass[berry]  # keep totals consistent for this cell only
	env.recount()
	var fert_before: int = core.world.fertility[c]
	var drain: float = core.params.get_float("flora.harvest_fertility_drain")

	env.begin_tick(core.time.ticks_per_season + 1)  # summer
	var got: Dictionary = env.harvest(c, 30)
	var summer_yield: float = core.flora.seasonal_yield[berry * 4 + 1]
	check_eq(got["removed"], 30, "removed the requested amount")
	check_eq(got["qty"], roundi(30 * summer_yield), "yield scales with the summer seasonal_yield")
	check_eq(got["name"], "berries", "harvest item")
	check_eq(got["nutrition"], got["qty"] * core.flora.nutrition[berry], "nutrition per item")
	check_eq(core.world.flora_biomass[c], 70, "biomass reduced")
	check_eq(core.world.fertility[c], maxi(0, fert_before - roundi(30 * drain)), "fertility drained per biomass removed")

	env.begin_tick(3 * core.time.ticks_per_season + 1)  # winter: berry yield is 0 in config
	var winter_got: Dictionary = env.harvest(c, 30)
	check_eq(winter_got["qty"], roundi(30 * core.flora.seasonal_yield[berry * 4 + WINTER]), "winter yield per config")
	check(winter_got["qty"] < got["qty"], "seasonal yield varies")

	var cov_before: int = env.coverage[berry]
	var rest: Dictionary = env.harvest(c, 255)
	check_eq(rest["removed"], 40, "harvest is capped at the remaining biomass")
	check_eq(core.world.flora_type[c], 0, "a plant harvested to zero is removed")
	check_eq(env.coverage[berry], cov_before - 1, "coverage updated")
	check_eq(env.harvest(c, 10)["removed"], 0, "harvesting an empty cell yields nothing")


func test_fertility_drops_under_harvest_and_recovers() -> void:
	var core := make_core("test_tiny", {"world.seed": 9})
	var env: RefCounted = core.env
	_run(core, core.time.ticks_per_season)  # let flora establish
	var region := _region_cells(core, 64, 64, 48)
	var before := _mean_fertility(core, region)
	# Heavy harvest: every day take half of every plant's biomass in the region, for a season.
	for day in core.time.days_per_season:
		for c in region:
			var b: int = core.world.flora_biomass[c]
			if b > 1:
				env.harvest(c, b / 2)
		_run(core, core.time.ticks_per_day)
	var harvested := _mean_fertility(core, region)
	_run(core, core.time.ticks_per_season * 4)  # leave it alone for a year
	var recovered := _mean_fertility(core, region)
	var drop := before - harvested
	check(drop > 5.0, "fertility drops under heavy harvest (%.1f -> %.1f)" % [before, harvested])
	check(recovered - harvested > 0.3 * drop,
			"fertility recovers when left alone (%.1f -> %.1f, %.0f%% of the drop)" % [
			harvested, recovered, 100.0 * (recovered - harvested) / maxf(drop, 0.001)])


func test_growth_drains_fertility_without_harvest() -> void:
	# Same world twice, no harvest in either; in one, plants consume no fertility. Growth alone
	# (fertility_consumption) must leave the consuming world with less fertility.
	var a := make_core("test_tiny", {"world.seed": 12})
	var b := make_core("test_tiny", {"world.seed": 12})
	for t in range(1, b.flora.count() + 1):
		b.flora.fertility_consumption[t] = 0.0
	b.env._setup_tables(b.params)
	_run(a, 3000)
	_run(b, 3000)
	var stats_a: Dictionary = a.env.take_period_stats()
	var grown := 0
	var harvested := 0
	for t in range(1, a.flora.count() + 1):
		grown += stats_a["growth"][t]
		harvested += stats_a["harvested"][t]
	check(grown > 0, "plants grew (%d biomass)" % grown)
	check_eq(harvested, 0, "nothing was harvested")
	var fa := _sum_fertility(a)
	var fb := _sum_fertility(b)
	check(fa < fb, "growth drains fertility via fertility_consumption (%d vs %d without it)" % [fa, fb])


func _sum_fertility(core: RefCounted) -> int:
	var s := 0
	for c in core.world.cell_count:
		s += core.world.fertility[c]
	return s


func test_growth_stall_hook_is_neutral_stub() -> void:
	var core := make_core("test_tiny", {"world.seed": 11})
	var w: RefCounted = core.world
	check_eq(core.env.growth_stall(0), 1.0, "no structure: no stall")
	for material in [1, 7, 255]:
		w.structure_material[5] = material
		check_eq(core.env.growth_stall(5), 1.0, "material %d: stub returns 1.0 until Phase 7" % material)


func test_moisture_spreads_from_water() -> void:
	# Left quarter water, rest soil; one day per tick and every cell sampled every tick, so the
	# field converges quickly.
	var core := make_core("test_tiny", {"world.seed": 10, "env.sample_fraction": 1.0,
			"time.ticks_per_hour": 1, "time.hours_per_day": 1, "env.rain_enabled": false,
			"env.climate_moisture_min": 0.1, "env.climate_moisture_max": 0.1})
	var w: RefCounted = core.world
	var water: int = core.substrates.id_of("water")
	var soil: int = core.substrates.id_of("soil")
	for y in w.height:
		for x in w.width:
			var c: int = w.index(x, y)
			w.substrate[c] = water if x < w.width / 4 else soil
			w.moisture[c] = 255 if x < w.width / 4 else 0
	_run(core, 300)
	var edge: int = w.width / 4
	var row: int = w.height / 2
	var near: int = w.moisture[w.index(edge, row)]
	var mid: int = w.moisture[w.index(edge + 4, row)]
	var far: int = w.moisture[w.index(w.width - 1, row)]
	check(near > mid and mid > far, "moisture falls off with distance from water (%d > %d > %d)" % [near, mid, far])


func _region_cells(core: RefCounted, x0: int, y0: int, size: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var soil: int = core.substrates.id_of("soil")
	for y in range(y0, y0 + size):
		for x in range(x0, x0 + size):
			var c: int = core.world.index(x, y)
			if core.world.substrate[c] == soil:
				out.append(c)
	return out


func _mean_fertility(core: RefCounted, cells: PackedInt32Array) -> float:
	var s := 0
	for c in cells:
		s += core.world.fertility[c]
	return float(s) / maxi(cells.size(), 1)
