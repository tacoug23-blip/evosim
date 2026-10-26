## Entities (spec sections 4-5): an SoA store with slot recycling, genome-shaped stats, grid
## perception, a fixed-size memory ring, utility decisions, terrain-costed movement with strict
## one-entity-per-cell, eating through the flora harvest API, starvation, and corpses.
##
## Per tick:
##   decide   (parallel)   entities due this tick scan their sense window, update memory, score
##                         every action and pick the best. Writes only their own slots.
##   propose  (parallel)   age, energy burn (base or rest, plus sense), arrival check, movement
##                         proposal. Own slots only; out-of-energy and arriving entities are
##                         listed per chunk. An entity out of energy proposes no move.
##   resolve  (sequential) moves applied in rotating order from a seeded start: a move succeeds
##                         only into an empty cell, so no two entities share a cell or swap. Each
##                         move is charged its energy cost.
##   deaths   (sequential) the death check, after every per-tick cost: entities at or below zero
##                         energy die in slot order and leave corpses.
##   interact (sequential) eating, corpse pick-up/drop/eating, memory checks, same order as resolve.
## Corpse decay runs after the entities (sequential).
##
## Slots: entity id = slot + 1 (what world.occupancy stores). A dead slot is reused for a later
## entity with generation + 1, so (slot, generation) identifies one entity over time.
##
## Energy, speed, progress and costs are fixed-point integers (thousandths, Units.MILLI).
## Randomness in parallel phases is Rng.hash3(seed, tick, slot), independent of threading.
extends RefCounted

const Units := preload("res://sim/core/units.gd")
const Rng := preload("res://sim/core/rng.gd")
const Parallel := preload("res://sim/core/parallel.gd")
const StateHash := preload("res://sim/core/state_hash.gd")

enum Action { NONE, FORAGE, EAT_CORPSE, SEEK_FOOD, WANDER, REST, PICK_UP, DROP }
const ACTION_NAMES := ["none", "forage", "eat corpse", "seek food", "wander", "rest",
		"pick up corpse", "drop corpse"]
const ACTIONS := 8
enum Mem { NONE, FOOD, DANGER }
enum Cause { STARVATION }
const CAUSE_NAMES := ["starvation"]

const STREAM_RESOLVE := "entity.resolve"
const STREAM_DECIDE := "entity.decide"
const NO_DIR := 255
const NO_CELL := -1
const NO_PROPOSAL := -1
const NONE_U8 := 255
const SEASONS := 4
## Fixed point for rates and digest.
const Q_SHIFT := 10
const Q := 1 << Q_SHIFT
## Headings, clockwise from east; heading +/- 1 is the neighbouring direction (sidesteps).
const DIR_X_LIST := [1, 1, 0, -1, -1, -1, 0, 1]
const DIR_Y_LIST := [0, 1, 1, 1, 0, -1, -1, -1]
## Heading for a unit step (dx, dy), indexed by (dy + 1) * 3 + (dx + 1). Centre = NO_DIR.
const DIR_FROM_DELTA_LIST := [5, 6, 7, 4, NO_DIR, 0, 3, 2, 1]
## Search sweep legs (search_leg): 0 look back (heading = axis + 4), 1 a half leg at axis + 1,
## then full legs alternating axis - 1 (2) and axis + 1 (3). Per leg: the heading change at its end,
## the next leg, and the offset from the heading to the sweep's cardinal axis.
const NO_LEG := 255
const LEG_TURN := [5, 6, 2, 6]
const LEG_NEXT := [1, 2, 3, 2]
const LEG_AXIS := [4, 7, 1, 7]
## Genes the entity system reads, by name (config/genes.json must define them).
const GENE_NAMES := ["max_energy", "food_needed_to_sate", "digest_efficiency", "move_speed",
		"sense_radius", "memory_capacity", "forage", "rest", "explore", "carry_corpse", "max_hp"]

var world: RefCounted
var subs: RefCounted
var flora: RefCounted
var items: RefCounted
var env: RefCounted
var corpses: RefCounted
var genes: RefCounted
var time: RefCounted

var capacity := 0
var count := 0
var gene_count := 0
var memory_slots := 1

# --- SoA state (index = slot) -------------------------------------------------------------
var alive := PackedByteArray()
var generation := PackedInt32Array()
var x := PackedInt32Array()
var y := PackedInt32Array()
## 0 = male, 1 = female. Assigned at spawn, unused until reproduction.
var sex := PackedByteArray()
var age := PackedInt32Array()
var energy := PackedInt32Array()
var hp := PackedInt32Array()
## Carried corpse index + 1, or 0.
var carrying := PackedInt32Array()
var action := PackedByteArray()
var target := PackedInt32Array()
var heading := PackedByteArray()
var progress := PackedInt32Array()
var action_ticks := PackedInt32Array()
var carry_ticks := PackedInt32Array()
var proposal := PackedInt32Array()
## Ticks in a row a move toward the target was blocked; at entity.stuck_ticks the entity gives
## up on that target (it becomes `avoid`) and decides again.
var stuck := PackedByteArray()
## Cell the entity will not pick as a food target (the last one it got stuck on).
var avoid := PackedInt32Array()
## Eating episodes (a run of bites on consecutive ticks counts once) and the last bite tick.
var meals := PackedInt32Array()
var last_bite := PackedInt32Array()
## Perception results of the last decision (for the inspector and later phases).
var neighbors := PackedByteArray()
var water_dist := PackedByteArray()
## Genome, entity-major: [slot * gene_count + gene].
var genome := PackedFloat32Array()
## Utility scores of the last decision: [slot * ACTIONS + action].
var scores := PackedFloat32Array()
## Memory ring: [slot * memory_slots + i].
var mem_kind := PackedByteArray()
var mem_cell := PackedInt32Array()
var mem_tick := PackedInt32Array()
var mem_head := PackedByteArray()
## Search sweep of a hungry entity with no food in sight or in memory: the current leg (NO_LEG
## when not sweeping) and the cell where that leg began.
var search_leg := PackedByteArray()
var search_from := PackedInt32Array()

# --- Derived from the genome when it is fixed (at spawn; at birth from Phase 4) ----------------
var max_energy := PackedInt32Array()
var sate_energy := PackedInt32Array()
## Energy costs (spec 4.1.1), milli: base burn per tick, the same while resting (x
## entity.rest_burn_factor), perception per tick, and movement per cell on cost-1 terrain.
## Computed once from the genome, never per tick, and never genes themselves.
var base_burn := PackedInt32Array()
var rest_burn := PackedInt32Array()
var sense_burn := PackedInt32Array()
var move_cost := PackedInt32Array()
var speed := PackedInt32Array()
var sense_r := PackedByteArray()
var digest_q := PackedInt32Array()
var mem_cap := PackedByteArray()

# --- Stats ---------------------------------------------------------------------------------
var deaths_by_cause := PackedInt64Array([0])
var spawned := 0
var bites := 0
var corpse_bites := 0
## Milli-energy gained from food, per item id (index 0 = corpses).
var energy_eaten := PackedInt64Array()
## Meals (eating episodes) started, per item id of the first bite (index 0 = corpses).
var meals_by_item := PackedInt64Array()
var last_moves := 0
## Decisions made in the last tick (staggered ones plus re-decisions after an action ended).
var last_decisions := 0
var _chunk_decisions := PackedInt64Array()
var last_blocked := 0
var timing_usec := {"decide": 0, "propose": 0, "deaths": 0, "resolve": 0, "interact": 0}

