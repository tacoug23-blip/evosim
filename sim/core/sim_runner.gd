## Runs SimCore ticks on a worker thread, so the render frame rate never waits on a tick.
##
## Speed is a multiple of sim.base_tps; SPEED_PAUSED stops, SPEED_MAX runs ticks back to back.
## The main thread talks to the runner only through the public methods (mutex-guarded) and
## gets entity positions through snapshots the worker takes between ticks. hold() parks the
## worker so the main thread can safely touch the core (save, load, respawn).
extends RefCounted

const SPEED_PAUSED := 0.0
const SPEED_MAX := -1.0
## Longest single sleep while pacing a fixed speed. Scheduler granularity, not a sim tunable.
const PACING_SLEEP_USEC := 1000
## Weight of the newest sample in the tick-time moving average.
const EMA_WEIGHT := 0.1

var core: RefCounted

var _thread: Thread
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _quit := false
var _held := false
var _parked := false
var _speed := SPEED_PAUSED
var _pending_steps := 0
var _base_tps := 1.0
var _snapshot_requested := false
var _snapshot := {}
var _tick := 0
var _ticks_run := 0
var _last_tick_usec := 0
var _tick_usec_ema := 0.0


func start(p_core: RefCounted, base_tps: float) -> void:
	core = p_core
	_base_tps = base_tps
	_tick = core.tick
	_quit = false
	_thread = Thread.new()
	_thread.start(_run)


func stop() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_wake.post()
	_thread.wait_to_finish()
	_thread = null


func set_speed(multiplier: float) -> void:
	_mutex.lock()
	_speed = multiplier
	_mutex.unlock()
	_wake.post()


func get_speed() -> float:
	_mutex.lock()
	var s := _speed
	_mutex.unlock()
	return s


## Run exactly one tick, then stay paused.
func step_once() -> void:
	_mutex.lock()
	_speed = SPEED_PAUSED
	_pending_steps += 1
	_mutex.unlock()
	_wake.post()


func request_snapshot() -> void:
	_mutex.lock()
	_snapshot_requested = true
	_mutex.unlock()
	_wake.post()


## The newest snapshot since the last call, or {} if none arrived.
func take_snapshot() -> Dictionary:
	_mutex.lock()
	var s := _snapshot
	_snapshot = {}
	_mutex.unlock()
	return s


## Park the worker between ticks. Returns once it is parked; the core is then safe to touch
## from the calling thread until release().
func hold() -> void:
	_mutex.lock()
	_held = true
	_mutex.unlock()
	_wake.post()
	while true:
		_mutex.lock()
		var parked := _parked
		_mutex.unlock()
		if parked:
			return
		OS.delay_usec(PACING_SLEEP_USEC)


## Resume after hold(). Pass a new core if the held section replaced it (load).
func release(new_core: RefCounted = null) -> void:
	_mutex.lock()
	if new_core != null:
		core = new_core
		_tick = core.tick
	_held = false
	_mutex.unlock()
	_wake.post()


func stats() -> Dictionary:
	_mutex.lock()
	var s := {
		"tick": _tick,
		"ticks_run": _ticks_run,
		"speed": _speed,
		"last_tick_ms": _last_tick_usec / 1000.0,
		"tick_ms_ema": _tick_usec_ema / 1000.0,
	}
	_mutex.unlock()
	return s


func _run() -> void:
	var next_due := Time.get_ticks_usec()
	while true:
		_mutex.lock()
		if _quit:
			_mutex.unlock()
			return
		if _held:
			_parked = true
			_mutex.unlock()
			_wake.wait()
			continue
		_parked = false
		var speed := _speed
		var do_step := _pending_steps > 0
		if do_step:
			_pending_steps -= 1
		var want_snapshot := _snapshot_requested
		_mutex.unlock()

		if want_snapshot:
			_publish_snapshot()
		var now := Time.get_ticks_usec()
		if do_step or speed == SPEED_MAX:
			_do_tick()
			next_due = Time.get_ticks_usec()
		elif speed == SPEED_PAUSED:
			_wake.wait()
			next_due = Time.get_ticks_usec()
		elif now < next_due:
			OS.delay_usec(mini(next_due - now, PACING_SLEEP_USEC))
		else:
			_do_tick()
			var interval := int(1_000_000.0 / (_base_tps * speed))
			next_due += interval
			# If ticks are slower than the requested speed, run flat out rather than
			# accumulating a backlog to catch up on.
			if next_due < now:
				next_due = now


func _do_tick() -> void:
	var t0 := Time.get_ticks_usec()
	core.step()
	var dt := Time.get_ticks_usec() - t0
	_mutex.lock()
	_tick = core.tick
	_ticks_run += 1
	_last_tick_usec = dt
	_tick_usec_ema = dt if _ticks_run == 1 else lerpf(_tick_usec_ema, dt, EMA_WEIGHT)
	_mutex.unlock()


func _publish_snapshot() -> void:
	var snap: Dictionary = core.render_snapshot()
	_mutex.lock()
	_snapshot = snap
	_snapshot_requested = false
	_mutex.unlock()
