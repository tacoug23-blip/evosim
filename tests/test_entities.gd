## Phase 3 entity behaviour: eating, nutrition, utilities, memory, corpses, founders, survival,
## starvation, one-per-cell over long runs, determinism.
extends "res://tests/test_base.gd"

const EntitySystem := preload("res://sim/entity/entity_system.gd")
const Founders := preload("res://sim/entity/founders.gd")

const SUMMER := 1


## Open soil world without flora.
func _flat(w: int = 48, h: int = 48) -> RefCounted:
	var core := make_core("test_tiny", {"world.width": w, "world.height": h})
	var world: RefCounted = core.world
	var soil: int = core.substrates.id_of("soil")
	for c in world.cell_count:
		world.substrate[c] = soil
		world.flora_type[c] = 0
		world.flora_biomass[c] = 0
	core.env.recount()
	return core


func _spawn_at(core: RefCounted, p: Vector2i) -> int:
	var slot: int = core.entities.spawn(core.world.index(p.x, p.y), core.genes.defaults(), 0)
	check(slot >= 0, "spawned at %s" % p)
	return slot


func _set_energy_share(core: RefCounted, i: int, share: float) -> void:
	core.entities.energy[i] = roundi(core.entities.max_energy[i] * share)


func _summer(core: RefCounted) -> void:
	var t: int = core.time.ticks_per_season + 5
	core.env.begin_tick(t)
	core.entities.begin_tick(t)


func test_nutrition_lives_only_in_items() -> void:
	var core := make_core("test_tiny")
	check(not ("nutrition" in core.flora), "FloraTable has no nutrition field")
	var flora_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/flora.json"))
	for e: Dictionary in flora_json["flora"]:
		check(not e.has("nutrition"), "%s in flora.json has no nutrition" % e["name"])
	var expected_ids := ["", "hay", "twigs", "berries", "wood", "reeds", "mushrooms"]
	for id in range(1, 7):
		check_eq(core.items.names[id], expected_ids[id], "item id %d unchanged" % id)
		check(core.items.nutrition[id] > 0.0, "%s nutrition > 0" % expected_ids[id])
	var by_name := {}
	for id in range(1, core.items.count()):
		by_name[core.items.names[id]] = core.items.nutrition[id]
	check(by_name["berries"] > by_name["mushrooms"] and by_name["mushrooms"] > by_name["reeds"]
			and by_name["reeds"] > by_name["hay"] and by_name["hay"] > by_name["twigs"]
			and by_name["hay"] > by_name["wood"], "nutrition ranking berries > mushrooms > reeds > hay > twigs, wood")


func test_eating_each_item_gains_nutrition_times_digest() -> void:
	for t in range(1, 7):
		var core := _flat()
		_summer(core)
		var e: RefCounted = core.entities
		var plant_cell: int = core.world.index(20, 20)
		check(core.env.plant(plant_cell, t, 200, true), "planted type %d" % t)
		var i := _spawn_at(core, Vector2i(21, 20))
		_set_energy_share(core, i, 0.2)
		e.action[i] = EntitySystem.Action.FORAGE
		e.target[i] = plant_cell
		var biomass: int = core.world.flora_biomass[plant_cell]
		var before: int = e.energy[i]
		e.interact_one(i)
		var removed := mini(core.params.get_int("entity.bite_biomass"), biomass)
		var qty: int = core.env.yield_qty(t, removed)
		var item: int = core.flora.harvest_item[t]
		var digest: float = e.genome[i * e.gene_count + core.genes.index_of("digest_efficiency")]
		var expected := roundi(qty * core.items.nutrition[item] * digest * 1000)
		check_eq(e.energy[i] - before, expected, "%s: gain = qty %d x nutrition %.1f x digest %.2f" % [
				core.items.names[item], qty, core.items.nutrition[item], digest])
		check_eq(core.world.flora_biomass[plant_cell], biomass - removed, "%s: plant lost one bite" % core.flora.names[t])