var _gi := {}
var _g_forage := 0
var _g_rest := 0
var _g_explore := 0
var _g_carry := 0
var _g_digest := 0
var _dir_x := PackedInt32Array(DIR_X_LIST)
var _dir_y := PackedInt32Array(DIR_Y_LIST)
var _dir_from_delta := PackedInt32Array(DIR_FROM_DELTA_LIST)
var _cell_offset := PackedInt32Array()
var _cost := PackedInt32Array()
var _passable := PackedByteArray()
var _water := 0
var _free := PackedInt32Array()
var _workers := 1
var _chunks := 1
var _parallel_min := 1
var _chunk_dying: Array[PackedInt32Array] = []
var _chunk_arrive: Array[PackedInt32Array] = []
## Entities whose move this tick took their energy to zero or below (filled by resolve).
var _move_dying := PackedInt32Array()
var _decide_seed32 := 0
var _rng_resolve: RandomNumberGenerator
var _tick := 0
# Params.
var _interval := 1
var _bite := 1
# Derived-cost coefficients (spec 4.1.1), energy units.
var _burn_floor := 0.0
var _burn_k_capacity := 0.0
var _burn_k_speed := 0.0
var _burn_k_digest := 0.0
var _burn_k_memory := 0.0
var _burn_k_hp := 0.0
var _sense_per_cell := 0.0
var _move_floor := 0.0
var _move_k_speed := 0.0
var _carry_cost_q := Q
var _rest_factor := 1.0
var _rate_scale := 1.0
var _mem_ticks := 1
var _mem_trust := 0.0
var _wander_base := 0.0
var _wander_hunger := 0.0
var _path_weight_q := 0
var _carry_speed_q := Q
var _carry_ticks_full := 1
var _drop_weight := 0.0
var _sex_ratio := 0.5
var _stuck_limit := 1
var _crowd_ref := 1.0
var _crowd_weight := 0.0
var _search_hunger := 0.0
var _search_rest_hunger := 1.0
## Sweep leg lengths in cells, by sense radius: the zigzag legs and the first look-back leg.
var _leg_cells := PackedInt32Array()
var _lookback_cells := PackedInt32Array()
## Perception blocks: corpse counts live in the corpse table; this is the static water mask.
var _block := 1
var _blocks_w := 1
var _water_blocks := PackedByteArray()
## Cached references to world layers and corpse block counts (decide reads them for every
## decision; going through world.<layer> costs a dynamic lookup each time). Layers are only
## replaced on load, which rebuilds the entity system.
var _w := 1
var _h := 1
var _ft := PackedByteArray()
var _fb := PackedByteArray()
var _occ := PackedInt32Array()
var _cid := PackedInt32Array()
var _sub := PackedByteArray()
var _cblocks := PackedInt32Array()
# Per-tick food value: energy (before digest) per biomass unit of each flora type, x Q.
var _vpb_q := PackedInt64Array()
# What a full bite of each flora type is worth this tick (_bite x _vpb_q), and the largest of
# them. Upper bounds for the food scan.
var _g_full_q := PackedInt64Array()
var _g_max_q := 0
var _item_of := PackedInt32Array()


func setup(p_world: RefCounted, p_subs: RefCounted, p_flora: RefCounted, p_items: RefCounted,
		p_env: RefCounted, p_corpses: RefCounted, p_genes: RefCounted, p_time: RefCounted,
		params: RefCounted, rngs: RefCounted) -> bool:
	world = p_world
	subs = p_subs
	flora = p_flora
	items = p_items
	env = p_env
	corpses = p_corpses
	genes = p_genes
	time = p_time
	gene_count = genes.count()
	for n: String in GENE_NAMES:
		var gi: int = genes.index_of(n)
		if gi < 0:
			push_error("EntitySystem: config/genes.json lacks gene %s" % n)
			return false
		_gi[n] = gi
	_g_forage = _gi["forage"]
	_g_rest = _gi["rest"]
	_g_explore = _gi["explore"]
	_g_carry = _gi["carry_corpse"]
	_g_digest = _gi["digest_efficiency"]
	memory_slots = params.get_int("entity.memory_slots")
	_interval = params.get_int("entity.decision_interval")
	_bite = params.get_int("entity.bite_biomass")
	_burn_floor = params.get_float("entity.burn_floor")
	_burn_k_capacity = params.get_float("entity.burn_k_capacity")
	_burn_k_speed = params.get_float("entity.burn_k_speed")
	_burn_k_digest = params.get_float("entity.burn_k_digest")
	_burn_k_memory = params.get_float("entity.burn_k_memory")
	_burn_k_hp = params.get_float("entity.burn_k_hp")
	_sense_per_cell = params.get_float("entity.sense_cost_per_cell")
	_move_floor = params.get_float("entity.move_cost_floor")
	_move_k_speed = params.get_float("entity.move_cost_k_speed")
	_carry_cost_q = roundi(params.get_float("entity.carry_move_cost_factor") * Q)
	_rest_factor = params.get_float("entity.rest_burn_factor")
	_rate_scale = params.get_float("entity.food_rate_scale")
	_mem_ticks = maxi(1, roundi(params.get_float("entity.memory_days") * time.ticks_per_day))
	_mem_trust = params.get_float("entity.memory_trust")
	_wander_base = params.get_float("entity.wander_base")
	_wander_hunger = params.get_float("entity.wander_hunger")
	_path_weight_q = roundi(params.get_float("entity.path_cost_weight") * Q)
	_carry_speed_q = roundi(params.get_float("entity.carry_speed_factor") * Q)
	_carry_ticks_full = maxi(1, roundi(params.get_float("entity.carry_days") * time.ticks_per_day))
	_drop_weight = params.get_float("entity.drop_weight")
	_sex_ratio = params.get_float("entity.birth_sex_ratio")
	_stuck_limit = params.get_int("entity.stuck_ticks")
	_crowd_ref = maxf(1.0, params.get_int("entity.crowd_ref"))
	_crowd_weight = params.get_float("entity.crowd_weight")
	_search_hunger = params.get_float("entity.search_hunger")
	_search_rest_hunger = params.get_float("entity.search_rest_hunger")
	_leg_cells.resize(256)
	_lookback_cells.resize(256)
	for r in 256:
		_leg_cells[r] = maxi(2, roundi(params.get_float("entity.search_leg_radii") * r))
		_lookback_cells[r] = maxi(1, roundi(params.get_float("entity.search_lookback_radii") * r))
	_block = params.get_int("entity.perception_block")
	_workers = Parallel.resolve_workers(params.get_int("sim.worker_threads"))
	_chunks = _workers * params.get_int("sim.chunks_per_worker")
	_parallel_min = params.get_int("sim.parallel_min_items")
	_decide_seed32 = rngs.stream_seed32(STREAM_DECIDE)
	_rng_resolve = rngs.stream(STREAM_RESOLVE)
	_cost = subs.move_cost_milli
	_passable = subs.passable
	_water = subs.id_of("water")
	_build_water_blocks()
	_w = world.width
	_h = world.height
	_ft = world.flora_type
	_fb = world.flora_biomass
	_occ = world.occupancy
	_cid = world.corpse_id
	_sub = world.substrate
	_cblocks = corpses.block_count
	_cell_offset.resize(8)
	for d in 8:
		_cell_offset[d] = _dir_y[d] * world.width + _dir_x[d]
	_item_of = PackedInt32Array(flora.harvest_item)
	_vpb_q.resize(flora.count() + 1)
	_vpb_q.fill(0)
	_g_full_q.resize(flora.count() + 1)
	_g_full_q.fill(0)
	energy_eaten.resize(items.count())
	energy_eaten.fill(0)
	meals_by_item.resize(items.count())
	meals_by_item.fill(0)
	_chunk_dying.clear()
	_chunk_arrive.clear()
	_chunk_decisions.resize(_chunks)
	_chunk_decisions.fill(0)
	for c in _chunks:
		_chunk_dying.append(PackedInt32Array())
		_chunk_arrive.append(PackedInt32Array())
	return true


