## One-per-cell movement of real entities on hand-built maps (ported from the Phase 1 spike's
## conflict tests).
extends "res://tests/test_base.gd"

const EntitySystem := preload("res://sim/entity/entity_system.gd")

const EAST := 0
const SOUTH := 2
const WEST := 4


## A small world with no flora: land where is_land(x, y), water elsewhere.
func _world(w: int, h: int, is_land: Callable) -> RefCounted:
	var core := make_core("test_tiny", {"world.width": w, "world.height": h})
	var world: RefCounted = core.world
	var soil: int = core.substrates.id_of("soil")
	var water: int = core.substrates.id_of("water")
	for yy in h:
		for xx in w:
			var c: int = world.index(xx, yy)
			world.substrate[c] = soil if is_land.call(xx, yy) else water
			world.flora_type[c] = 0
			world.flora_biomass[c] = 0
	core.env.recount()
	return core


func _corridor() -> RefCounted:
	return _world(64, 64, func(_x: int, yy: int) -> bool: return yy == 2)


func _spawn(core: RefCounted, positions: Array) -> void:
	for p: Vector2i in positions:
		var slot: int = core.entities.spawn(core.world.index(p.x, p.y), core.genes.defaults(), 0)
		check(slot >= 0, "spawned at %s" % p)


func _pos(core: RefCounted, i: int) -> Vector2i:
	return Vector2i(core.entities.x[i], core.entities.y[i])


func _propose_step(core: RefCounted, i: int, to: Vector2i) -> void:
	var d := to - _pos(core, i)
	core.entities.proposal[i] = EntitySystem.DIR_FROM_DELTA_LIST[(d.y + 1) * 3 + d.x + 1]
	core.entities.progress[i] = 1000


func test_two_claims_one_cell_rotating_winner() -> void:
	for start in 2:
		var core := _corridor()
		_spawn(core, [Vector2i(2, 2), Vector2i(4, 2)])
		_propose_step(core, 0, Vector2i(3, 2))
		_propose_step(core, 1, Vector2i(3, 2))
		core.entities._resolve(start)
		check_eq(_pos(core, start), Vector2i(3, 2), "start=%d: slot %d takes the cell" % [start, start])
		check_eq(_pos(core, 1 - start), [Vector2i(2, 2), Vector2i(4, 2)][1 - start], "start=%d: loser waits" % start)
		check_eq(core.entities.stuck[1 - start], 1, "start=%d: loser counts a blocked tick" % start)
		check_eq(core.entities.check_invariants(), "", "invariants")


func test_no_swaps() -> void:
	for start in 2:
		var core := _corridor()
		_spawn(core, [Vector2i(2, 2), Vector2i(3, 2)])
		_propose_step(core, 0, Vector2i(3, 2))
		_propose_step(core, 1, Vector2i(2, 2))
		core.entities._resolve(start)
		check_eq(_pos(core, 0), Vector2i(2, 2), "start=%d: A did not swap" % start)
		check_eq(_pos(core, 1), Vector2i(3, 2), "start=%d: B did not swap" % start)


func test_following_into_vacated_cell_depends_on_order() -> void:
	var core := _corridor()
	_spawn(core, [Vector2i(2, 2), Vector2i(3, 2)])
	_propose_step(core, 0, Vector2i(3, 2))
	_propose_step(core, 1, Vector2i(4, 2))
	core.entities._resolve(1)
	check_eq([_pos(core, 0), _pos(core, 1)], [Vector2i(3, 2), Vector2i(4, 2)], "B first: A follows")
	var core2 := _corridor()
	_spawn(core2, [Vector2i(2, 2), Vector2i(3, 2)])
	_propose_step(core2, 0, Vector2i(3, 2))
	_propose_step(core2, 1, Vector2i(4, 2))
	core2.entities._resolve(0)
	check_eq([_pos(core2, 0), _pos(core2, 1)], [Vector2i(2, 2), Vector2i(4, 2)], "A first: A blocked")


func test_sidestep_when_blocked_in_open_ground() -> void:
	var core := _world(32, 32, func(_x: int, _y: int) -> bool: return true)
	_spawn(core, [Vector2i(3, 3), Vector2i(4, 3)])
	_propose_step(core, 0, Vector2i(4, 3))
	core.entities._tick = 0
	core.entities._resolve(0)
	check_eq(_pos(core, 0), Vector2i(4, 4), "A sidesteps south-east")
	check_eq(core.entities.check_invariants(), "", "invariants")


