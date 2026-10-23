## Phase 1 performance spike (spec section 13): dummy entities that exercise the hot paths
## the real entity system will have. Not real entity logic; Phase 3 replaces it.
##
## Per tick:
##   decide   - entities with (tick + index) % decision_interval == 0 scan a (2r+1)^2 window
##              of the dummy field (the fertility layer) and either gradient-seek its best
##              cell or pick a random-walk heading.
##   propose  - every entity accumulates movement progress; once progress covers the terrain
##              move cost of the next cell it proposes that cell.
##   resolve  - proposals are applied one by one in a rotating order with a seeded start.
##              A move succeeds only into an empty cell, so two entities can never share a
##              cell and no two entities can swap. A blocked entity tries the two neighbouring
##              headings (sidestep), else waits.
##
## decide and propose only write each entity's own slots, so they run in parallel chunks on
## the WorkerThreadPool (sim.worker_threads). decide draws its randomness from
## Rng.hash3(seed, tick, entity) rather than a sequential stream, so results are identical
## for any thread count. resolve is sequential by construction.
##
## Entity id = index + 1 (0 means an empty cell in world.occupancy).
extends RefCounted

const Units := preload("res://sim/core/units.gd")
const StateHash := preload("res://sim/core/state_hash.gd")
const Rng := preload("res://sim/core/rng.gd")

## decide's coin flip uses the top 24 bits of the hash, the heading the low 3 bits.
const COIN_BITS := 24
const COIN_SHIFT := 32 - COIN_BITS

const STREAM_SPAWN := "spike.spawn"
const STREAM_DECIDE := "spike.decide"
const STREAM_RESOLVE := "spike.resolve"
const NO_DIR := 255
const NO_TARGET := -1
const NO_PROPOSAL := -1
## Headings index this 8-neighbourhood clockwise from east, so heading +/- 1 is the
## neighbouring direction used for sidesteps.
const DIR_X_LIST := [1, 1, 0, -1, -1, -1, 0, 1]
const DIR_Y_LIST := [0, 1, 1, 1, 0, -1, -1, -1]
## Heading for a unit step (dx, dy), indexed by (dy + 1) * 3 + (dx + 1). Centre = NO_DIR.
const DIR_FROM_DELTA_LIST := [5, 6, 7, 4, NO_DIR, 0, 3, 2, 1]

var world: RefCounted
var count := 0

var x := PackedInt32Array()
var y := PackedInt32Array()
## Milli-cells per tick on cost-1 terrain.
var speed := PackedInt32Array()
## Milli-cells accumulated toward the next step.
var progress := PackedInt32Array()
var energy := PackedInt32Array()
var target_x := PackedInt32Array()
var target_y := PackedInt32Array()
var heading := PackedByteArray()
## Heading this tick's resolve should step along, or NO_PROPOSAL.
var proposal := PackedInt32Array()

## Accumulated microseconds per phase since the last reset_timing().
var timing_usec := {"decide": 0, "propose": 0, "resolve": 0}
var last_moves := 0
var last_sidesteps := 0
var last_blocked := 0

var _dir_x := PackedInt32Array(DIR_X_LIST)
var _dir_y := PackedInt32Array(DIR_Y_LIST)
var _dir_from_delta := PackedInt32Array(DIR_FROM_DELTA_LIST)
var _cost := PackedInt32Array()
## Milli-energy spent entering each substrate.
var _energy_cost := PackedInt32Array()
## Cell-index delta for each heading.
var _cell_offset := PackedInt32Array()
var _passable := PackedByteArray()
var _radius := 0
var _interval := 1
## A decision seeks when its coin (top COIN_BITS of the hash) is below this.
var _seek_threshold := 0
var _speed_min := 0
var _speed_max := 0
var _move_energy_cost := 0
var _initial_energy := 0
var _workers := 1
var _chunks_per_worker := 1
var _parallel_min := 1
var _rng_spawn: RandomNumberGenerator
var _rng_resolve: RandomNumberGenerator
var _decide_seed32 := 0