# --- Spawning and death ---------------------------------------------------------------------

## Put a new entity on free passable cell c. Returns its slot, or -1 if the cell is unusable.
## Sequential phases only.
func spawn(c: int, p_genome: PackedFloat32Array, p_sex: int) -> int:
	if world.occupancy[c] != 0 or _passable[world.substrate[c]] == 0:
		return -1
	if _free.is_empty():
		_grow(maxi(256, capacity * 2))
	var i := _free[_free.size() - 1]
	_free.remove_at(_free.size() - 1)
	var w: int = world.width
	alive[i] = 1
	x[i] = c % w
	@warning_ignore("integer_division")
	y[i] = c / w
	sex[i] = p_sex
	age[i] = 0
	carrying[i] = 0
	action[i] = Action.NONE
	target[i] = NO_CELL
	heading[i] = NO_DIR
	search_leg[i] = NO_LEG
	search_from[i] = NO_CELL
	progress[i] = 0
	action_ticks[i] = 0
	carry_ticks[i] = 0
	proposal[i] = NO_PROPOSAL
	neighbors[i] = 0
	water_dist[i] = NONE_U8
	stuck[i] = 0
	avoid[i] = NO_CELL
	meals[i] = 0
	last_bite[i] = -2
	for g in gene_count:
		genome[i * gene_count + g] = genes.clamp_gene(g, p_genome[g])
	for a in ACTIONS:
		scores[i * ACTIONS + a] = 0.0
	for m in memory_slots:
		mem_kind[i * memory_slots + m] = Mem.NONE
		mem_cell[i * memory_slots + m] = NO_CELL
		mem_tick[i * memory_slots + m] = 0
	mem_head[i] = 0
	_derive(i)
	energy[i] = max_energy[i]
	hp[i] = Units.to_milli(gene(i, "max_hp"))
	world.occupancy[c] = i + 1
	count += 1
	spawned += 1
	return i


## Mark perception blocks that contain any water cell. One pass of native find() calls: after a
## hit, skip to the end of that block's row segment.
func _build_water_blocks() -> void:
	var w: int = world.width
	_blocks_w = ceili(float(w) / _block)
	_water_blocks.resize(_blocks_w * ceili(float(world.height) / _block))
	_water_blocks.fill(0)
	var sub: PackedByteArray = world.substrate
	var pos := 0
	while true:
		var p := sub.find(_water, pos)
		if p < 0:
			break
		var px := p % w
		@warning_ignore("integer_division")
		var bx := px / _block
		@warning_ignore("integer_division")
		_water_blocks[(p / w / _block) * _blocks_w + bx] = 1
		pos = p - px + mini(w, (bx + 1) * _block)


## Female with probability entity.birth_sex_ratio.
func roll_sex(rng: RandomNumberGenerator) -> int:
	return 1 if rng.randf() < _sex_ratio else 0


func kill(i: int, cause: Cause) -> void:
	var c: int = y[i] * world.width + x[i]
	world.occupancy[c] = 0
	corpses.create(c)
	if carrying[i] != 0:
		corpses.drop(carrying[i] - 1, c)
		carrying[i] = 0
	deaths_by_cause[cause] += 1
	alive[i] = 0
	generation[i] += 1
	x[i] = NO_CELL
	y[i] = NO_CELL
	action[i] = Action.NONE
	proposal[i] = NO_PROPOSAL
	count -= 1
	_free.append(i)


## Remove every entity without leaving corpses (tool and test resets).
func clear() -> void:
	for i in capacity:
		if alive[i] == 1:
			world.occupancy[y[i] * world.width + x[i]] = 0
			if carrying[i] != 0:
				corpses.drop(carrying[i] - 1, y[i] * world.width + x[i])
			alive[i] = 0
			generation[i] += 1
			x[i] = NO_CELL
			y[i] = NO_CELL
			carrying[i] = 0
			action[i] = Action.NONE
			proposal[i] = NO_PROPOSAL
			_free.append(i)
	count = 0
	# Keep the free list in a canonical order so a reset world behaves like a fresh one.
	_free.sort()
	_free.reverse()


func gene(i: int, gene_name: String) -> float:
	return genome[i * gene_count + _gi[gene_name]]


func is_handle_alive(slot: int, gen: int) -> bool:
	return slot >= 0 and slot < capacity and alive[slot] == 1 and generation[slot] == gen


## Integer stats derived from the genome (recomputed whenever a genome is set), including the
## energy costs of spec 4.1.1. Each cost is summed in floating point from the gene values and
## rounded once to milli. Memory and sense costs use the capacity and radius the entity actually
## gets (rounded and clamped), so it pays for what it has.
func _derive(i: int) -> void:
	var g0 := i * gene_count
	var e_max: float = genome[g0 + _gi["max_energy"]]
	var spd: float = genome[g0 + _gi["move_speed"]]
	var digest: float = genome[g0 + _gi["digest_efficiency"]]
	max_energy[i] = Units.to_milli(e_max)
	sate_energy[i] = roundi(max_energy[i] * genome[g0 + _gi["food_needed_to_sate"]])
	sense_r[i] = clampi(roundi(genome[g0 + _gi["sense_radius"]]), 1, 254)
	mem_cap[i] = clampi(roundi(genome[g0 + _gi["memory_capacity"]]), 1, memory_slots)
	var b := Units.to_milli(_burn_floor + _burn_k_capacity * e_max / 1000.0 + _burn_k_speed * spd * spd
			+ _burn_k_digest * digest + _burn_k_memory * mem_cap[i] + _burn_k_hp * genome[g0 + _gi["max_hp"]] / 100.0)
	base_burn[i] = b
	rest_burn[i] = roundi(b * _rest_factor)
	var side: int = 2 * sense_r[i] + 1
	sense_burn[i] = Units.to_milli(_sense_per_cell * side * side)
	move_cost[i] = Units.to_milli(_move_floor + _move_k_speed * spd * spd)
	speed[i] = maxi(1, Units.to_milli(spd))
	digest_q[i] = roundi(digest * Q)