func test_chooses_high_nutrition_food_at_equal_distance() -> void:
	for mirrored in [false, true]:
		var core := _flat()
		_summer(core)
		var berry_x := 27 if not mirrored else 21
		var grass_x := 21 if not mirrored else 27
		core.env.plant(core.world.index(berry_x, 24), core.flora.id_of("berry_bush"), 100, true)
		core.env.plant(core.world.index(grass_x, 24), core.flora.id_of("grass"), 100, true)
		var i := _spawn_at(core, Vector2i(24, 24))
		_set_energy_share(core, i, 0.3)
		core.entities.decide_one(i)
		check_eq(core.entities.action[i], EntitySystem.Action.FORAGE, "hungry entity forages")
		check_eq(core.entities.target[i], core.world.index(berry_x, 24),
				"berries (high nutrition) chosen over hay at equal distance (mirrored=%s)" % mirrored)


func test_low_value_food_eaten_only_when_better_is_scarce() -> void:
	var core := _flat()
	_summer(core)
	var i := _spawn_at(core, Vector2i(24, 24))
	_set_energy_share(core, i, 0.3)
	core.env.plant(core.world.index(25, 24), core.flora.id_of("tree"), 200, true)  # wood, adjacent
	core.entities.decide_one(i)
	check_eq(core.entities.target[i], core.world.index(25, 24), "only wood in sight: eats wood")
	core.env.plant(core.world.index(28, 24), core.flora.id_of("berry_bush"), 100, true)
	core.entities.decide_one(i)
	check_eq(core.entities.target[i], core.world.index(28, 24), "berries farther away still beat adjacent wood")


func test_utility_scores_match_chosen_action() -> void:
	var core := make_core("test_tiny", {"world.seed": 21})
	for k in core.time.ticks_per_year / 2:
		core.step()
	core.spawn_founders()
	for k in 300:
		core.step()
	var e: RefCounted = core.entities
	var checked := 0
	var mismatches := 0
	var seen := {}
	for i in e.capacity:
		if e.alive[i] == 0:
			continue
		e.decide_one(i)
		var best := 0
		var best_score := 0.0
		for a in range(1, EntitySystem.ACTIONS):
			if e.scores[i * EntitySystem.ACTIONS + a] > best_score:
				best_score = e.scores[i * EntitySystem.ACTIONS + a]
				best = a
		var d: Dictionary = e.describe(i)
		if best != e.action[i] or d["action"] != EntitySystem.ACTION_NAMES[best] or d["decided"] != d["action"]:
			mismatches += 1
		seen[d["action"]] = true
		checked += 1
	check(checked > 100, "checked %d entities" % checked)
	check_eq(mismatches, 0, "inspector scores' argmax equals the chosen action for every entity")
	check(seen.size() >= 2, "more than one action in use (%s)" % [seen.keys()])


func test_memory_ring_and_seeking_remembered_food() -> void:
	var core := _flat()
	_summer(core)
	var e: RefCounted = core.entities
	var food: int = core.world.index(30, 24)
	core.env.plant(food, core.flora.id_of("berry_bush"), 150, true)
	var i := _spawn_at(core, Vector2i(26, 24))
	_set_energy_share(core, i, 0.3)
	e.decide_one(i)
	var m0: int = i * e.memory_slots
	check_eq(e.mem_kind[m0], EntitySystem.Mem.FOOD, "food in sight is remembered")
	check_eq(e.mem_cell[m0], food, "at its cell")
	# Move the entity out of sight of the food: it should head back to the remembered cell.
	core.world.occupancy[e.y[i] * core.world.width + e.x[i]] = 0
	e.x[i] = 10
	e.y[i] = 24
	core.world.occupancy[core.world.index(10, 24)] = i + 1
	e.decide_one(i)
	check_eq(e.action[i], EntitySystem.Action.SEEK_FOOD, "seeks remembered food when none is in sight")
	check_eq(e.target[i], food, "toward the remembered cell")
	# The ring holds at most memory_capacity entries and wraps.
	var cap: int = e.mem_cap[i]
	for k in cap + 2:
		e._remember(i, EntitySystem.Mem.FOOD, core.world.index(k, 40))
	var stored := 0
	for m in e.memory_slots:
		if e.mem_kind[m0 + m] != EntitySystem.Mem.NONE:
			stored += 1
	check_eq(stored, cap, "ring keeps memory_capacity (%d) entries" % cap)