func setup(p_world: RefCounted, subs: RefCounted, params: RefCounted, rngs: RefCounted) -> void:
	world = p_world
	_cost = subs.move_cost_milli
	_passable = subs.passable
	_radius = params.get_int("spike.perception_radius")
	_interval = params.get_int("spike.decision_interval")
	_seek_threshold = roundi(params.get_float("spike.seek_probability") * (1 << COIN_BITS))
	_speed_min = Units.to_milli(params.get_float("spike.speed_min"))
	_speed_max = maxi(_speed_min, Units.to_milli(params.get_float("spike.speed_max")))
	_move_energy_cost = Units.to_milli(params.get_float("spike.move_energy_cost"))
	_initial_energy = Units.to_milli(params.get_float("spike.initial_energy"))
	var threads: int = params.get_int("sim.worker_threads")
	_workers = threads if threads > 0 else OS.get_processor_count()
	_chunks_per_worker = params.get_int("sim.chunks_per_worker")
	_parallel_min = params.get_int("sim.parallel_min_items")
	_rng_spawn = rngs.stream(STREAM_SPAWN)
	_rng_resolve = rngs.stream(STREAM_RESOLVE)
	_decide_seed32 = rngs.stream_seed32(STREAM_DECIDE)
	_energy_cost.resize(_cost.size())
	for s in _cost.size():
		@warning_ignore("integer_division")
		_energy_cost[s] = _cost[s] * _move_energy_cost / Units.MILLI
	_cell_offset.resize(8)
	for d in 8:
		_cell_offset[d] = _dir_y[d] * world.width + _dir_x[d]


## Allocate n entities (clamped to the free passable cells) at random free passable cells.
func spawn(n: int) -> int:
	var free_passable := 0
	for s in _passable.size():
		if _passable[s] == 1:
			free_passable += world.substrate.count(s)
	if n > free_passable:
		push_warning("Spike: %d entities requested, only %d passable cells" % [n, free_passable])
		n = free_passable
	_allocate(n)
	var sub: PackedByteArray = world.substrate
	var occ: PackedInt32Array = world.occupancy
	var w: int = world.width
	var cells: int = world.cell_count
	for i in n:
		while true:
			var c := _rng_spawn.randi_range(0, cells - 1)
			if occ[c] == 0 and _passable[sub[c]] == 1:
				occ[c] = i + 1
				x[i] = c % w
				@warning_ignore("integer_division")
				y[i] = c / w
				break
		speed[i] = _rng_spawn.randi_range(_speed_min, _speed_max)
		energy[i] = _initial_energy
		heading[i] = _rng_spawn.randi() & 7
	return n


## Remove every entity from the occupancy layer.
func despawn() -> void:
	var occ: PackedInt32Array = world.occupancy
	var w: int = world.width
	for i in count:
		occ[y[i] * w + x[i]] = 0
	_allocate(0)


func tick(tick_number: int) -> void:
	var t0 := Time.get_ticks_usec()
	decide(tick_number)
	var t1 := Time.get_ticks_usec()
	propose()
	var t2 := Time.get_ticks_usec()
	resolve(_rng_resolve.randi_range(0, maxi(count - 1, 0)), tick_number)
	var t3 := Time.get_ticks_usec()
	timing_usec["decide"] += t1 - t0
	timing_usec["propose"] += t2 - t1
	timing_usec["resolve"] += t3 - t2


func reset_timing() -> void:
	for k: String in timing_usec:
		timing_usec[k] = 0


func decide(tick_number: int) -> void:
	_run_ranges(_decide_range.bind(tick_number))


func propose() -> void:
	_run_ranges(_propose_range)


## Call fn(from, to) over [0, count): inline when small, else as parallel chunks.
func _run_ranges(fn: Callable) -> void:
	if _workers <= 1 or count < _parallel_min:
		fn.call(0, count)
		return
	var chunks := _workers * _chunks_per_worker
	# high_priority: low-priority tasks are capped to a fraction of the pool (2 of 8 threads).
	var task := WorkerThreadPool.add_group_task(_run_chunk.bind(fn, chunks), chunks, _workers, true)
	WorkerThreadPool.wait_for_group_task_completion(task)


func _run_chunk(chunk: int, fn: Callable, chunks: int) -> void:
	@warning_ignore("integer_division")
	fn.call(count * chunk / chunks, count * (chunk + 1) / chunks)