func _grow(new_capacity: int) -> void:
	var old := capacity
	for arr_name: String in ["alive", "sex", "action", "heading", "neighbors", "water_dist", "stuck", "search_leg",
			"mem_head", "sense_r", "mem_cap"]:
		var a: PackedByteArray = get(arr_name)
		a.resize(new_capacity)
		set(arr_name, a)
	for arr_name: String in ["generation", "x", "y", "age", "energy", "hp", "carrying", "target", "avoid", "meals", "last_bite",
			"progress", "action_ticks", "carry_ticks", "proposal", "search_from", "max_energy", "sate_energy",
			"base_burn", "rest_burn", "sense_burn", "move_cost", "speed", "digest_q"]:
		var a: PackedInt32Array = get(arr_name)
		a.resize(new_capacity)
		set(arr_name, a)
	genome.resize(new_capacity * gene_count)
	scores.resize(new_capacity * ACTIONS)
	mem_kind.resize(new_capacity * memory_slots)
	mem_cell.resize(new_capacity * memory_slots)
	mem_tick.resize(new_capacity * memory_slots)
	# resize() does not zero memory: give every new slot defined values. A stale proposal in an
	# empty slot would otherwise be "applied" at position (-1, -1).
	for i in range(old, new_capacity):
		alive[i] = 0
		sex[i] = 0
		action[i] = Action.NONE
		heading[i] = NO_DIR
		search_leg[i] = NO_LEG
		search_from[i] = NO_CELL
		neighbors[i] = 0
		water_dist[i] = NONE_U8
		stuck[i] = 0
		mem_head[i] = 0
		sense_r[i] = 1
		mem_cap[i] = 1
		generation[i] = 0
		x[i] = NO_CELL
		y[i] = NO_CELL
		age[i] = 0
		energy[i] = 0
		hp[i] = 0
		carrying[i] = 0
		target[i] = NO_CELL
		progress[i] = 0
		action_ticks[i] = 0
		carry_ticks[i] = 0
		proposal[i] = NO_PROPOSAL
		avoid[i] = NO_CELL
		meals[i] = 0
		last_bite[i] = -2
		max_energy[i] = 0
		sate_energy[i] = 1
		base_burn[i] = 0
		rest_burn[i] = 0
		sense_burn[i] = 0
		move_cost[i] = 0
		speed[i] = 1
		digest_q[i] = 0
	for i in range(old * gene_count, new_capacity * gene_count):
		genome[i] = 0.0
	for i in range(old * ACTIONS, new_capacity * ACTIONS):
		scores[i] = 0.0
	for i in range(old * memory_slots, new_capacity * memory_slots):
		mem_kind[i] = Mem.NONE
		mem_cell[i] = NO_CELL
		mem_tick[i] = 0
	# Free slots are handed out lowest index first.
	for i in range(new_capacity - 1, old - 1, -1):
		_free.append(i)
	capacity = new_capacity


# --- Tick ----------------------------------------------------------------------------------

## Per-tick values: the current tick and each flora type's food value this season (energy per
## biomass unit before digest). tick() calls it; tests call it before decide_one().
func begin_tick(tick_number: int) -> void:
	_tick = tick_number
	var season: int = time.season(tick_number)
	_g_max_q = 0
	for t in range(1, flora.count() + 1):
		_vpb_q[t] = roundi(flora.seasonal_yield[t * SEASONS + season] * items.nutrition[_item_of[t]] * Q)
		_g_full_q[t] = _bite * _vpb_q[t]
		_g_max_q = maxi(_g_max_q, _g_full_q[t])


func tick(tick_number: int) -> void:
	begin_tick(tick_number)
	if count == 0:
		corpses.tick(tick_number)
		return
	for arr: StringName in [&"alive", &"action", &"target", &"heading", &"scores", &"neighbors",
			&"water_dist", &"mem_kind", &"mem_cell", &"mem_tick", &"mem_head", &"energy", &"age", &"stuck", &"avoid",
			&"progress", &"proposal", &"action_ticks", &"carry_ticks", &"search_leg", &"search_from"]:
		Parallel.ensure_unique(self, arr)

	var t0 := Time.get_ticks_usec()
	_run_chunks(_decide_chunk)
	last_decisions = 0
	for c in _chunks:
		last_decisions += _chunk_decisions[c]
	var t1 := Time.get_ticks_usec()
	_run_chunks(_propose_chunk)
	var t2 := Time.get_ticks_usec()
	var start := _rng_resolve.randi_range(0, capacity - 1)
	_resolve(start)
	var t3 := Time.get_ticks_usec()
	_starve()
	var t4 := Time.get_ticks_usec()
	_interact(start)
	var t5 := Time.get_ticks_usec()
	timing_usec["decide"] += t1 - t0
	timing_usec["propose"] += t2 - t1
	timing_usec["resolve"] += t3 - t2
	timing_usec["deaths"] += t4 - t3
	timing_usec["interact"] += t5 - t4
	corpses.tick(tick_number)


func reset_timing() -> void:
	for k: String in timing_usec:
		timing_usec[k] = 0
	corpses.timing_usec = 0


## fn(chunk) over chunks of the slot range; inline when small.
func _run_chunks(fn: Callable) -> void:
	if _workers <= 1 or capacity < _parallel_min:
		for c in _chunks:
			fn.call(c)
		return
	Parallel.for_each(_chunks, fn, _workers)


func _chunk_range(c: int) -> Vector2i:
	@warning_ignore("integer_division")
	return Vector2i(capacity * c / _chunks, capacity * (c + 1) / _chunks)


# --- Decide --------------------------------------------------------------------------------

func _decide_chunk(c: int) -> void:
	var r := _chunk_range(c)
	var interval := _interval
	var phase := _tick % interval
	var act := action
	var alv := alive
	var n := 0
	for i in range(r.x, r.y):
		if alv[i] == 0:
			continue
		if act[i] != Action.NONE and (phase + i) % interval != 0:
			continue
		decide_one(i)
		n += 1
	_chunk_decisions[c] = n