func test_default_genome_derived_costs() -> void:
	var core := _flat()
	var e: RefCounted = core.entities
	var i := _spawn_at(core, Vector2i(5, 5))
	check_eq(e.base_burn[i], 600, "default genome: base burn 0.600 per tick")
	check_eq(e.move_cost[i], 400, "default genome: move cost 0.400 per cell")
	# The old linear sense cost at radius 5: 0.02 per radius cell x 5 = 0.100 per tick.
	check_eq(e.sense_burn[i], 100, "default genome: sense burn 0.100 per tick, the old cost at r = 5")
	check_eq(e.rest_burn[i], roundi(600 * core.params.get_float("entity.rest_burn_factor")), "rest burn = base x rest factor")
	check_eq(core.genes.count(), 11, "11 genes")
	for gone: String in ["base_energy_burn", "move_energy_cost"]:
		check_eq(core.genes.index_of(gone), -1, "%s is not a gene" % gone)
	for k: String in ["burn_k_capacity", "burn_k_speed", "burn_k_digest", "burn_k_memory", "burn_k_hp",
			"move_cost_k_speed", "sense_cost_per_cell"]:
		check(core.params.get_float("entity." + k) > 0.0, "entity.%s > 0" % k)


## The derived cost `arr` of an entity whose genome is the default with `gene_name` = value.
func _cost_with(gene_name: String, value: float, arr: String) -> int:
	var core := _flat()
	var genome: PackedFloat32Array = core.genes.defaults()
	genome[core.genes.index_of(gene_name)] = value
	var i: int = core.entities.spawn(core.world.index(5, 5), genome, 0)
	return core.entities.get(arr)[i]


func test_each_derived_cost_rises_with_its_gene() -> void:
	var cases := [["max_energy", "base_burn"], ["move_speed", "base_burn"], ["move_speed", "move_cost"],
			["digest_efficiency", "base_burn"], ["memory_capacity", "base_burn"], ["max_hp", "base_burn"],
			["sense_radius", "sense_burn"]]
	var genes: RefCounted = make_core("test_tiny").genes
	for c: Array in cases:
		var g: int = genes.index_of(c[0])
		var lo: float = genes.minimum[g]
		var hi: float = genes.maximum[g]
		var values := [lo, genes.default_value[g], hi]
		var costs := []
		for v: float in values:
			costs.append(_cost_with(c[0], v, c[1]))
		check(costs[0] < costs[1] and costs[1] < costs[2], "%s rises with %s: %s at %s" % [c[1], c[0], costs, values])


## A hungry entity (energy 30% of max) with one remembered food cell out of sight, the memory
## `age_share` of entity.memory_days old. Returns [core, slot] after one decision.
func _hungry_with_memory(age_share: float) -> Array:
	var core := _flat()
	_summer(core)
	var e: RefCounted = core.entities
	var i := _spawn_at(core, Vector2i(10, 24))
	_set_energy_share(core, i, 0.3)
	var m0: int = i * e.memory_slots
	e.mem_kind[m0] = EntitySystem.Mem.FOOD
	e.mem_cell[m0] = core.world.index(40, 24)
	e.mem_tick[m0] = e._tick - roundi(age_share * e._mem_ticks)
	e.decide_one(i)
	return [core, i]


func test_stale_memory_does_not_stop_a_hungry_entity_searching() -> void:
	var r := _hungry_with_memory(0.9)
	var e: RefCounted = r[0].entities
	var s0: int = r[1] * EntitySystem.ACTIONS
	var wander: float = e.scores[s0 + EntitySystem.Action.WANDER]
	check(wander > e.scores[s0 + EntitySystem.Action.REST], "stale memory, hungry: wander %.3f > rest %.3f" % [
			wander, e.scores[s0 + EntitySystem.Action.REST]])
	check(wander > e.scores[s0 + EntitySystem.Action.SEEK_FOOD], "and > seek %.3f" % e.scores[s0 + EntitySystem.Action.SEEK_FOOD])
	check_eq(e.action[r[1]], EntitySystem.Action.WANDER, "it wanders (searches)")


