## Decide micro-benchmark: single-threaded µs per decide_one() on a steady-state population.
## The first run builds the state (mature flora, founders, entity warmup) and saves it; later
## runs load it, so a decide change can be timed in seconds. The printed output hash covers what
## decide writes (action, target, heading, scores, memory), so a pure optimisation must keep it.
##
##   godot --headless --path . --script res://tools/decide_bench.gd -- [--state=user://decide_bench.evosave]
##       [--entities=100000] [--env-warmup=38400] [--warmup=2000] [--repeats=3] [--rebuild]
##       [--ticks=N]   then time N whole ticks from the same state (all phases, all threads)
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SaveLoad := preload("res://sim/io/save_load.gd")


func _initialize() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() == 2 else "true"
	var path: String = args.get("state", "user://decide_bench.evosave")
	var core: RefCounted
	if args.has("rebuild") or not FileAccess.file_exists(path):
		core = _build(args)
		var err := SaveLoad.save(core, path)
		if err != OK:
			push_error("save failed: %s" % error_string(err))
			quit(2)
			return
		print("saved state to %s" % ProjectSettings.globalize_path(path))
	var loaded := SaveLoad.load_file(path)
	if loaded["core"] == null:
		push_error(loaded["error"])
		quit(2)
		return
	core = loaded["core"]
	var es: RefCounted = core.entities
	es.begin_tick(core.tick)
	var slots := PackedInt32Array()
	for i in es.capacity:
		if es.alive[i] != 0:
			slots.append(i)
	print("state: %s, %d entities" % [core.time.describe(core.tick), slots.size()])

	# First pass from the loaded state: this is the output that must not change.
	var t0 := Time.get_ticks_usec()
	for i in slots:
		es.decide_one(i)
	var first := Time.get_ticks_usec() - t0
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for arr: StringName in [&"action", &"target", &"heading", &"scores", &"neighbors", &"water_dist",
			&"mem_kind", &"mem_cell", &"mem_tick", &"mem_head"]:
		ctx.update(var_to_bytes(es.get(arr)))
	var out_hash := ctx.finish().hex_encode()

	var best := first
	for r in int(args.get("repeats", 3)):
		t0 = Time.get_ticks_usec()
		for i in slots:
			es.decide_one(i)
		best = mini(best, Time.get_ticks_usec() - t0)
	var counts := PackedInt32Array()
	counts.resize(es.ACTIONS)
	for i in slots:
		counts[es.action[i]] += 1
	var mix := []
	for a in es.ACTIONS:
		if counts[a] > 0:
			mix.append("%s %d" % [es.ACTION_NAMES[a], counts[a]])
	print("decide_one: first pass %.2f us, best %.2f us per decision (single thread)" % [
			float(first) / slots.size(), float(best) / slots.size()])
	print("chosen: %s" % ", ".join(mix))
	print("output hash %s" % out_hash)

	# Optional: whole ticks from the same state, every phase, all worker threads.
	var ticks := int(args.get("ticks", 0))
	if ticks > 0:
		es.reset_timing()
		core.env.timing_usec = 0
		var t1 := Time.get_ticks_usec()
		for t in ticks:
			core.step()
		var ms := (Time.get_ticks_usec() - t1) / 1000.0 / ticks
		var phases := ["env %.2f" % (core.env.timing_usec / 1000.0 / ticks)]
		for p: String in es.timing_usec:
			phases.append("%s %.2f" % [p, es.timing_usec[p] / 1000.0 / ticks])
		phases.append("corpses %.2f" % (core.corpses.timing_usec / 1000.0 / ticks))
		print("%d ticks: %.2f ms/tick (%.1f ticks/s); %s ms" % [ticks, ms, 1000.0 / ms, ", ".join(phases)])
	quit(0)


func _build(args: Dictionary) -> RefCounted:
	var params := Registry.new()
	params.load_file()
	var core := SimCore.new()
	core.init_new(params)
	var tw := Time.get_ticks_msec()
	for t in int(args.get("env-warmup", 38400)):
		core.step()
	print("environment warmup to %s in %.0f s" % [core.time.describe(core.tick), (Time.get_ticks_msec() - tw) / 1000.0])
	var n := int(args.get("entities", 100000))
	@warning_ignore("integer_division")
	var groups := maxi(1, (n + 249) / 250)
	var area: float = core.world.width * core.world.height
	core.spawn_founders({"groups": groups, "size_min": 250, "size_max": 250,
			"spacing": maxi(8, int(sqrt(area / groups) * 0.5))})
	tw = Time.get_ticks_msec()
	for t in int(args.get("warmup", 2000)):
		core.step()
	print("entity warmup in %.0f s, %d entities" % [(Time.get_ticks_msec() - tw) / 1000.0, core.entities.count])
	return core