## Perceive, remember, score, choose. Own slots only (parallel-safe). Public for tests and for
## re-running a decision the inspector can display.
func decide_one(i: int) -> void:
	var w := _w
	var h := _h
	var cx := x[i]
	var cy := y[i]
	var self_cell := cy * w + cx
	var r: int = sense_r[i]
	var ft := _ft
	var fb := _fb
	var occ := _occ
	var cid := _cid
	var sub := _sub
	var vpb := _vpb_q
	var bite := _bite
	var water := _water
	@warning_ignore("integer_division")
	var step_q := Q * Units.MILLI / speed[i]  # ticks per step, x Q

	var x0 := maxi(cx - r, 0)
	var x1 := mini(cx + r, w - 1)
	var y0 := maxi(cy - r, 0)
	var y1 := mini(cy + r, h - 1)
	# Entities in sight: occupied cells counted natively per row. The x half of the crowd
	# centroid is only needed for a crowded wander, so it is summed then (_crowd_dx).
	var near := 0
	var crowd_dy := 0
	for yy in range(y0, y1 + 1):
		var seg := occ.slice(yy * w + x0, yy * w + x1 + 1)
		var n_row := seg.size() - seg.count(0)
		near += n_row
		crowd_dy += n_row * (yy - cy)
	if occ[self_cell] != 0:
		near -= 1

	# Food: the plant with the best expected rate, ties to the lowest cell index (what a
	# row-major scan picks). Rows go outward from the entity's own, and two exact bounds skip
	# plants that cannot reach the best rate so far: past distance dmax not even the season's
	# richest type at a full bite could (_g_max_q), and in a row no type whose full bite
	# (_g_full_q) is under g_need at the row's distance can. Candidates: not under another
	# entity, not the target we last got stuck on.
	var best_rate := 0
	var best_food := NO_CELL
	var avoid_c := avoid[i]
	var g_full := _g_full_q
	var g_top := _g_max_q << Q_SHIFT
	var dmax := r
	for ady in r + 1:
		if ady > dmax:
			break
		var den0 := ady * step_q + Q
		for side in (1 if ady == 0 else 2):
			var yy := cy - ady if side == 0 else cy + ady
			if yy < y0 or yy > y1:
				continue
			var row := yy * w
			# rate >= best_rate needs g << Q_SHIFT >= best_rate * den, and den >= den0 here.
			var g_need := (best_rate * den0 + Q - 1) >> Q_SHIFT
			for xx in range(maxi(x0, cx - dmax), mini(x1, cx + dmax) + 1):
				var c := row + xx
				var t := ft[c]
				if t == 0 or g_full[t] < g_need or c == avoid_c or (occ[c] != 0 and c != self_cell):
					continue
				var b := fb[c]
				var g := (b if b < bite else bite) * vpb[t]
				if g <= 0:
					continue
				var adx := absi(xx - cx)
				var rate := (g << Q_SHIFT) / ((adx if adx > ady else ady) * step_q + Q)
				if rate > best_rate or (rate == best_rate and c < best_food):
					best_rate = rate
					best_food = c
					g_need = (best_rate * den0 + Q - 1) >> Q_SHIFT
					# Farthest distance where a plant could still tie: g_top / den >= best_rate.
					@warning_ignore("integer_division")
					var lim := g_top / best_rate - Q
					@warning_ignore("integer_division")
					dmax = lim / step_q if lim >= 0 else -1

	var best_corpse := NO_CELL
	var corpse_d := 1 << 30
	var water_d := NONE_U8
	# Corpses and water are rare: read their cells only inside perception blocks that have any
	# (corpse counts per block are kept by the corpse table; the water mask is static).
	var blk := _block
	@warning_ignore("integer_division")
	var bx0 := x0 / blk
	@warning_ignore("integer_division")
	var bx1 := x1 / blk
	@warning_ignore("integer_division")
	var by0 := y0 / blk
	@warning_ignore("integer_division")
	var by1 := y1 / blk
	var corpse_blocks := _cblocks
	for by in range(by0, by1 + 1):
		for bx in range(bx0, bx1 + 1):
			var bi := by * _blocks_w + bx
			var has_c := corpse_blocks[bi] > 0
			var has_w := _water_blocks[bi] == 1
			if not has_c and not has_w:
				continue
			for yy in range(maxi(by * blk, y0), mini(by * blk + blk - 1, y1) + 1):
				var row := yy * w
				var ady := absi(yy - cy)
				for xx in range(maxi(bx * blk, x0), mini(bx * blk + blk - 1, x1) + 1):
					var c := row + xx
					var adx := absi(xx - cx)
					var d := adx if adx > ady else ady
					if has_c and cid[c] != 0 and d < corpse_d:
						corpse_d = d
						best_corpse = c
					if has_w and d < water_d and sub[c] == water:
						water_d = d
	neighbors[i] = mini(near, NONE_U8)
	water_dist[i] = water_d

	# Memory: remember the best food in sight; find the freshest (most recent) remembered food
	# elsewhere. With no food in sight, a remembered cell that is in sight has nothing edible on it
	# any more: forget it (a searcher that reaches the spot and finds nothing moves on).
	var m0 := i * memory_slots
	var cap: int = mem_cap[i]
	if best_food != NO_CELL:
		_remember(i, Mem.FOOD, best_food)
	var mem_best := NO_CELL
	var mem_fresh := 0.0
	for m in cap:
		var k := m0 + m
		if mem_kind[k] != Mem.FOOD:
			continue
		var mc := mem_cell[k]
		@warning_ignore("integer_division")
		if best_food == NO_CELL and absi(mc % w - cx) <= r and absi(mc / w - cy) <= r:
			mem_kind[k] = Mem.NONE
			continue
		if mc == self_cell:
			continue
		var age_ticks := _tick - mem_tick[k]
		if age_ticks >= _mem_ticks:
			mem_kind[k] = Mem.NONE
			continue
		var fresh := 1.0 - float(age_ticks) / _mem_ticks
		if fresh > mem_fresh:
			mem_fresh = fresh
			mem_best = mem_cell[k]

	# Utilities.
	var e := energy[i]
	var sate := sate_energy[i]
	var hunger := clampf(float(sate - e) / sate, 0.0, 1.0)
	var digest := digest_q[i] / float(Q)
	var burn_now := (base_burn[i] + sense_burn[i]) / float(Units.MILLI)
	var g0 := i * gene_count
	var w_forage := genome[g0 + _g_forage]
	var w_rest := genome[g0 + _g_rest]
	var w_explore := genome[g0 + _g_explore]
	var w_carry := genome[g0 + _g_carry]
	var carried := carrying[i]
	var s0 := i * ACTIONS
	for a in ACTIONS:
		scores[s0 + a] = 0.0
	var food_known := best_food != NO_CELL
	if food_known:
		var rate := best_rate / float(Q) * digest
		scores[s0 + Action.FORAGE] = w_forage * hunger * rate / (rate + burn_now * _rate_scale)
	var corpse_reachable := best_corpse != NO_CELL or carried != 0
	if corpses.edible and corpse_reachable:
		var k: int = carried - 1 if carried != 0 else cid[best_corpse] - 1
		var dist := 0 if carried != 0 else corpse_d
		var crate: float = corpses.bite_energy(corpses.mass[k]) / float(Units.MILLI) * digest \
				* Q / (dist * step_q + Q)
		scores[s0 + Action.EAT_CORPSE] = w_forage * hunger * crate / (crate + burn_now * _rate_scale)
		food_known = true
	# A remembered food cell adds the seek option; it does not damp the search drive below, so a
	# fresh memory wins over wandering and a stale one loses to it.
	if not food_known and mem_best != NO_CELL:
		scores[s0 + Action.SEEK_FOOD] = w_forage * hunger * _mem_trust * mem_fresh
	# With no food in sight, resting loses its appeal by entity.search_rest_hunger: a hungry entity
	# goes back to remembered food before the memory goes stale, or starts searching while it still
	# has the energy to, instead of resting until it is weak.
	var rest_drive := 1.0 - hunger if food_known else maxf(0.0, 1.0 - hunger / _search_rest_hunger)
	scores[s0 + Action.REST] = w_rest * rest_drive
	# Crowding (entities in sight, relative to entity.crowd_ref) makes wandering away attractive,
	# so sated entities spread out instead of clumping and blocking each other; it fades with
	# hunger. With food in sight it applies only to an entity that would rest rather than eat:
	# crowding never takes an entity away from food it would eat, but the sated still leave
	# feeding spots instead of boxing hungry entities in.
	var crowd := minf(1.0, float(near) / _crowd_ref)
	var crowd_pull := _crowd_weight * crowd * (1.0 - hunger)
	if food_known and scores[s0 + Action.FORAGE] >= scores[s0 + Action.REST]:
		crowd_pull = 0.0
	scores[s0 + Action.WANDER] = w_explore * (_wander_base + (0.0 if food_known else _wander_hunger * hunger)) \
			+ crowd_pull
	if carried == 0 and best_corpse != NO_CELL:
		scores[s0 + Action.PICK_UP] = w_carry * (1.0 - hunger)
	if carried != 0:
		scores[s0 + Action.DROP] = _drop_weight * minf(1.0, float(carry_ticks[i]) / _carry_ticks_full) + hunger

	# Same rule as best_scored() (inlined: this runs ~10k times per tick).
	var best := Action.NONE
	var best_score := 0.0
	for a in range(1, ACTIONS):
		if scores[s0 + a] > best_score:
			best_score = scores[s0 + a]
			best = a
	if best == Action.NONE:
		best = Action.REST
	action[i] = best
	action_ticks[i] = 0
	if best != Action.WANDER:
		search_leg[i] = NO_LEG
	match best:
		Action.FORAGE:
			target[i] = best_food
		Action.EAT_CORPSE:
			target[i] = NO_CELL if carried != 0 else best_corpse
		Action.SEEK_FOOD:
			target[i] = mem_best
		Action.PICK_UP:
			target[i] = best_corpse
		Action.WANDER:
			target[i] = NO_CELL
			# Searching: hungry, no food in sight, and wandering won (any remembered food was too
			# stale to seek). Crowding does not turn a searcher (a stranded hungry group that kept
			# turning from each other would oscillate in place instead of leaving):
			#  - with a remembered food cell, even a stale one, head for the most recent first;
			#  - otherwise sweep (propose runs the legs): look back a short leg, then zigzag in
			#    diagonal legs along a cardinal axis, which keeps full speed away from where it
			#    started while seeing a band about twice as wide as a straight line.
			var searching := not food_known and hunger >= _search_hunger
			if searching and mem_best != NO_CELL:
				@warning_ignore("integer_division")
				var my := mem_best / w
				heading[i] = _dir_from_delta[(signi(my - cy) + 1) * 3 + signi(mem_best % w - cx) + 1]
				search_leg[i] = NO_LEG
			elif searching:
				if search_leg[i] == NO_LEG:
					var d0: int = heading[i] if heading[i] != NO_DIR else Rng.hash3(_decide_seed32, _tick, i + capacity) & 7
					heading[i] = ((d0 & 6) + 4) & 7  # behind the cardinal axis nearest the current heading
					search_leg[i] = 0
					search_from[i] = self_cell
			else:
				var crowd_dx := _crowd_dx(cx, x0, x1, y0, y1) if crowd > 0.0 else 0
				if crowd > 0.0 and (crowd_dx != 0 or crowd_dy != 0):
					# Away from the centre of the entities in sight.
					var away: int = _dir_from_delta[(1 - signi(crowd_dy)) * 3 + 1 - signi(crowd_dx)]
					heading[i] = away if away != NO_DIR else Rng.hash3(_decide_seed32, _tick, i + capacity) & 7
				elif heading[i] == NO_DIR or (Rng.hash3(_decide_seed32, _tick, i) & 3) == 0:
					heading[i] = Rng.hash3(_decide_seed32, _tick, i + capacity) & 7
		_:
			target[i] = NO_CELL