func test_fresh_memory_beats_wandering() -> void:
	var r := _hungry_with_memory(0.0)
	var e: RefCounted = r[0].entities
	var s0: int = r[1] * EntitySystem.ACTIONS
	check(e.scores[s0 + EntitySystem.Action.SEEK_FOOD] > e.scores[s0 + EntitySystem.Action.WANDER],
			"fresh memory, hungry: seek %.3f > wander %.3f" % [e.scores[s0 + EntitySystem.Action.SEEK_FOOD],
			e.scores[s0 + EntitySystem.Action.WANDER]])
	check_eq(e.action[r[1]], EntitySystem.Action.SEEK_FOOD, "it seeks the remembered food")
	# Crossover: seek = forage*h*trust*f equals wander = explore*(base + w_hunger*h) at
	# f* = explore*(base + w_hunger*h) / (forage*h*trust). Check the switch happens there.
	var p: RefCounted = r[0].params
	var h: float = 1.0 - 0.3 / r[0].genes.default_value[r[0].genes.index_of("food_needed_to_sate")]
	var f_star: float = r[0].genes.default_value[r[0].genes.index_of("explore")] * (p.get_float("entity.wander_base")
			+ p.get_float("entity.wander_hunger") * h) / (r[0].genes.default_value[r[0].genes.index_of("forage")]
			* h * p.get_float("entity.memory_trust"))
	var above: Array = _hungry_with_memory(1.0 - f_star - 0.02)
	var below: Array = _hungry_with_memory(1.0 - f_star + 0.02)
	check_eq(above[0].entities.action[above[1]], EntitySystem.Action.SEEK_FOOD, "seeks just above freshness %.3f (hunger %.3f)" % [f_star, h])
	check_eq(below[0].entities.action[below[1]], EntitySystem.Action.WANDER, "wanders just below freshness %.3f" % f_star)


## A stranded founder cluster: 225 hungry entities 3 cells apart (about 11% density, like a
## founder group) on open land with no food anywhere. Each keeps a dozen others in sight, so
## turning away from the crowd at every decision made them random-walk in place (before the fix:
## slowest 4 cells, median 53). Searchers must leave in straight lines instead: every entity at
## least N = 100 cells of net (Chebyshev) displacement in M = 240 ticks (2.5 days); a straight
## walk at the default speed covers about 140.
func test_stranded_hungry_cluster_disperses() -> void:
	var core := _flat(384, 384)
	var e: RefCounted = core.entities
	var slots := []
	var start := {}
	for dy in range(-7, 8):
		for dx in range(-7, 8):
			var i := _spawn_at(core, Vector2i(192 + 3 * dx, 192 + 3 * dy))
			_set_energy_share(core, i, 0.45)
			slots.append(i)
			start[i] = Vector2i(e.x[i], e.y[i])
	for t in 240:
		core.step()
	var moved := []
	for i: int in slots:
		check(e.alive[i] == 1, "slot %d still alive" % i)
		var d: Vector2i = Vector2i(e.x[i], e.y[i]) - start[i]
		moved.append(maxi(absi(d.x), absi(d.y)))
	var sorted := moved.duplicate()
	sorted.sort()
	check(moved[112] >= 100, "the centre entity moved %d cells net in 240 ticks (need 100)" % moved[112])
	check(sorted[0] >= 100, "every entity moved >= 100 cells net (slowest %d, median %d)" % [sorted[0], sorted[112]])


func test_slots_are_recycled_with_a_new_generation() -> void:
	var core := _flat()
	var e: RefCounted = core.entities
	var a := _spawn_at(core, Vector2i(5, 5))
	var gen: int = e.generation[a]
	e.kill(a, EntitySystem.Cause.STARVATION)
	check(not e.is_handle_alive(a, gen), "old handle dead")
	check_eq(core.world.occupancy[core.world.index(5, 5)], 0, "cell freed")
	check(core.corpses.at(core.world.index(5, 5)) >= 0, "corpse left on the cell")
	var b := _spawn_at(core, Vector2i(9, 9))
	check_eq(b, a, "slot reused")
	check_eq(e.generation[b], gen + 1, "with generation + 1")
	check(e.is_handle_alive(b, gen + 1), "new handle alive")


