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
var _snapshot_layers := PackedStringArray()
var _commands: Array[Callable] = []
var _probe_cell := -1
var _probe_result := {}
var _entity_probe := Vector2i(-1, -1)
var _entity_result := {}
var _snapshot := {}
var _tick := 0
var _ticks_run := 0
var _last_tick_usec := 0
var _tick_usec_ema := 0.0
var _entities := 0
var _corpses := 0


func start(p_core: RefCounted, base_tps: float) -> void:
	core = p_core
	_base_tps = base_tps
	_tick = core.tick
	_entities = core.entities.count
	_corpses = core.corpses.count
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


## Ask for a render snapshot; `layers` names world layers to copy as well (see
## SimCore.render_snapshot). Requests made before the snapshot is taken are merged.
func request_snapshot(layers: PackedStringArray = PackedStringArray()) -> void:
	_mutex.lock()
	_snapshot_requested = true
	for layer_name in layers:
		if not _snapshot_layers.has(layer_name):
			_snapshot_layers.append(layer_name)
	_mutex.unlock()
	_wake.post()


## Ask the sim thread to read one cell between ticks (see SimCore.probe_cell). The UI must not
## read live world layers itself: parallel phases write them.
func request_probe(cell: int) -> void:
	_mutex.lock()
	_probe_cell = cell
	_mutex.unlock()
	_wake.post()


## Ask once for the inspector view of entity (slot, generation), answered between ticks.
## Request again to refresh; slot -1 clears the last result.
func request_entity_probe(slot: int, generation: int) -> void:
	_mutex.lock()
	_entity_probe = Vector2i(slot, generation)
	if slot < 0:
		_entity_result = {}
	_mutex.unlock()
	_wake.post()


## Latest entity probe: {"requested": Vector2i(slot, gen), ...describe() fields}, or {} until
## one arrives. Only "requested" is set if the entity is no longer alive.
func entity_probe_result() -> Dictionary:
	_mutex.lock()
	var r := _entity_result
	_mutex.unlock()
	return r


## The latest probe result ({} until one arrives).
func probe_result() -> Dictionary:
	_mutex.lock()
	var r := _probe_result
	_mutex.unlock()
	return r


## Queue fn(core) to run on the sim thread before the next tick (also while paused). For
## edits to sim state from the UI, such as the debug brush. A snapshot follows each batch.
func submit(fn: Callable) -> void:
	_mutex.lock()
	_commands.append(fn)
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
		_entities = core.entities.count
		_corpses = core.corpses.count
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
		"entities": _entities,
		"corpses": _corpses,
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
		var commands := _commands
		var probe := _probe_cell
		var entity_probe := _entity_probe
		_entity_probe = Vector2i(-1, -1)
		_probe_cell = -1
		_commands = []
		_mutex.unlock()

		# Commands (debug brush and the like) run here, between ticks, on the sim thread.
		for cmd in commands:
			cmd.call(core)
		if not commands.is_empty():
			_mutex.lock()
			_entities = core.entities.count
			_corpses = core.corpses.count
			_mutex.unlock()
		if entity_probe.x >= 0:
			var er: Dictionary = core.probe_entity(entity_probe.x, entity_probe.y)
			er["requested"] = entity_probe
			_mutex.lock()
			_entity_result = er
			_mutex.unlock()
		if probe >= 0:
			var result: Dictionary = core.probe_cell(probe)
			_mutex.lock()
			_probe_result = result
			_mutex.unlock()
		if want_snapshot or not commands.is_empty():
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
	_entities = core.entities.count
	_corpses = core.corpses.count
	_ticks_run += 1
	_last_tick_usec = dt
	_tick_usec_ema = dt if _ticks_run == 1 else lerpf(_tick_usec_ema, dt, EMA_WEIGHT)
	_mutex.unlock()


func _publish_snapshot() -> void:
	_mutex.lock()
	var layers := _snapshot_layers
	_snapshot_layers = PackedStringArray()
	_snapshot_requested = false
	_mutex.unlock()
	var snap: Dictionary = core.render_snapshot(layers)
	_mutex.lock()
	# Keep layers from a snapshot the main thread has not picked up yet.
	if not _snapshot.is_empty():
		var old: Dictionary = _snapshot["layers"]
		for layer_name: String in old:
			if not snap["layers"].has(layer_name):
				snap["layers"][layer_name] = old[layer_name]
	_snapshot = snap
	_mutex.unlock()