## Sum of x offsets from cx of the occupied cells in a window: the x half of the crowd centroid
## (the entity's own cell adds 0).
func _crowd_dx(cx: int, x0: int, x1: int, y0: int, y1: int) -> int:
	var occ := _occ
	var w := _w
	var s := 0
	for yy in range(y0, y1 + 1):
		var row := yy * w
		for xx in range(x0, x1 + 1):
			if occ[row + xx] != 0:
				s += xx - cx
	return s


## The action the last decision chose: the highest stored score, ties to the lower index, REST
## if every score is 0. The current action can differ once the action ends or is given up.
func best_scored(i: int) -> int:
	var s0 := i * ACTIONS
	var best := Action.NONE
	var best_score := 0.0
	for a in range(1, ACTIONS):
		if scores[s0 + a] > best_score:
			best_score = scores[s0 + a]
			best = a
	return Action.REST if best == Action.NONE else best


func _remember(i: int, kind: Mem, c: int) -> void:
	var m0 := i * memory_slots
	var cap: int = mem_cap[i]
	for m in cap:
		if mem_kind[m0 + m] == kind and mem_cell[m0 + m] == c:
			mem_tick[m0 + m] = _tick
			return
	var slot := mem_head[i] % cap
	mem_kind[m0 + slot] = kind
	mem_cell[m0 + slot] = c
	mem_tick[m0 + slot] = _tick
	mem_head[i] = (slot + 1) % cap


func _forget(i: int, c: int) -> void:
	var m0 := i * memory_slots
	for m in mem_cap[i]:
		if mem_cell[m0 + m] == c:
			mem_kind[m0 + m] = Mem.NONE


# --- Propose -------------------------------------------------------------------------------

func _propose_chunk(c: int) -> void:
	var r := _chunk_range(c)
	var dying := _chunk_dying[c]
	var arrive := _chunk_arrive[c]
	dying.resize(0)
	arrive.resize(0)
	var w: int = world.width
	var h: int = world.height
	var sub: PackedByteArray = world.substrate
	var cost := _cost
	var passable := _passable
	var dir_x := _dir_x
	var dir_y := _dir_y
	var from_delta := _dir_from_delta
	var alv := alive
	var act := action
	var tgt := target
	var hd := heading
	var sleg := search_leg
	var sfrom := search_from
	var prog := progress
	var prop := proposal
	var en := energy
	var xs := x
	var ys := y
	var carry := carrying
	var path_w := _path_weight_q
	for i in range(r.x, r.y):
		if alv[i] == 0:
			continue
		age[i] += 1
		action_ticks[i] += 1
		var a := act[i]
		var e := en[i] - (rest_burn[i] if a == Action.REST else base_burn[i]) - sense_burn[i]
		en[i] = e
		prop[i] = NO_PROPOSAL
		if e <= 0:
			dying.append(i)
			continue
		if carry[i] != 0:
			carry_ticks[i] += 1
		var cx := xs[i]
		var cy := ys[i]
		var hh := NO_DIR
		if a == Action.FORAGE or a == Action.EAT_CORPSE or a == Action.PICK_UP or a == Action.SEEK_FOOD:
			var t := tgt[i]
			if t == NO_CELL:
				arrive.append(i)
				continue
			var tx := t % w
			@warning_ignore("integer_division")
			var ty := t / w
			var ddx := tx - cx
			var ddy := ty - cy
			if absi(ddx) <= 1 and absi(ddy) <= 1:
				arrive.append(i)
				continue
			if stuck[i] >= _stuck_limit:
				# Blocked too long (usually a crowd around the target): give it up and head away
				# from it until the next decision.
				avoid[i] = t
				stuck[i] = 0
				act[i] = Action.WANDER
				hd[i] = (from_delta[(signi(ddy) + 1) * 3 + signi(ddx) + 1] + 4) & 7
				continue
			# Cost-weighted local step: of the direct heading and its two neighbours, take the
			# passable one that minimises remaining distance (in steps) plus weighted terrain cost.
			var direct: int = from_delta[(signi(ddy) + 1) * 3 + signi(ddx) + 1]
			var best_metric := 1 << 40
			for k in 3:
				var cand := (direct + (0 if k == 0 else (1 if k == 1 else 7))) & 7
				var nx := cx + dir_x[cand]
				var ny := cy + dir_y[cand]
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var s := sub[ny * w + nx]
				if passable[s] == 0:
					continue
				var rx := absi(tx - nx)
				var ry := absi(ty - ny)
				var metric := (rx if rx > ry else ry) * Units.MILLI * Q + cost[s] * path_w
				if metric < best_metric:
					best_metric = metric
					hh = cand
			if hh == NO_DIR:
				act[i] = Action.NONE  # walled in: decide again next tick
				continue
		elif a == Action.WANDER:
			var leg := sleg[i]
			if leg != NO_LEG:
				# Sweep: at the end of a leg (Chebyshev cells from where it began), turn to the next.
				var from := sfrom[i]
				@warning_ignore("integer_division")
				var done := maxi(absi(cx - from % w), absi(cy - from / w))
				var r_i: int = sense_r[i]
				@warning_ignore("integer_division")
				if done >= (_lookback_cells[r_i] if leg == 0 else (_leg_cells[r_i] + 1) / 2 if leg == 1 else _leg_cells[r_i]):
					hd[i] = (hd[i] + LEG_TURN[leg]) & 7
					leg = LEG_NEXT[leg]
					sleg[i] = leg
					sfrom[i] = cy * w + cx
			hh = hd[i]
			if hh == NO_DIR:
				continue
			var nx := cx + dir_x[hh]
			var ny := cy + dir_y[hh]
			# Turn when the way ahead is water or the map edge, or after entity.stuck_ticks blocked
			# by other entities (wanderers heading into each other's cells would otherwise wait
			# forever: a 2x2 group sweeping diagonally can block itself completely).
			if nx < 0 or ny < 0 or nx >= w or ny >= h or passable[sub[ny * w + nx]] == 0 or stuck[i] >= _stuck_limit:
				stuck[i] = 0
				if leg != NO_LEG:
					# A sweep turns its axis 90 degrees (side from the hash) and starts zigzagging
					# again from here.
					var axis: int = (hh + LEG_AXIS[leg]) & 7
					axis = (axis + (2 if (Rng.hash3(_decide_seed32, _tick, i + 2 * capacity) & 1) == 0 else 6)) & 7
					hd[i] = (axis + 1) & 7
					sleg[i] = 1
					sfrom[i] = cy * w + cx
				else:
					hd[i] = Rng.hash3(_decide_seed32, _tick, i + 2 * capacity) & 7
				continue
		elif a == Action.DROP:
			arrive.append(i)
			continue
		else:
			continue
		hd[i] = hh
		var s2 := sub[(cy + dir_y[hh]) * w + cx + dir_x[hh]]
		var spd := speed[i]
		if carry[i] != 0:
			spd = (spd * _carry_speed_q) >> Q_SHIFT
		var p := prog[i] + spd
		var need := cost[s2]
		prog[i] = p if p < need else need
		if p >= need:
			prop[i] = hh


