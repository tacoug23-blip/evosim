## One-per-cell conflict resolution on hand-built maps.
extends "res://tests/test_base.gd"

const Rng := preload("res://sim/core/rng.gd")
const Substrates := preload("res://sim/world/substrates.gd")
const World := preload("res://sim/world/world.gd")
const Spike := preload("res://sim/spike/spike.gd")

const EAST := 0
const SOUTH := 2
const WEST := 4

var _subs: RefCounted


## A corridor: row y=2 is soil, everything else water, so sidesteps are impossible.
func _corridor_spike(positions: Array, headings: Array) -> RefCounted:
	return _spike_on(_make_world(8, 5, func(_x: int, yy: int) -> bool: return yy == 2),
			positions, headings)


func _open_spike(w: int, h: int, positions: Array, headings: Array) -> RefCounted:
	return _spike_on(_make_world(w, h, func(_x: int, _y: int) -> bool: return true),
			positions, headings)


func _make_world(w: int, h: int, is_land: Callable) -> RefCounted:
	_subs = Substrates.new()
	_subs.load_file()
	var world := World.new(w, h)
	for yy in h:
		for xx in w:
			world.substrate[world.index(xx, yy)] = _subs.id_of("soil") if is_land.call(xx, yy) \
					else _subs.id_of("water")
	return world


func _spike_on(world: RefCounted, positions: Array, headings: Array) -> RefCounted:
	var spike := Spike.new()
	spike.setup(world, _subs, make_params(""), Rng.new(1))
	spike._allocate(positions.size())
	for i in positions.size():
		var p: Vector2i = positions[i]
		spike.x[i] = p.x
		spike.y[i] = p.y
		world.occupancy[world.index(p.x, p.y)] = i + 1
		spike.speed[i] = 1000
		spike.progress[i] = 1000
		spike.heading[i] = headings[i]
	return spike


## Propose a step from entity i's cell to the adjacent `cell` (stored as a heading).
func _propose(spike: RefCounted, i: int, cell: Vector2i) -> void:
	var d := cell - _pos(spike, i)
	var h: int = Spike.DIR_FROM_DELTA_LIST[(d.y + 1) * 3 + d.x + 1]
	assert(h != Spike.NO_DIR, "proposal must be to a neighbouring cell")
	spike.proposal[i] = h


func _pos(spike: RefCounted, i: int) -> Vector2i:
	return Vector2i(spike.x[i], spike.y[i])


func test_two_claims_one_cell_rotating_winner() -> void:
	for start in 2:
		var s := _corridor_spike([Vector2i(2, 2), Vector2i(4, 2)], [EAST, WEST])
		_propose(s, 0, Vector2i(3, 2))
		_propose(s, 1, Vector2i(3, 2))
		s.resolve(start, 0)
		var winner := start
		check_eq(_pos(s, winner), Vector2i(3, 2), "start=%d: entity %d takes the cell" % [start, winner])
		check_eq(_pos(s, 1 - winner), [Vector2i(2, 2), Vector2i(4, 2)][1 - winner],
				"start=%d: loser waits" % start)
		check_eq(s.check_invariants(), "", "invariants")
		check_eq(s.last_blocked, 1, "one blocked")


func test_no_swaps() -> void:
	for start in 2:
		var s := _corridor_spike([Vector2i(2, 2), Vector2i(3, 2)], [EAST, WEST])
		_propose(s, 0, Vector2i(3, 2))
		_propose(s, 1, Vector2i(2, 2))
		s.resolve(start, 0)
		check_eq(_pos(s, 0), Vector2i(2, 2), "start=%d: A did not swap" % start)
		check_eq(_pos(s, 1), Vector2i(3, 2), "start=%d: B did not swap" % start)
		check_eq(s.check_invariants(), "", "invariants")


func test_following_into_vacated_cell_depends_on_order() -> void:
	# B (index 1) moves away first when start=1, so A can follow into B's old cell.
	var s := _corridor_spike([Vector2i(2, 2), Vector2i(3, 2)], [EAST, EAST])
	_propose(s, 0, Vector2i(3, 2))
	_propose(s, 1, Vector2i(4, 2))
	s.resolve(1, 0)
	check_eq(_pos(s, 0), Vector2i(3, 2), "A follows")
	check_eq(_pos(s, 1), Vector2i(4, 2), "B moves")
	var t := _corridor_spike([Vector2i(2, 2), Vector2i(3, 2)], [EAST, EAST])
	_propose(t, 0, Vector2i(3, 2))
	_propose(t, 1, Vector2i(4, 2))
	t.resolve(0, 0)
	check_eq(_pos(t, 0), Vector2i(2, 2), "A goes first and is blocked")
	check_eq(_pos(t, 1), Vector2i(4, 2), "B still moves")


func test_sidestep_when_blocked_in_open_ground() -> void:
	var s := _open_spike(8, 8, [Vector2i(3, 3), Vector2i(4, 3)], [EAST, EAST])
	_propose(s, 0, Vector2i(4, 3))  # B stays put, A is blocked by it
	s.proposal[1] = Spike.NO_PROPOSAL
	s.resolve(0, 0)
	# (index 0 + tick 0) is even, so A tries heading+1 (south-east) first.
	check_eq(_pos(s, 0), Vector2i(4, 4), "A sidesteps south-east")
	check_eq(s.last_sidesteps, 1, "sidestep counted")
	check_eq(s.check_invariants(), "", "invariants")


func test_blocked_entity_does_not_bank_progress() -> void:
	var s := _corridor_spike([Vector2i(2, 2), Vector2i(3, 2)], [EAST, EAST])
	s.progress[0] = 5000
	_propose(s, 0, Vector2i(3, 2))
	s.proposal[1] = Spike.NO_PROPOSAL
	s.resolve(0, 0)
	check_eq(s.progress[0], _subs.move_cost_milli[_subs.id_of("soil")], "progress capped at one step")


func test_never_proposes_impassable_or_off_map() -> void:
	var s := _corridor_spike([Vector2i(2, 2), Vector2i(0, 2)], [SOUTH, WEST])
	s.target_x.fill(Spike.NO_TARGET)
	s.propose()
	check_eq(s.proposal[0], Spike.NO_PROPOSAL, "no proposal into water")
	check_eq(s.proposal[1], Spike.NO_PROPOSAL, "no proposal off the map")
	check_eq(s.heading[0], Spike.NO_DIR, "heading cleared at the shore")


func test_dense_ticks_keep_one_per_cell_and_never_swap() -> void:
	var positions := []
	var headings := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var taken := {}
	while positions.size() < 120:
		var p := Vector2i(rng.randi_range(0, 15), rng.randi_range(0, 15))
		if not taken.has(p):
			taken[p] = true
			positions.append(p)
			headings.append(rng.randi() & 7)
	var s := _open_spike(16, 16, positions, headings)
	var swaps := 0
	var violations := ""
	for t in range(1, 301):
		var before := {}
		for i in s.count:
			before[_pos(s, i)] = i
		var old := []
		for i in s.count:
			old.append(_pos(s, i))
		s.tick(t)
		for i in s.count:
			var now := _pos(s, i)
			if now != old[i] and before.has(now):
				var k: int = before[now]
				if k != i and _pos(s, k) == old[i]:
					swaps += 1
		var inv: String = s.check_invariants()
		if not inv.is_empty() and violations.is_empty():
			violations = "tick %d: %s" % [t, inv]
	check_eq(violations, "", "one entity per cell every tick")
	check_eq(swaps, 0, "no swaps")
