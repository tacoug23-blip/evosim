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


func test_speed_controls() -> void:
	var core := make_core("test_tiny", {"world.seed": 2})
	core.spawn_spike(300)
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
	check_eq(snap.get("spike_count", -1), 300, "snapshot delivered while paused")
	check_eq((snap.get("spike_x", PackedByteArray()) as PackedByteArray).size(), 300 * 4, "snapshot positions")
	runner.stop()
	check_eq(core.spike.check_invariants(), "", "invariants after threaded run")