func test_corpse_pick_up_carry_drop_and_eat() -> void:
	var core := _flat()
	var e: RefCounted = core.entities
	var cells := [core.world.index(10, 10), core.world.index(30, 30)]
	var k: int = core.corpses.create(cells[0])
	var i := _spawn_at(core, Vector2i(11, 10))
	e.action[i] = EntitySystem.Action.PICK_UP
	e.target[i] = cells[0]
	e.interact_one(i)
	check_eq(e.carrying[i], k + 1, "picked up")
	check_eq(core.world.corpse_id[cells[0]], 0, "a carried corpse occupies no cell")
	check_eq(e.check_invariants(), "", "invariants while carrying")
	e.action[i] = EntitySystem.Action.DROP
	e.interact_one(i)
	check_eq(e.carrying[i], 0, "dropped")
	check_eq(core.corpses.at(core.world.index(11, 10)), k, "corpse lies at the carrier's cell")
	# Eating needs corpse.edible.
	check(not core.corpses.edible, "corpses are not edible by default")
	_set_energy_share(core, i, 0.2)
	e.decide_one(i)
	check_eq(e.scores[i * EntitySystem.ACTIONS + EntitySystem.Action.EAT_CORPSE], 0.0, "no eat-corpse utility when not edible")
	core.corpses.edible = true
	e.decide_one(i)
	check(e.scores[i * EntitySystem.ACTIONS + EntitySystem.Action.EAT_CORPSE] > 0.0, "eat-corpse utility when edible")
	e.action[i] = EntitySystem.Action.EAT_CORPSE
	e.target[i] = core.world.index(11, 10)
	var before: int = e.energy[i]
	var mass_before: int = core.corpses.mass[k]
	e.interact_one(i)
	var bite_milli := roundi(core.params.get_float("corpse.bite_mass") * 1000)
	var digest: float = e.genome[i * e.gene_count + core.genes.index_of("digest_efficiency")]
	var expected := roundi(roundi(bite_milli * core.params.get_float("corpse.nutrition_per_mass")) * digest)
	check_eq(e.energy[i] - before, expected, "corpse bite gain = mass x corpse nutrition x digest")
	check_eq(core.corpses.mass[k], mass_before - bite_milli, "corpse lost one bite of mass")


func test_corpse_decay_fertilises_nearby_land() -> void:
	var core := _flat()
	var world: RefCounted = core.world
	for c in world.cell_count:
		world.fertility[c] = 50
	var centre: int = world.index(20, 20)
	core.corpses.create(centre)
	var decay_ticks := roundi(core.params.get_float("corpse.decay_days") * core.time.ticks_per_day)
	var interval: int = core.params.get_int("corpse.update_interval")
	for t in range(interval, decay_ticks + 2 * interval, interval):
		core.corpses.tick(t)
	check_eq(core.corpses.count, 0, "corpse gone after decaying")
	check(world.fertility[centre] > 50, "fertility rose at the corpse (%d)" % world.fertility[centre])
	check(world.fertility[world.index(22, 22)] > 50, "and within spread_radius")
	check_eq(world.fertility[world.index(30, 30)], 50, "but not far away")


func test_founder_groups() -> void:
	var core := make_core("test_tiny", {"world.seed": 3})
	var res: Dictionary = core.spawn_founders({"groups": 3, "size_min": 20, "size_max": 30, "spacing": 60})
	check_eq(res["groups"].size(), 3, "three groups")
	var total := 0
	for g: Dictionary in res["groups"]:
		check(g["size"] >= 20 and g["size"] <= 30, "group size within range (%d)" % g["size"])
		check_eq(g["placed"], g["size"], "every member placed")
		total += g["placed"]
	for a in 3:
		for b in range(a + 1, 3):
			var d := Vector2(res["groups"][a]["centre"]).distance_to(Vector2(res["groups"][b]["centre"]))
			check(d >= 60, "centres at least 60 apart (%.0f)" % d)
	check_eq(core.entities.count, total, "count")
	check_eq(core.entities.check_invariants(), "", "invariants")


