## Phase 2 acceptance: fertility drops under heavy harvest and recovers when left alone.
##
## After a warmup, one region is harvested every day (half of every plant's biomass) for
## --harvest-seasons, then left alone for --rest-seasons. A second, untouched region of similar
## soil is the control. Daily mean fertility, mean biomass, and plant count for both regions go to
## CSV and an SVG chart.
##
##   godot --headless --path . --script res://tools/harvest_experiment.gd -- [--size=N]
##       [--region=64] [--warmup-years=1] [--harvest-seasons=1] [--rest-seasons=4]
##       [--set=param.id=value ...] [--out=res://batch_output/harvest]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SvgChart := preload("res://tools/svg_chart.gd")

## Share of each plant's biomass taken per daily harvest.
const HARVEST_SHARE := 0.5


func _initialize() -> void:
	var args := {"set": []}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv[0] == "set" and kv.size() == 2:
			args["set"].append(kv[1])
		elif kv.size() == 2:
			args[kv[0]] = kv[1]
	var params := Registry.new()
	params.load_file()
	if args.has("size"):
		params.set_value("world.width", int(args["size"]))
		params.set_value("world.height", int(args["size"]))
	for kv: String in args["set"]:
		var parts := kv.split("=", true, 1)
		params.set_value(parts[0], str_to_var(parts[1]))
	var region_size := int(args.get("region", 64))
	var out_dir: String = args.get("out", "res://batch_output/harvest")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var core := SimCore.new()
	core.init_new(params)
	var time: RefCounted = core.time
	var blocks := _best_soil_blocks(core, region_size)
	var harvested_cells := _soil_cells(core, blocks[0], region_size)
	var control_cells := _soil_cells(core, blocks[1], region_size)
	print("world %dx%d; harvest region at %s (%d soil cells), control at %s (%d soil cells)" % [
			core.world.width, core.world.height, blocks[0], harvested_cells.size(), blocks[1],
			control_cells.size()])

	var warmup: int = int(args.get("warmup-years", 1)) * time.ticks_per_year
	for i in warmup:
		core.step()
	var harvest_days: int = int(args.get("harvest-seasons", 1)) * time.days_per_season
	var rest_days: int = int(args.get("rest-seasons", 4)) * time.days_per_season
	var rows := []
	var taken := 0
	for day in harvest_days + rest_days:
		var harvesting := day < harvest_days
		# Measure at the start of the day, before that day's harvest.
		rows.append({"day": day, "phase": "harvest" if harvesting else "rest",
				"h": _measure(core, harvested_cells), "c": _measure(core, control_cells)})
		if harvesting:
			for c in harvested_cells:
				var b: int = core.world.flora_biomass[c]
				if b > 1:
					taken += core.env.harvest(c, roundi(b * HARVEST_SHARE))["removed"]
		for i in time.ticks_per_day:
			core.step()
	rows.append({"day": harvest_days + rest_days, "phase": "rest",
			"h": _measure(core, harvested_cells), "c": _measure(core, control_cells)})

	var f := FileAccess.open(out_dir + "/harvest_fertility.csv", FileAccess.WRITE)
	f.store_line("day,phase,harvest_fertility,harvest_biomass,harvest_plants,control_fertility,control_biomass,control_plants")
	for r: Dictionary in rows:
		f.store_line("%d,%s,%.2f,%.2f,%d,%.2f,%.2f,%d" % [r["day"], r["phase"], r["h"][0], r["h"][1],
				r["h"][2], r["c"][0], r["c"][1], r["c"][2]])
	f.close()

	var labels := PackedStringArray()
	var hf := PackedFloat64Array()
	var cf := PackedFloat64Array()
	for r: Dictionary in rows:
		var d: int = r["day"]
		labels.append("day %d" % d if d % time.days_per_season == 0 else "")
		hf.append(r["h"][0])
		cf.append(r["c"][0])
	var svg := SvgChart.line_chart(
			"Mean fertility: harvested region (daily 50%% harvest for %d days, then rest) vs control" % harvest_days,
			"fertility (0-255)", labels,
			[{"name": "harvested", "color": Color(0.75, 0.3, 0.2), "values": hf},
			{"name": "control", "color": Color(0.25, 0.45, 0.7), "values": cf}], 1)
	var sf := FileAccess.open(out_dir + "/harvest_fertility.svg", FileAccess.WRITE)
	sf.store_string(svg)
	sf.close()

	var start: Dictionary = rows[0]
	var low: Dictionary = rows[harvest_days]
	var end: Dictionary = rows[-1]
	var drop: float = start["h"][0] - low["h"][0]
	var recovered: float = end["h"][0] - low["h"][0]
	print("harvested %d biomass units over %d days" % [taken, harvest_days])
	print("harvested region fertility: %.1f -> %.1f after harvest (%+.1f) -> %.1f after %d days rest (%+.1f, %.0f%% of the drop)" % [
			start["h"][0], low["h"][0], -drop, end["h"][0], rest_days, recovered,
			100.0 * recovered / maxf(drop, 0.001)])
	print("control region fertility:   %.1f -> %.1f -> %.1f" % [start["c"][0], low["c"][0], end["c"][0]])
	var ok := drop > 0.0 and recovered > 0.0
	print("RESULT: %s (drops under harvest, recovers when left alone)" % ("PASS" if ok else "FAIL"))
	print("wrote %s/{harvest_fertility.csv, harvest_fertility.svg}" % ProjectSettings.globalize_path(out_dir))
	quit(0 if ok else 1)


## [mean fertility, mean biomass per cell, plant count].
func _measure(core: RefCounted, cells: PackedInt32Array) -> Array:
	var fert := 0
	var bio := 0
	var plants := 0
	for c in cells:
		fert += core.world.fertility[c]
		bio += core.world.flora_biomass[c]
		if core.world.flora_type[c] != 0:
			plants += 1
	var n := maxi(cells.size(), 1)
	return [float(fert) / n, float(bio) / n, plants]


## The two non-overlapping region-sized blocks with the most soil.
func _best_soil_blocks(core: RefCounted, size: int) -> Array:
	var soil: int = core.substrates.id_of("soil")
	var scored := []
	for by in range(0, core.world.height - size + 1, size):
		for bx in range(0, core.world.width - size + 1, size):
			var n := 0
			for y in range(by, by + size, 4):
				for x in range(bx, bx + size, 4):
					if core.world.substrate[core.world.index(x, y)] == soil:
						n += 1
			scored.append([n, Vector2i(bx, by)])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	return [scored[0][1], scored[1][1]]


func _soil_cells(core: RefCounted, origin: Vector2i, size: int) -> PackedInt32Array:
	var soil: int = core.substrates.id_of("soil")
	var out := PackedInt32Array()
	for y in range(origin.y, origin.y + size):
		for x in range(origin.x, origin.x + size):
			var c: int = core.world.index(x, y)
			if core.world.substrate[c] == soil:
				out.append(c)
	return out
