## Headless sim state: params, RNG streams, config tables, world layers, time, the sampled
## environment pass, entities and corpses, and the tick counter. No UI or scene-tree
## dependency: runs under `godot --headless`. Renderers read from it through render_snapshot()
## and the probes; they never write and never hold references to live arrays.
extends RefCounted

const Rng := preload("res://sim/core/rng.gd")
const StateHash := preload("res://sim/core/state_hash.gd")
const Substrates := preload("res://sim/world/substrates.gd")
const World := preload("res://sim/world/world.gd")
const TerrainGen := preload("res://sim/world/terrain_gen.gd")
const TimeSystem := preload("res://sim/env/time_system.gd")
const Items := preload("res://sim/env/items.gd")
const FloraTable := preload("res://sim/env/flora_table.gd")
const EnvSystem := preload("res://sim/env/env_system.gd")
const GeneTable := preload("res://sim/entity/genes.gd")
const Corpses := preload("res://sim/entity/corpses.gd")
const EntitySystem := preload("res://sim/entity/entity_system.gd")
const Founders := preload("res://sim/entity/founders.gd")

var params: RefCounted
var rngs: RefCounted
var substrates: RefCounted
var items: RefCounted
var flora: RefCounted
var genes: RefCounted
var world: RefCounted
var time: RefCounted
var env: RefCounted
var corpses: RefCounted
var entities: RefCounted
var tick := 0
var terrain_stats := {}
var error := ""


## Build a fresh world from the registry's current values, then lock structural params.
func init_new(p_params: RefCounted) -> bool:
	params = p_params
	if not _load_tables():
		return false
	rngs = Rng.new(params.get_int("world.seed"))
	world = World.new(params.get_int("world.width"), params.get_int("world.height"))
	terrain_stats = TerrainGen.generate(world, params, rngs, substrates)
	tick = 0
	if not _setup_systems():
		return false
	env.seed_initial(rngs)
	params.lock_structural()
	return true


## Wire up pieces restored by the save loader. Returns false if config tables fail to load.
func init_from_parts(p_params: RefCounted, p_rngs: RefCounted, p_world: RefCounted,
		p_tick: int) -> bool:
	params = p_params
	if not _load_tables():
		return false
	rngs = p_rngs
	world = p_world
	tick = p_tick
	if not _setup_systems():
		return false
	params.lock_structural()
	return true


func _load_tables() -> bool:
	substrates = Substrates.new()
	items = Items.new()
	flora = FloraTable.new()
	genes = GeneTable.new()
	if not substrates.load_file():
		error = "; ".join(substrates.errors)
	elif not items.load_file():
		error = "; ".join(items.errors)
	elif not flora.load_file(substrates, items):
		error = "; ".join(flora.errors)
	elif not genes.load_file():
		error = "; ".join(genes.errors)
	return error.is_empty()


func _setup_systems() -> bool:
	time = TimeSystem.new()
	time.setup(params)
	env = EnvSystem.new()
	env.setup(world, substrates, flora, items, time, params, rngs)
	corpses = Corpses.new()
	corpses.setup(world, substrates, params, time)
	entities = EntitySystem.new()
	if not entities.setup(world, substrates, flora, items, env, corpses, genes, time, params, rngs):
		error = "entity system setup failed (see log)"
		return false
	return true


## Spawn founder groups (founders.* params, optionally overridden). Returns the spawner's
## summary. Sequential: call between ticks.
func spawn_founders(overrides: Dictionary = {}) -> Dictionary:
	return Founders.spawn(entities, params, rngs, overrides)


func step() -> void:
	tick += 1
	env.tick(tick)
	entities.tick(tick)


func world_hash() -> String:
	return world.hash_state()


## Hash of everything that determines the future: tick, seed, layers, entities, corpses, RNG
## state. Time and weather are pure functions of the tick and seed, so they need no hashing.
func full_hash() -> String:
	var h := StateHash.new()
	h.add_int(tick)
	h.add_int(rngs.master_seed)
	h.add_string(world_hash())
	h.add_string(entities.hash_state())
	var state: Dictionary = rngs.get_state()
	for stream_name in rngs.stream_names():
		h.add_string(stream_name)
		h.add_string(state[stream_name])
	return h.finish_hex()


## Everything the UI shows about one cell. Call between ticks (SimRunner.request_probe).
func probe_cell(cell: int) -> Dictionary:
	var w: RefCounted = world
	if cell < 0 or cell >= w.cell_count:
		return {}
	var t: int = w.flora_type[cell]
	var occupant: int = w.occupancy[cell]
	return {
		"cell": cell,
		"x": cell % w.width,
		"y": cell / w.width,
		"substrate": substrates.names[w.substrate[cell]],
		"fertility": w.fertility[cell],
		"moisture": w.moisture[cell],
		"flora": flora.names[t] if t > 0 else "",
		"biomass": w.flora_biomass[cell],
		"occupant": occupant,
		"occupant_generation": entities.generation[occupant - 1] if occupant > 0 else -1,
		"corpse": w.corpse_id[cell] - 1,
	}


## The inspector's view of one entity, or {} if (slot, generation) is no longer alive.
func probe_entity(slot: int, gen: int) -> Dictionary:
	if not entities.is_handle_alive(slot, gen):
		return {}
	return entities.describe(slot)


## Read-only copies of what the renderer needs, taken between ticks on the sim thread.
## `layers` names world layers to copy (16 MB each at 4096x4096). slice(0) makes a real copy;
## duplicate() would share the buffer copy-on-write and the next sim write would pay for it,
## possibly inside a parallel phase.
func render_snapshot(layers: PackedStringArray = PackedStringArray()) -> Dictionary:
	var e: RefCounted = entities
	var snap := {
		"tick": tick,
		"entity_capacity": e.capacity,
		"entity_count": e.count,
		"entity_x": e.x.to_byte_array(),
		"entity_y": e.y.to_byte_array(),
		"entity_energy": e.energy.to_byte_array(),
		"entity_max_energy": e.max_energy.to_byte_array(),
		"entity_sex": e.sex.slice(0),
		"layers": {},
	}
	for layer_name in layers:
		var data: Variant = world.get(layer_name)
		if data is PackedByteArray:
			snap["layers"][layer_name] = (data as PackedByteArray).slice(0)
	return snap