func test_no_cell_ever_holds_two_entities_over_10k_ticks() -> void:
	var core := make_core("test_tiny", {"world.seed": 4})
	for k in core.time.ticks_per_year / 2:
		core.step()
	core.spawn_founders()
	var e: RefCounted = core.entities
	var violation := ""
	var swaps := 0
	var last_x := PackedInt32Array()
	var last_y := PackedInt32Array()
	for t in 10000:
		last_x = e.x.duplicate()
		last_y = e.y.duplicate()
		var before := {}
		for i in e.capacity:
			if e.alive[i] == 1:
				before[Vector2i(e.x[i], e.y[i])] = i
		core.step()
		for i in e.capacity:
			if e.alive[i] == 0 or i >= last_x.size():
				continue
			var now := Vector2i(e.x[i], e.y[i])
			var old := Vector2i(last_x[i], last_y[i])
			if now != old and before.has(now):
				var k: int = before[now]
				if k != i and e.alive[k] == 1 and Vector2i(e.x[k], e.y[k]) == old:
					swaps += 1
		var inv: String = e.check_invariants()
		if not inv.is_empty() and violation.is_empty():
			violation = "tick %d: %s" % [core.tick, inv]
	check_eq(violation, "", "one entity per cell, corpses consistent, every tick for 10,000 ticks")
	check_eq(swaps, 0, "no swaps")


func test_starving_entities_leave_corpses_that_fertilise() -> void:
	var core := make_core("test_tiny", {"world.seed": 5})
	var world: RefCounted = core.world
	for c in world.cell_count:  # scarce: no flora at all
		world.flora_type[c] = 0
		world.flora_biomass[c] = 0
	core.env.recount()
	core.spawn_founders({"groups": 2, "size_min": 30, "size_max": 30})
	var e: RefCounted = core.entities
	for i in e.capacity:
		if e.alive[i] == 1:
			_set_energy_share(core, i, 0.05)
	var sites := PackedInt32Array()
	var fert_at_death := {}
	var deaths_before := 0
	for t in 2 * core.time.ticks_per_day:
		core.step()
		if e.deaths_by_cause[0] > deaths_before:
			deaths_before = e.deaths_by_cause[0]
			for k in core.corpses.capacity:
				if core.corpses.alive[k] == 1 and not fert_at_death.has(core.corpses.cell[k]):
					fert_at_death[core.corpses.cell[k]] = world.fertility[core.corpses.cell[k]]
					sites.append(core.corpses.cell[k])
	check_eq(e.count, 0, "with no food, every entity starves")
	check(e.deaths_by_cause[0] == 60, "60 starvation deaths (%d)" % e.deaths_by_cause[0])
	check(sites.size() > 0, "corpses left (%d sites)" % sites.size())
	var decay_ticks := roundi(core.params.get_float("corpse.decay_days") * core.time.ticks_per_day)
	for t in decay_ticks + 2 * core.params.get_int("corpse.update_interval"):
		core.step()
	check_eq(core.corpses.count, 0, "corpses decayed")
	var rose := 0
	for c in sites:
		if world.fertility[c] > fert_at_death[c]:
			rose += 1
	check(rose * 10 >= sites.size() * 9, "fertility rose at >= 90%% of corpse sites (%d of %d)" % [rose, sites.size()])


func test_abundant_flora_founders_survive_and_keep_eating() -> void:
	var core := make_core("test_tiny", {"world.seed": 2})
	for k in core.time.ticks_per_year:
		core.step()
	core.spawn_founders()
	var e: RefCounted = core.entities
	var n0: int = e.count
	for k in 30 * core.time.ticks_per_day:
		core.step()
	var ate := 0
	for i in e.capacity:
		if e.alive[i] == 1 and e.meals[i] >= 2:
			ate += 1
	check(e.count * 100 >= n0 * 95, "at least 95%% survive 30 days (%d of %d)" % [e.count, n0])
	check(ate * 100 >= e.count * 90, "at least 90%% of survivors ate 2+ meals (%d of %d)" % [ate, e.count])


func test_same_result_for_any_thread_count() -> void:
	var hashes := []
	for threads in [1, 3, 8]:
		var core := make_core("test_tiny", {"world.seed": 6, "sim.worker_threads": threads,
				"sim.parallel_min_items": 1})
		core.spawn_founders()
		for k in 1500:
			core.step()
		hashes.append(core.full_hash())
	check_eq(hashes[1], hashes[0], "3 threads match 1 thread")
	check_eq(hashes[2], hashes[0], "8 threads match 1 thread")


func test_same_seed_same_state() -> void:
	var runs := []
	for r in 2:
		var core := make_core("test_tiny", {"world.seed": 7})
		core.spawn_founders()
		for k in 1000:
			core.step()
		runs.append(core.full_hash())
	check_eq(runs[1], runs[0], "same seed, same full-state hash after 1000 ticks")