func _decide_range(from: int, to: int, tick_number: int) -> void:
	var w: int = world.width
	var h: int = world.height
	var r := _radius
	var field: PackedByteArray = world.fertility
	var seed32 := _decide_seed32
	var seek_threshold := _seek_threshold
	var tx_arr := target_x
	var ty_arr := target_y
	var hd := heading
	var xs := x
	var ys := y
	# Entity i decides when (tick + i) % interval == 0.
	var first := from + posmod(-(tick_number + from), _interval)
	for i in range(first, to, _interval):
		var roll := Rng.hash3(seed32, tick_number, i)
		if (roll >> COIN_SHIFT) >= seek_threshold:
			tx_arr[i] = NO_TARGET
			hd[i] = roll & 7
			continue
		var cx := xs[i]
		var cy := ys[i]
		var x0 := maxi(cx - r, 0)
		var x1 := mini(cx + r, w - 1)
		var y0 := maxi(cy - r, 0)
		var y1 := mini(cy + r, h - 1)
		# Highest field value in the window; ties go to the nearest, then to scan order.
		var best_v := -1
		var best_d := 0
		var bx := cx
		var by := cy
		for yy in range(y0, y1 + 1):
			var row := yy * w
			var ddy := yy - cy
			var ddy2 := ddy * ddy
			for xx in range(x0, x1 + 1):
				var v := field[row + xx]
				if v >= best_v:
					var ddx := xx - cx
					var d := ddx * ddx + ddy2
					if v > best_v or d < best_d:
						best_v = v
						best_d = d
						bx = xx
						by = yy
		if bx == cx and by == cy:
			tx_arr[i] = NO_TARGET
			hd[i] = NO_DIR
		else:
			tx_arr[i] = bx
			ty_arr[i] = by


func _propose_range(from: int, to: int) -> void:
	var w: int = world.width
	var h: int = world.height
	var sub: PackedByteArray = world.substrate
	var cost := _cost
	var passable := _passable
	var dir_x := _dir_x
	var dir_y := _dir_y
	var from_delta := _dir_from_delta
	var xs := x
	var ys := y
	var tx_arr := target_x
	var ty_arr := target_y
	var hd := heading
	var prog := progress
	var spd := speed
	var prop := proposal
	for i in range(from, to):
		var cx := xs[i]
		var cy := ys[i]
		var hh := hd[i]
		var tx := tx_arr[i]
		if tx != NO_TARGET:
			var ddx := signi(tx - cx)
			var ddy := signi(ty_arr[i] - cy)
			hh = from_delta[(ddy + 1) * 3 + ddx + 1]
			hd[i] = hh
			if hh == NO_DIR:
				tx_arr[i] = NO_TARGET  # arrived
		if hh == NO_DIR:
			prop[i] = NO_PROPOSAL
			continue
		var nx := cx + dir_x[hh]
		var ny := cy + dir_y[hh]
		if nx < 0 or ny < 0 or nx >= w or ny >= h:
			hd[i] = NO_DIR
			tx_arr[i] = NO_TARGET
			prop[i] = NO_PROPOSAL
			continue
		var c := ny * w + nx
		var s := sub[c]
		if passable[s] == 0:
			hd[i] = NO_DIR
			tx_arr[i] = NO_TARGET
			prop[i] = NO_PROPOSAL
			continue
		var p := prog[i] + spd[i]
		prog[i] = p
		prop[i] = hh if p >= cost[s] else NO_PROPOSAL


## Apply proposals in rotating order starting at `start`. Public for the conflict tests.
func resolve(start: int, tick_number: int) -> void:
	last_moves = 0
	last_sidesteps = 0
	last_blocked = 0
	_resolve_span(start, count, tick_number)
	_resolve_span(0, start, tick_number)


