## Threaded runner: speed controls, single-step, hold/release, snapshots.
extends "res://tests/test_base.gd"

const SimRunner := preload("res://sim/core/sim_runner.gd")

const TIMEOUT_MSEC := 10000
const POLL_USEC := 2000


func _wait_for(runner: RefCounted, cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if cond.call(runner.stats()):
			return true
		OS.delay_usec(POLL_USEC)
	return false


func test_submit_and_probe() -> void:
	var core := make_core("test_tiny", {"world.seed": 2})
	var runner := SimRunner.new()
	runner.start(core, 10.0)
	var w: RefCounted = core.world
	var soil: int = core.substrates.id_of("soil")
	var cell := -1
	for c in w.cell_count:
		if w.substrate[c] == soil and w.flora_type[c] == 0:
			cell = c
			break
	var tree: int = core.flora.id_of("tree")
	runner.submit(func(c: RefCounted) -> void: c.env.plant(cell, tree, 200))
	runner.request_probe(cell)
	var p := {}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		p = runner.probe_result()
		if p.get("cell", -1) == cell:
			break
		OS.delay_usec(POLL_USEC)
	runner.stop()
	check_eq(p.get("flora", ""), "tree", "submitted edit ran on the sim thread before the probe")
	check_eq(p.get("biomass", -1), 200, "probe reads the planted biomass")
	check_eq(p.get("substrate", ""), "soil", "probe reads the substrate")


func test_speed_controls() -> void:
	var core := make_core("test_tiny", {"world.seed": 2})
	var spawned: int = core.spawn_founders()["spawned"]
	var runner := SimRunner.new()
	runner.start(core, 10.0)

	OS.delay_msec(100)
	check_eq(runner.stats()["ticks_run"], 0, "starts paused")

	runner.step_once()
	check(_wait_for(runner, func(s: Dictionary) -> bool: return s["ticks_run"] == 1), "single step runs one tick")
	OS.delay_msec(100)
	check_eq(runner.stats()["ticks_run"], 1, "stays paused after the step")

	runner.set_speed(SimRunner.SPEED_MAX)
	check(_wait_for(runner, func(s: Dictionary) -> bool: return s["ticks_run"] >= 50), "max speed runs")

	runner.hold()
	var held: int = runner.stats()["ticks_run"]
	OS.delay_msec(100)
	check_eq(runner.stats()["ticks_run"], held, "hold parks the worker")
	check_eq(core.tick, held + 0, "core tick matches while held")
	runner.release()
	check(_wait_for(runner, func(s: Dictionary) -> bool: return s["ticks_run"] > held), "release resumes")

	runner.set_speed(1.0)  # 10 ticks/s
	var t0: int = runner.stats()["ticks_run"]
	OS.delay_msec(1000)
	var paced: int = runner.stats()["ticks_run"] - t0
	check(paced >= 7 and paced <= 13, "1x paces at base_tps (%d ticks in 1 s)" % paced)

	runner.set_speed(SimRunner.SPEED_PAUSED)
	runner.request_snapshot()
	var snap := {}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while snap.is_empty() and Time.get_ticks_msec() < deadline:
		snap = runner.take_snapshot()
		OS.delay_usec(POLL_USEC)
	check_eq(snap.get("entity_count", -1), core.entities.count, "snapshot delivered while paused")
	check(spawned > 0, "founders spawned")
	check_eq((snap.get("entity_x", PackedByteArray()) as PackedByteArray).size(), core.entities.capacity * 4, "snapshot positions")
	runner.stop()
	check_eq(core.entities.check_invariants(), "", "invariants after threaded run")