# --- Resolve (sequential) ------------------------------------------------------------------

func _resolve(start: int) -> void:
	last_moves = 0
	last_blocked = 0
	_move_dying.resize(0)
	_resolve_span(start, capacity)
	_resolve_span(0, start)


func _resolve_span(from: int, to: int) -> void:
	var w: int = world.width
	var h: int = world.height
	var sub: PackedByteArray = world.substrate
	var occ: PackedInt32Array = world.occupancy
	var cost := _cost
	var passable := _passable
	var dir_x := _dir_x
	var dir_y := _dir_y
	var offs := _cell_offset
	var xs := x
	var ys := y
	var prog := progress
	var en := energy
	var prop := proposal
	var mc := move_cost
	var moves := 0
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
			step = NO_PROPOSAL
			var first_off := 1 if ((i + _tick) & 1) == 0 else 7
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
					break
			if step == NO_PROPOSAL:
				blocked += 1
				if stuck[i] < NONE_U8:
					stuck[i] += 1
				continue
		stuck[i] = 0
		var s := sub[dest]
		occ[cur] = 0
		occ[dest] = i + 1
		xs[i] = cx + dir_x[step]
		ys[i] = cy + dir_y[step]
		prog[i] -= cost[s]
		# Move cost = derived move_cost x terrain cost (x carry factor while carrying a corpse).
		@warning_ignore("integer_division")
		var spent := mc[i] * cost[s] / Units.MILLI
		if carrying[i] != 0:
			spent = (spent * _carry_cost_q) >> Q_SHIFT
		en[i] -= spent
		if en[i] <= 0:
			_move_dying.append(i)
		moves += 1
	last_moves += moves
	last_blocked += blocked


## The death check, once every per-tick energy cost is charged: entities that ran out in propose
## (burn, sense) or in resolve (movement) die, in slot order.
func _starve() -> void:
	var dying := _move_dying.duplicate()
	for c in _chunks:
		dying.append_array(_chunk_dying[c])
	dying.sort()
	for i in dying:
		kill(i, Cause.STARVATION)


# --- Interact (sequential) -----------------------------------------------------------------

func _interact(start: int) -> void:
	# Arrivals come out of the chunks in slot order; process them rotated to `start`, like
	# resolve, so no slot range is always served first.
	var order := PackedInt32Array()
	for c in _chunks:
		order.append_array(_chunk_arrive[c])
	var n := order.size()
	if n == 0:
		return
	var first := order.bsearch(start)
	for k in n:
		var i := order[(first + k) % n]
		if alive[i] == 1:
			interact_one(i)


## Carry out the action of an entity that has reached its target. Sequential phases only.
## Public for tests.
func interact_one(i: int) -> void:
	var w: int = world.width
	var a := action[i]
	match a:
		Action.FORAGE:
			var t := target[i]
			var ft: int = world.flora_type[t]
			if ft == 0:
				_forget(i, t)
				action[i] = Action.NONE
				return
			var removed: int = env.harvest_removed(t, _bite)
			var qty: int = env.yield_qty(ft, removed)
			var item := _item_of[ft]
			# Exactly nutrition x digest_efficiency per item (the gene value, not the fixed-point copy).
			var gain := roundi(qty * items.nutrition[item] * genome[i * gene_count + _g_digest] * Units.MILLI)
			_gain(i, gain, item)
			bites += 1
			if energy[i] >= sate_energy[i] or world.flora_type[t] == 0:
				action[i] = Action.NONE
		Action.EAT_CORPSE:
			var k: int = carrying[i] - 1 if carrying[i] != 0 else (corpses.at(target[i]) if target[i] != NO_CELL else -1)
			if k < 0 or corpses.alive[k] == 0:
				action[i] = Action.NONE
				return
			var raw: int = corpses.bite(k)
			_gain(i, roundi(raw * genome[i * gene_count + _g_digest]), 0)
			corpse_bites += 1
			if carrying[i] != 0 and corpses.alive[k] == 0:
				carrying[i] = 0
			if energy[i] >= sate_energy[i] or corpses.alive[k] == 0:
				action[i] = Action.NONE
		Action.PICK_UP:
			var k: int = corpses.at(target[i]) if target[i] != NO_CELL else -1
			if k >= 0 and carrying[i] == 0:
				corpses.pick_up(k, i)
				carrying[i] = k + 1
				carry_ticks[i] = 0
			action[i] = Action.NONE
		Action.DROP:
			if carrying[i] != 0:
				corpses.drop(carrying[i] - 1, y[i] * w + x[i])
				carrying[i] = 0
			action[i] = Action.NONE
		Action.SEEK_FOOD:
			_forget(i, target[i])  # arrived: whatever is here is now in sight
			action[i] = Action.NONE
		_:
			action[i] = Action.NONE


func _gain(i: int, gain_milli: int, item: int) -> void:
	var before := energy[i]
	energy[i] = mini(max_energy[i], before + gain_milli)
	energy_eaten[item] += energy[i] - before
	if last_bite[i] < _tick - 1:
		meals[i] += 1
		meals_by_item[item] += 1
	last_bite[i] = _tick


# --- Inspection, hashing, invariants, saving -----------------------------------------------

