## Runs the same seeded world at several thread counts and prints the hashes, which must match.
##
##   godot --headless --path . --script res://tools/thread_hash_check.gd -- [--size=512]
##       [--ticks=7680] [--threads=1,3,8] [--spike=N] [--seed=N]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")


func _initialize() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var size := int(args.get("size", 512))
	var ticks := int(args.get("ticks", 7680))
	var spike := int(args.get("spike", 0))
	var seed_value := int(args.get("seed", 1337))
	var results := []
	for threads_text in str(args.get("threads", "1,3,8")).split(","):
		var threads := int(threads_text)
		var params := Registry.new()
		params.load_file()
		params.apply_overrides({"world.width": size, "world.height": size, "world.seed": seed_value,
				"sim.worker_threads": threads, "sim.parallel_min_items": 1})
		var core := SimCore.new()
		core.init_new(params)
		core.spawn_spike(spike)
		var t0 := Time.get_ticks_msec()
		for i in ticks:
			core.step()
		var cover := 0
		for t in range(1, core.flora.count() + 1):
			cover += core.env.coverage[t]
		results.append(core.full_hash())
		print("threads=%d  ticks=%d (%s)  %.1f s  plants=%d  spike=%d\n  world hash %s\n  full hash  %s" % [
				threads, ticks, core.time.describe(core.tick), (Time.get_ticks_msec() - t0) / 1000.0,
				cover, core.spike_count(), core.world_hash(), results[-1]])
	var same := results.all(func(h: String) -> bool: return h == results[0])
	print("RESULT: %s (full hashes %s)" % ["PASS" if same else "FAIL", "identical" if same else "DIFFER"])
	quit(0 if same else 1)
