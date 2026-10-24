## Headless profile harness for the Phase 1 spike: ms/tick (mean, p50, p95, max) and per-phase
## breakdown at several entity counts on the real map.
##
##   godot --headless --path . --script res://tools/profile_spike.gd -- \
##       [--counts=1000,10000,50000,100000] [--warmup=50] [--ticks=200] [--seed=N]
##       [--preset=NAME] [--set=param.id=value ...] [--out=batch_output/perf.json]
##       [--env-warmup=N]   run N entity-free ticks first so flora is mature when measuring
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")


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
	for kv: String in args.get("set", []):
		var parts := kv.split("=", true, 1)
		var def: Dictionary = params.definition(parts[0])
		params.set_value(parts[0], str_to_var(parts[1]) if not def.is_empty() else parts[1])
	var counts := PackedInt32Array()
	for c in str(args.get("counts", "1000,10000,50000,100000")).split(","):
		counts.append(int(c))
	var warmup := int(args.get("warmup", 50))
	var ticks := int(args.get("ticks", 200))
	var out_path: String = args.get("out", "res://batch_output/perf.json")

	var t0 := Time.get_ticks_msec()
	var core := SimCore.new()
	if not core.init_new(params):
		push_error(core.error)
		quit(2)
		return
	print("world %dx%d generated in %.1f s  %s" % [core.world.width, core.world.height,
			(Time.get_ticks_msec() - t0) / 1000.0, _fmt_fractions(core.terrain_stats["fractions"])])
	print("cpu: %s, %d logical cores, %s" % [OS.get_processor_name(), OS.get_processor_count(),
			Engine.get_version_info()["string"]])
	print("perception radius %d, decision interval %d, warmup %d, measured %d ticks\n" % [
			params.get_int("spike.perception_radius"), params.get_int("spike.decision_interval"),
			warmup, ticks])

	# --env-warmup=N: run N ticks with no entities first, so flora is mature when measuring.
	var env_warmup := int(args.get("env-warmup", 0))
	if env_warmup > 0:
		var tw := Time.get_ticks_msec()
		for t in env_warmup:
			core.step()
		var cover := 0
		for ft in range(1, core.flora.count() + 1):
			cover += core.env.coverage[ft]
		print("environment warmup: %d ticks (%s) in %.0f s; %d plants" % [env_warmup,
				core.time.describe(core.tick), (Time.get_ticks_msec() - tw) / 1000.0, cover])
	var rows := []
	print("environment pass: %s, %d samples/tick" % ["on" if core.env.enabled else "off", core.env.samples_per_tick])
	print("| entities | mean ms | p50 ms | p95 ms | max ms | tps (mean) | env | decide | propose | resolve | moves/tick | blocked/tick |")
	print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	for n in counts:
		core.spawn_spike(n)
		var spike: RefCounted = core.spike
		for t in warmup:
			core.step()
		if spike != null:
			spike.reset_timing()
		core.env.timing_usec = 0
		var samples := PackedFloat64Array()
		var moves := 0
		var blocked := 0
		for t in ticks:
			var s0 := Time.get_ticks_usec()
			core.step()
			samples.append((Time.get_ticks_usec() - s0) / 1000.0)
			if spike != null:
				moves += spike.last_moves
				blocked += spike.last_blocked
		var inv: String = spike.check_invariants() if spike != null else ""
		if not inv.is_empty():
			push_error("invariant violated at %d entities: %s" % [n, inv])
		var sorted := samples.duplicate()
		sorted.sort()
		var mean := _sum(samples) / ticks
		var timing: Dictionary = spike.timing_usec if spike != null else {"decide": 0, "propose": 0, "resolve": 0}
		var row := {
			"entities": core.spike_count(),
			"mean_ms": mean,
			"p50_ms": sorted[ticks / 2],
			"p95_ms": sorted[mini(ticks - 1, int(ceil(ticks * 0.95)) - 1)],
			"max_ms": sorted[ticks - 1],
			"tps": 1000.0 / mean,
			"env_ms": core.env.timing_usec / 1000.0 / ticks,
			"decide_ms": timing["decide"] / 1000.0 / ticks,
			"propose_ms": timing["propose"] / 1000.0 / ticks,
			"resolve_ms": timing["resolve"] / 1000.0 / ticks,
			"moves_per_tick": float(moves) / ticks,
			"blocked_per_tick": float(blocked) / ticks,
			"invariants_ok": inv.is_empty(),
		}
		rows.append(row)
		print("| %d | %.2f | %.2f | %.2f | %.2f | %.1f | %.2f | %.2f | %.2f | %.2f | %.0f | %.0f |" % [
				row["entities"], row["mean_ms"], row["p50_ms"], row["p95_ms"], row["max_ms"],
				row["tps"], row["env_ms"], row["decide_ms"], row["propose_ms"], row["resolve_ms"],
				row["moves_per_tick"], row["blocked_per_tick"]])

	var report := {
		"timestamp": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info()["string"],
		"cpu": OS.get_processor_name(),
		"cores": OS.get_processor_count(),
		"world": [core.world.width, core.world.height],
		"warmup": warmup,
		"ticks": ticks,
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


static func _fmt_fractions(fractions: Dictionary) -> String:
	var parts := PackedStringArray()
	for k: String in fractions:
		parts.append("%s %.1f%%" % [k, fractions[k] * 100.0])
	return ", ".join(parts)