## Everything the inspector shows about one entity. Sequential phases / between ticks.
func describe(i: int) -> Dictionary:
	if i < 0 or i >= capacity or alive[i] == 0:
		return {}
	var g := {}
	for k in gene_count:
		g[genes.names[k]] = genome[i * gene_count + k]
	var mem := []
	for m in mem_cap[i]:
		var k := i * memory_slots + m
		if mem_kind[k] != Mem.NONE:
			mem.append({"kind": ["none", "food", "danger"][mem_kind[k]], "x": mem_cell[k] % world.width,
					"y": mem_cell[k] / world.width, "age_ticks": _tick - mem_tick[k]})
	var sc := {}
	for a in ACTIONS:
		sc[ACTION_NAMES[a]] = scores[i * ACTIONS + a]
	var t := target[i]
	return {
		"slot": i, "generation": generation[i], "id": i + 1, "x": x[i], "y": y[i],
		"sex": "female" if sex[i] == 1 else "male", "age_ticks": age[i],
		"energy": energy[i] / float(Units.MILLI), "max_energy": max_energy[i] / float(Units.MILLI),
		"hp": hp[i] / float(Units.MILLI), "carrying": carrying[i] - 1,
		"action": ACTION_NAMES[action[i]], "action_index": action[i], "decided": ACTION_NAMES[best_scored(i)],
		"target": [] if t == NO_CELL else [t % world.width, t / world.width],
		"neighbors": neighbors[i], "water_dist": -1 if water_dist[i] == NONE_U8 else water_dist[i],
		"meals": meals[i], "stuck": stuck[i],
		"search": ["", "looking back", "sweeping", "sweeping", "sweeping"][search_leg[i] + 1 if search_leg[i] != NO_LEG else 0],
		"genome": g, "memory": mem, "scores": sc,
		"costs": {"base_burn": base_burn[i] / float(Units.MILLI), "rest_burn": rest_burn[i] / float(Units.MILLI),
				"sense_burn": sense_burn[i] / float(Units.MILLI), "move_cost": move_cost[i] / float(Units.MILLI)},
	}


func hash_into(h: RefCounted) -> void:
	h.add_int(capacity)
	h.add_int(count)
	for arr: PackedByteArray in [alive, sex, action, heading, neighbors, water_dist, mem_kind, mem_head, stuck, search_leg]:
		h.add_bytes(arr)
	for arr: PackedInt32Array in [generation, x, y, age, energy, hp, carrying, target, avoid, meals, last_bite, progress,
			action_ticks, carry_ticks, mem_cell, mem_tick, _free, search_from]:
		h.add_i32(arr)
	for arr: PackedInt32Array in [base_burn, rest_burn, sense_burn, move_cost]:
		h.add_i32(arr)
	h.add_bytes(genome.to_byte_array())
	h.add_bytes(scores.to_byte_array())


func hash_state() -> String:
	var h := StateHash.new()
	hash_into(h)
	corpses.hash_into(h)
	return h.finish_hex()


## "" if one-per-cell and bookkeeping hold, else the first violation.
func check_invariants() -> String:
	var occ: PackedInt32Array = world.occupancy
	var w: int = world.width
	var n := 0
	for i in capacity:
		if alive[i] == 0:
			continue
		n += 1
		var c := y[i] * w + x[i]
		if occ[c] != i + 1:
			return "entity slot %d at (%d,%d) but cell holds %d" % [i, x[i], y[i], occ[c]]
		if _passable[world.substrate[c]] == 0:
			return "entity slot %d on impassable cell" % i
		if energy[i] <= 0:
			return "entity slot %d alive with energy %d (the death check runs after every cost)" % [i, energy[i]]
		if carrying[i] != 0 and corpses.carried_by[carrying[i] - 1] != i + 1:
			return "entity slot %d carrying corpse %d that does not record it" % [i, carrying[i] - 1]
	if n != count:
		return "count %d but %d alive" % [count, n]
	var occupied: int = world.cell_count - occ.count(0)
	if occupied != n:
		return "%d occupied cells for %d entities" % [occupied, n]
	return corpses.check_invariants()


func export_blocks() -> Dictionary:
	var out := {}
	for arr_name: String in ["alive", "sex", "action", "heading", "neighbors", "water_dist", "stuck", "mem_kind",
			"mem_head", "sense_r", "mem_cap"]:
		out["entity." + arr_name] = get(arr_name)
	for arr_name: String in ["generation", "x", "y", "age", "energy", "hp", "carrying", "target", "avoid", "meals", "last_bite",
			"progress", "action_ticks", "carry_ticks", "proposal", "mem_cell", "mem_tick", "max_energy",
			"sate_energy", "base_burn", "rest_burn", "sense_burn", "move_cost", "speed", "digest_q", "_free"]:
		out["entity." + arr_name] = (get(arr_name) as PackedInt32Array).to_byte_array()
	out["entity.genome"] = genome.to_byte_array()
	out["entity.scores"] = scores.to_byte_array()
	out["entity.energy_eaten"] = energy_eaten.to_byte_array()
	out["entity.meals_by_item"] = meals_by_item.to_byte_array()
	out["entity.deaths_by_cause"] = deaths_by_cause.to_byte_array()
	out["entity.search_leg"] = search_leg
	out["entity.search_from"] = search_from.to_byte_array()
	return out


func header() -> Dictionary:
	return {"capacity": capacity, "count": count, "gene_count": gene_count,
			"memory_slots": memory_slots, "spawned": spawned, "bites": bites,
			"corpse_bites": corpse_bites, "genes_hash": genes.source_hash}


func import_blocks(blocks: Dictionary, hdr: Dictionary) -> bool:
	if int(hdr.get("gene_count", -1)) != gene_count or int(hdr.get("memory_slots", -1)) != memory_slots:
		push_error("EntitySystem: save has a different gene count or memory size")
		return false
	capacity = int(hdr.get("capacity", 0))
	count = int(hdr.get("count", 0))
	for key: String in ["spawned", "bites", "corpse_bites"]:
		set(key, int(hdr.get(key, 0)))
	for arr_name: String in ["alive", "sex", "action", "heading", "neighbors", "water_dist", "stuck", "mem_kind",
			"mem_head", "sense_r", "mem_cap"]:
		set(arr_name, blocks.get("entity." + arr_name, PackedByteArray()))
	for arr_name: String in ["generation", "x", "y", "age", "energy", "hp", "carrying", "target", "avoid", "meals", "last_bite",
			"progress", "action_ticks", "carry_ticks", "proposal", "mem_cell", "mem_tick", "max_energy",
			"sate_energy", "base_burn", "rest_burn", "sense_burn", "move_cost", "speed", "digest_q", "_free"]:
		set(arr_name, (blocks.get("entity." + arr_name, PackedByteArray()) as PackedByteArray).to_int32_array())
	genome = (blocks.get("entity.genome", PackedByteArray()) as PackedByteArray).to_float32_array()
	scores = (blocks.get("entity.scores", PackedByteArray()) as PackedByteArray).to_float32_array()
	energy_eaten = (blocks.get("entity.energy_eaten", PackedByteArray()) as PackedByteArray).to_int64_array()
	meals_by_item = (blocks.get("entity.meals_by_item", PackedByteArray()) as PackedByteArray).to_int64_array()
	deaths_by_cause = (blocks.get("entity.deaths_by_cause", PackedByteArray()) as PackedByteArray).to_int64_array()
	# Version 3 saves have no sweep state (added in version 4): nobody is mid-sweep after loading one.
	# Per-item counts missing from any save start at 0.
	search_leg = blocks.get("entity.search_leg", PackedByteArray())
	search_from = (blocks.get("entity.search_from", PackedByteArray()) as PackedByteArray).to_int32_array()
	if search_leg.size() != capacity or search_from.size() != capacity:
		search_leg.resize(capacity)
		search_leg.fill(NO_LEG)
		search_from.resize(capacity)
		search_from.fill(NO_CELL)
	if energy_eaten.size() != items.count():
		energy_eaten.resize(items.count())
		energy_eaten.fill(0)
	if meals_by_item.size() != items.count():
		meals_by_item.resize(items.count())
		meals_by_item.fill(0)
	return alive.size() == capacity and x.size() == capacity and genome.size() == capacity * gene_count \
			and mem_cell.size() == capacity * memory_slots