## proposal[i] holds the heading to step along; the cell is the current cell + offset.
func _resolve_span(from: int, to: int, tick_number: int) -> void:
	var w: int = world.width
	var h: int = world.height
	var sub: PackedByteArray = world.substrate
	var occ: PackedInt32Array = world.occupancy
	var cost := _cost
	var energy_cost := _energy_cost
	var passable := _passable
	var dir_x := _dir_x
	var dir_y := _dir_y
	var offs := _cell_offset
	var xs := x
	var ys := y
	var prog := progress
	var en := energy
	var prop := proposal
	var moves := 0
	var sidesteps := 0
	var blocked := 0
	for i in range(from, to):
		var hh := prop[i]
		if hh == NO_PROPOSAL:
			continue
		var cx := xs[i]
		var cy := ys[i]
		var cur := cy * w + cx
		var dest := cur + offs[hh]
		var step := hh
		if occ[dest] != 0:
			# Sidestep: try heading+1 then heading-1, order flipped by parity so blocked
			# crowds do not all drift the same way.
			step = NO_PROPOSAL
			var first_off := 1 if ((i + tick_number) & 1) == 0 else 7  # +1 or -1 (mod 8)
			for t in 2:
				var a := (hh + (first_off if t == 0 else 8 - first_off)) & 7
				var ax := cx + dir_x[a]
				var ay := cy + dir_y[a]
				if ax < 0 or ay < 0 or ax >= w or ay >= h:
					continue
				var ac := cur + offs[a]
				if occ[ac] == 0 and passable[sub[ac]] == 1 and prog[i] >= cost[sub[ac]]:
					step = a
					dest = ac
					sidesteps += 1
					break
			if step == NO_PROPOSAL:
				prog[i] = mini(prog[i], cost[sub[dest]])  # waiting does not bank extra moves
				blocked += 1
				continue
		var s := sub[dest]
		occ[cur] = 0
		occ[dest] = i + 1
		xs[i] = cx + dir_x[step]
		ys[i] = cy + dir_y[step]
		prog[i] -= cost[s]
		en[i] -= energy_cost[s]
		moves += 1
	last_moves += moves
	last_sidesteps += sidesteps
	last_blocked += blocked


func hash_state() -> String:
	var hs := StateHash.new()
	hs.add_int(count)
	for arr: PackedInt32Array in [x, y, speed, progress, energy, target_x, target_y]:
		hs.add_i32(arr)
	hs.add_bytes(heading)
	hs.add_i32(world.occupancy)
	return hs.finish_hex()


## "" if every invariant holds, else a description of the first violation.
## One-per-cell: every entity's cell holds that entity's id, and no other cell is occupied.
func check_invariants() -> String:
	var occ: PackedInt32Array = world.occupancy
	var sub: PackedByteArray = world.substrate
	var w: int = world.width
	for i in count:
		var c := y[i] * w + x[i]
		if occ[c] != i + 1:
			return "entity %d at (%d,%d) but cell holds %d" % [i + 1, x[i], y[i], occ[c]]
		if _passable[sub[c]] == 0:
			return "entity %d on impassable cell (%d,%d)" % [i + 1, x[i], y[i]]
	var occupied: int = world.cell_count - occ.count(0)
	if occupied != count:
		return "%d occupied cells for %d entities" % [occupied, count]
	return ""


## Named raw blocks for the save file.
func export_blocks() -> Dictionary:
	return {
		"spike.x": x.to_byte_array(),
		"spike.y": y.to_byte_array(),
		"spike.speed": speed.to_byte_array(),
		"spike.progress": progress.to_byte_array(),
		"spike.energy": energy.to_byte_array(),
		"spike.target_x": target_x.to_byte_array(),
		"spike.target_y": target_y.to_byte_array(),
		"spike.heading": heading,
	}


func import_blocks(blocks: Dictionary, n: int) -> bool:
	_allocate(n)
	for key: String in ["spike.x", "spike.y", "spike.speed", "spike.progress", "spike.energy",
			"spike.target_x", "spike.target_y"]:
		var bytes: PackedByteArray = blocks.get(key, PackedByteArray())
		if bytes.size() != n * 4:
			push_error("Spike: block %s has %d bytes, expected %d" % [key, bytes.size(), n * 4])
			return false
		set(key.trim_prefix("spike."), bytes.to_int32_array())
	var hd: PackedByteArray = blocks.get("spike.heading", PackedByteArray())
	if hd.size() != n:
		push_error("Spike: heading block has %d bytes, expected %d" % [hd.size(), n])
		return false
	heading = hd
	return true


func _allocate(n: int) -> void:
	count = n
	for arr_name: String in ["x", "y", "speed", "progress", "energy", "target_y", "proposal"]:
		var arr: PackedInt32Array = get(arr_name)
		arr.resize(n)
		arr.fill(0)
		set(arr_name, arr)
	target_x.resize(n)
	target_x.fill(NO_TARGET)
	proposal.fill(NO_PROPOSAL)
	heading.resize(n)
	heading.fill(NO_DIR)
