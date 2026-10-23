## Spike determinism and the one-per-cell invariant over long runs.
extends "res://tests/test_base.gd"

const TICKS := 1000


func _run(seed_value: int, ticks: int, overrides: Dictionary = {}) -> Dictionary:
	var o := overrides.duplicate()
	o["world.seed"] = seed_value
	var core := make_core("test_tiny", o)
	core.spawn_spike(core.params.get_int("spike.entity_count"))
	var first_violation := ""
	var moves := 0
	for t in ticks:
		core.step()
		moves += core.spike.last_moves
		if first_violation.is_empty():
			var inv: String = core.spike.check_invariants()
			if not inv.is_empty():
				first_violation = "tick %d: %s" % [core.tick, inv]
	return {"hash": core.spike.hash_state(), "full": core.full_hash(), "violation": first_violation,
			"moves": moves, "count": core.spike.count}


func test_same_seed_same_state_after_1000_ticks() -> void:
	var a := _run(5, TICKS)
	var b := _run(5, TICKS)
	check_eq(a["violation"], "", "run A keeps one entity per cell")
	check_eq(b["violation"], "", "run B keeps one entity per cell")
	check_eq(a["hash"], b["hash"], "entity-state hash after %d ticks" % TICKS)
	check_eq(a["full"], b["full"], "full-state hash after %d ticks" % TICKS)
	check(a["moves"] > a["count"] * 50, "entities actually move (%d moves)" % a["moves"])
	var c := _run(6, TICKS)
	check(a["hash"] != c["hash"], "different seed diverges")


func test_thread_count_does_not_change_results() -> void:
	var single := _run(5, 200, {"sim.worker_threads": 1})
	for threads in [2, 3, 8]:
		var multi := _run(5, 200, {"sim.worker_threads": threads, "sim.parallel_min_items": 1})
		check_eq(multi["violation"], "", "%d threads keep one entity per cell" % threads)
		check_eq(multi["hash"], single["hash"], "%d threads match single-threaded" % threads)


func test_dense_crowd_keeps_one_per_cell() -> void:
	var r := _run(9, 300, {"world.width": 128, "world.height": 128, "spike.entity_count": 6000})
	check_eq(r["violation"], "", "dense crowd invariant")
	check_eq(r["count"], 6000, "all spawned")


func test_spawn_clamps_to_passable_cells() -> void:
	var r := _run(4, 20, {"world.width": 64, "world.height": 64, "spike.entity_count": 100000})
	check(r["count"] < 4096, "clamped below cell count (%d)" % r["count"])
	check_eq(r["violation"], "", "full map invariant")
