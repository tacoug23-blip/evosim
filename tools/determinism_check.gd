## Full-scale determinism check (the Phase 1 acceptance run): default map and entity count.
##   1. Generate the world twice from the same seed; world hashes must match.
##   2. Run the spike N ticks on each, checking one-per-cell every tick; entity hashes match.
##   3. Save run A, load it, and compare world and full-state hashes.
##
##   godot --headless --path . --script res://tools/determinism_check.gd -- [--ticks=1000]
##       [--entities=N] [--check-every=1]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SaveLoad := preload("res://sim/io/save_load.gd")

const SAVE_PATH := "user://determinism_check.evosave"


func _initialize() -> void:
	var ticks := 1000
	var entities := -1
	var check_every := 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ticks="):
			ticks = int(arg.trim_prefix("--ticks="))
		elif arg.begins_with("--entities="):
			entities = int(arg.trim_prefix("--entities="))
		elif arg.begins_with("--check-every="):
			check_every = maxi(1, int(arg.trim_prefix("--check-every=")))

	var ok := true
	var runs := []
	for run_index in 2:
		var params := Registry.new()
		params.load_file()
		var t0 := Time.get_ticks_msec()
		var core := SimCore.new()
		core.init_new(params)
		var gen_s := (Time.get_ticks_msec() - t0) / 1000.0
		var world_hash: String = core.world_hash()
		var n := entities if entities >= 0 else params.get_int("spike.entity_count")
		core.spawn_spike(n)
		var violation := ""
		var tick_ms := PackedFloat64Array()
		for t in ticks:
			var s0 := Time.get_ticks_usec()
			core.step()
			tick_ms.append((Time.get_ticks_usec() - s0) / 1000.0)
			if violation.is_empty() and core.tick % check_every == 0:
				violation = core.spike.check_invariants()
				if not violation.is_empty():
					violation = "tick %d: %s" % [core.tick, violation]
		var run := {"core": core, "world_hash": world_hash, "spike_hash": core.spike.hash_state(),
				"violation": violation}
		runs.append(run)
		print("run %d: %dx%d world in %.1f s, %d entities, %d ticks, mean %.1f ms/tick (first 100: %.1f, last 100: %.1f)" % [
				run_index + 1, core.world.width, core.world.height, gen_s, core.spike.count, ticks,
				_mean(tick_ms, 0, ticks), _mean(tick_ms, 0, mini(100, ticks)),
				_mean(tick_ms, maxi(0, ticks - 100), ticks)])
		print("  world hash  %s" % world_hash)
		print("  entity hash %s" % run["spike_hash"])
		print("  one-per-cell: %s" % ("ok (checked every %d ticks)" % check_every if violation.is_empty() else violation))
		ok = ok and violation.is_empty()

	var same_world: bool = runs[0]["world_hash"] == runs[1]["world_hash"]
	var same_entities: bool = runs[0]["spike_hash"] == runs[1]["spike_hash"]
	print("same seed -> identical world hash: %s" % same_world)
	print("same seed -> identical entity hash after %d ticks: %s" % [ticks, same_entities])
	ok = ok and same_world and same_entities

	var core_b: RefCounted = runs[1]["core"]
	runs.clear()  # drop run A so the save/load test fits in memory comfortably
	var t_save := Time.get_ticks_msec()
	var err := SaveLoad.save(core_b, SAVE_PATH)
	var save_s := (Time.get_ticks_msec() - t_save) / 1000.0
	var size_mb := FileAccess.open(SAVE_PATH, FileAccess.READ).get_length() / 1048576.0
	var t_load := Time.get_ticks_msec()
	var res := SaveLoad.load_file(SAVE_PATH)
	var load_s := (Time.get_ticks_msec() - t_load) / 1000.0
	var loaded: RefCounted = res["core"]
	var same_after_load: bool = err == OK and loaded != null \
			and loaded.world_hash() == core_b.world_hash() and loaded.full_hash() == core_b.full_hash()
	print("save %.1f s (%.1f MB), load+verify %.1f s -> identical world and full hash: %s" % [
			save_s, size_mb, load_s, same_after_load])
	ok = ok and same_after_load
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


static func _mean(values: PackedFloat64Array, from: int, to: int) -> float:
	if to <= from:
		return 0.0
	var s := 0.0
	for i in range(from, to):
		s += values[i]
	return s / (to - from)
