## Headless profile harness: ms/tick (mean, p50, p95, max) and per-phase breakdown with real
## entities at several counts, on the real map, flora enabled.
##
##   godot --headless --path . --script res://tools/profile.gd -- \
##       [--counts=10000,50000,100000] [--warmup=500] [--ticks=200] [--seed=N]
##       [--env-warmup=N]   entity-free ticks first, so flora is mature when measuring
##       [--season=spring|summer|autumn|winter]   before each count, run entity-free ticks until
##                          its measured ticks fall early in that season (so every row is measured
##                          in the same season; counts otherwise run one after another)
##       [--thin-flora=SHARE]   just before each count spawns, keep each plant with this
##                          probability (fixed seed): a scarce-food, searching population
##       [--group-size=250] [--preset=NAME] [--set=param.id=value ...] [--out=res://batch_output/perf.json]
##
## Entities come from the founder spawner: count / group-size groups of exactly group-size.
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")

const PHASES := ["env", "decide", "propose", "resolve", "deaths", "interact", "corpses"]


func _initialize() -> void:
	var args := _parse_args()
	var params := Registry.new()
	if not params.load_file():
		quit(2)
		return
	if args.has("preset"):
		params.apply_preset(args["preset"])
	if args.has("seed"):
		params.set_value("world.seed", int(args["seed"]))
	for kv: String in args["set"]:
		var parts := kv.split("=", true, 1)
		params.set_value(parts[0], str_to_var(parts[1]))
	var counts := PackedInt32Array()
	for c in str(args.get("counts", "10000,50000,100000")).split(","):
		counts.append(int(c))
	var warmup := int(args.get("warmup", 500))
	var ticks := int(args.get("ticks", 200))
	var group_size := int(args.get("group-size", 250))
	var out_path: String = args.get("out", "res://batch_output/perf.json")

	var t0 := Time.get_ticks_msec()
	var core := SimCore.new()
	if not core.init_new(params):
		push_error(core.error)
		quit(2)
		return
	print("world %dx%d generated in %.1f s" % [core.world.width, core.world.height,
			(Time.get_ticks_msec() - t0) / 1000.0])
	print("cpu: %s, %d logical cores, %s" % [OS.get_processor_name(), OS.get_processor_count(),
			Engine.get_version_info()["string"]])
	var env_warmup := int(args.get("env-warmup", 0))
	if env_warmup > 0:
		var tw := Time.get_ticks_msec()
		for t in env_warmup:
			core.step()
		print("environment warmup: %d ticks (%s) in %.0f s; %d plants" % [env_warmup,
				core.time.describe(core.tick), (Time.get_ticks_msec() - tw) / 1000.0, _plants(core)])
	print("decision interval %d, entity warmup %d, measured %d ticks, founder groups of %d\n" % [
			params.get_int("entity.decision_interval"), warmup, ticks, group_size])

	var rows := []
	var head := "| entities | mean ms | p50 ms | p95 ms | max ms | tps (mean) |"
	var sep := "|---:|---:|---:|---:|---:|---:|"
	for p: String in PHASES:
		head += " %s |" % p
		sep += "---:|"
	print(head + " decisions/tick | moves/tick | blocked/tick | deaths | measured from |")
	print(sep + "---:|---:|---:|---:|---|")
	var season := ["spring", "summer", "autumn", "winter"].find(str(args.get("season", "")))
	for n in counts:
		core.entities.clear()
		if season >= 0:
			# Measured ticks start two days into the season.
			var tpy: int = core.time.ticks_per_year
			var target := posmod(season * core.time.ticks_per_season + 2 * core.time.ticks_per_day - warmup, tpy)
			while posmod(core.tick, tpy) != target:
				core.step()
		if args.has("thin-flora"):
			var keep := float(args["thin-flora"])
			var rng := RandomNumberGenerator.new()
			rng.seed = 777
			var ft: PackedByteArray = core.world.flora_type
			var fb: PackedByteArray = core.world.flora_biomass
			for c in core.world.cell_count:
				if ft[c] != 0 and rng.randf() >= keep:
					ft[c] = 0
					fb[c] = 0
			core.env.recount()
			print("flora thinned to %.0f%%: %d plants" % [keep * 100.0, _plants(core)])
		@warning_ignore("integer_division")
		var groups := maxi(1, (n + group_size - 1) / group_size)
		var spawned: int = core.spawn_founders({"groups": groups, "size_min": group_size,
				"size_max": group_size, "spacing": _spacing(core, groups)})["spawned"]
		for t in warmup:
			core.step()
		core.entities.reset_timing()
		core.env.timing_usec = 0
		var deaths_before: int = core.entities.deaths_by_cause[0]
		var measured_from: String = core.time.describe(core.tick)
		var samples := PackedFloat64Array()
		var moves := 0
		var decisions := 0
		var blocked := 0
		for t in ticks:
			var s0 := Time.get_ticks_usec()
			core.step()
			samples.append((Time.get_ticks_usec() - s0) / 1000.0)
			moves += core.entities.last_moves
			decisions += core.entities.last_decisions
			blocked += core.entities.last_blocked
		var inv: String = core.entities.check_invariants()
		if not inv.is_empty():
			push_error("invariant violated at %d entities: %s" % [n, inv])
		var sorted := samples.duplicate()
		sorted.sort()
		var mean := _sum(samples) / ticks
		var timing: Dictionary = core.entities.timing_usec
		var phase_ms := {"env": core.env.timing_usec / 1000.0 / ticks,
				"corpses": core.corpses.timing_usec / 1000.0 / ticks}
		for p: String in ["decide", "propose", "deaths", "resolve", "interact"]:
			phase_ms[p] = timing[p] / 1000.0 / ticks
		var row := {
			"requested": n, "spawned": spawned, "entities": core.entities.count,
			"mean_ms": mean, "p50_ms": sorted[ticks / 2],
			"p95_ms": sorted[mini(ticks - 1, int(ceil(ticks * 0.95)) - 1)],
			"max_ms": sorted[ticks - 1], "tps": 1000.0 / mean, "phase_ms": phase_ms,
			"moves_per_tick": float(moves) / ticks, "blocked_per_tick": float(blocked) / ticks,
			"decisions_per_tick": float(decisions) / ticks,
			"deaths_during_measure": core.entities.deaths_by_cause[0] - deaths_before,
			"invariants_ok": inv.is_empty(), "measured_from": measured_from,
		}
		rows.append(row)
		var line := "| %d | %.2f | %.2f | %.2f | %.2f | %.1f |" % [row["entities"], mean, row["p50_ms"],
				row["p95_ms"], row["max_ms"], row["tps"]]
		for p: String in PHASES:
			line += " %.2f |" % phase_ms[p]
		print(line + " %.0f | %.0f | %.0f | %d | %s |" % [row["decisions_per_tick"], row["moves_per_tick"], row["blocked_per_tick"],
				row["deaths_during_measure"], measured_from])

	var report := {
		"timestamp": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info()["string"],
		"cpu": OS.get_processor_name(),
		"cores": OS.get_processor_count(),
		"world": [core.world.width, core.world.height],
		"env_warmup": env_warmup, "warmup": warmup, "ticks": ticks, "group_size": group_size,
		"params": params.snapshot(),
		"rows": rows,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path).get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "\t", true, true))
		f.close()
		print("\nwrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


## Group-centre spacing that fits `groups` centres comfortably on the map.
static func _spacing(core: RefCounted, groups: int) -> int:
	var area: float = core.world.width * core.world.height
	return maxi(8, int(sqrt(area / maxi(groups, 1)) * 0.5))


static func _plants(core: RefCounted) -> int:
	var n := 0
	for t in range(1, core.flora.count() + 1):
		n += core.env.coverage[t]
	return n


func _parse_args() -> Dictionary:
	var out := {"set": []}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv[0] == "set" and kv.size() == 2:
			out["set"].append(kv[1])
		else:
			out[kv[0]] = kv[1] if kv.size() == 2 else "true"
	return out


static func _sum(values: PackedFloat64Array) -> float:
	var s := 0.0
	for v in values:
		s += v
	return s