func test_progress_does_not_bank_and_terrain_costs_energy() -> void:
	var core := _world(32, 32, func(_x: int, _y: int) -> bool: return true)
	_spawn(core, [Vector2i(5, 5)])
	var e: RefCounted = core.entities
	e.action[0] = EntitySystem.Action.WANDER
	e.heading[0] = EAST
	e.progress[0] = 50000
	e._run_chunks(e._propose_chunk)
	check_eq(e.progress[0], 1000, "progress capped at one step's cost")
	var before: int = e.energy[0]
	e._resolve(0)
	check_eq(_pos(core, 0), Vector2i(6, 5), "moved east")
	check_eq(before - e.energy[0], e.move_cost[0], "a cost-1 step costs the derived move_cost")


func test_never_moves_into_water_or_off_map() -> void:
	var core := _corridor()
	_spawn(core, [Vector2i(5, 2), Vector2i(0, 2)])
	var e: RefCounted = core.entities
	for i in 2:
		e.action[i] = EntitySystem.Action.WANDER
		e.progress[i] = 1000
	e.heading[0] = SOUTH
	e.heading[1] = WEST
	e._run_chunks(e._propose_chunk)
	check_eq(e.proposal[0], EntitySystem.NO_PROPOSAL, "no proposal into water")
	check_eq(e.proposal[1], EntitySystem.NO_PROPOSAL, "no proposal off the map")


func test_carrying_slows_movement() -> void:
	var core := _world(32, 32, func(_x: int, _y: int) -> bool: return true)
	_spawn(core, [Vector2i(5, 5)])
	var e: RefCounted = core.entities
	var k: int = core.corpses.create(core.world.index(9, 9))
	core.corpses.pick_up(k, 0)
	e.carrying[0] = k + 1
	e.action[0] = EntitySystem.Action.WANDER
	e.heading[0] = EAST
	e.progress[0] = 0
	e._run_chunks(e._propose_chunk)
	var factor: float = core.params.get_float("entity.carry_speed_factor")
	check_eq(e.progress[0], (e.speed[0] * roundi(factor * 1024)) >> 10, "carrying scales speed by carry_speed_factor")


func test_carrying_raises_move_cost() -> void:
	var core := _world(32, 32, func(_x: int, _y: int) -> bool: return true)
	_spawn(core, [Vector2i(5, 5)])
	var e: RefCounted = core.entities
	var k: int = core.corpses.create(core.world.index(9, 9))
	core.corpses.pick_up(k, 0)
	e.carrying[0] = k + 1
	e.action[0] = EntitySystem.Action.WANDER
	e.heading[0] = EAST
	e.progress[0] = 50000
	e._run_chunks(e._propose_chunk)
	var before: int = e.energy[0]
	e._resolve(0)
	check_eq(_pos(core, 0), Vector2i(6, 5), "moved east while carrying")
	var factor: float = core.params.get_float("entity.carry_move_cost_factor")
	check_eq(before - e.energy[0], (e.move_cost[0] * roundi(factor * 1024)) >> 10,
			"a cost-1 step while carrying costs move_cost x carry_move_cost_factor")


## Burn, sense and movement are all charged before the death check: an entity that can pay its
## burn but not the step after it dies this tick, where it stepped, instead of living on with
## negative energy until the next tick.
func test_death_check_after_every_energy_cost() -> void:
	var core := _world(32, 32, func(_x: int, _y: int) -> bool: return true)
	_spawn(core, [Vector2i(5, 5), Vector2i(20, 20), Vector2i(10, 20)])
	var e: RefCounted = core.entities
	for i in [0, 2]:
		e.action[i] = EntitySystem.Action.WANDER
		e.heading[i] = EAST
		e.progress[i] = 50000
	e.energy[0] = e.base_burn[0] + e.sense_burn[0] + 1
	e.action[1] = EntitySystem.Action.REST
	e.energy[1] = 500000
	e.energy[2] = 500000
	# Tick 1: none of slots 0-2 is due to decide ((tick + slot) % decision_interval != 0).
	e.tick(1)
	check_eq(e.alive[0], 0, "out of energy after its step: died this tick")
	check_eq(core.corpses.at(core.world.index(6, 5)) >= 0, true, "its corpse lies where it stepped to")
	check_eq(e.energy[1], 500000 - e.rest_burn[1] - e.sense_burn[1], "resting: rest burn + sense burn")
	check_eq(e.energy[2], 500000 - e.base_burn[2] - e.sense_burn[2] - e.move_cost[2], "active: base burn + sense burn + one cost-1 step")
	check_eq(e.check_invariants(), "", "invariants hold (no living entity at or below zero energy)")
