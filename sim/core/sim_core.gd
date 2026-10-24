## Headless sim state: params, RNG streams, config tables, world layers, time, the sampled
## environment pass, the tick counter, and (Phase 1 only) the performance spike. No UI or
## scene-tree dependency: runs under `godot --headless`. Renderers read from it, through
## render_snapshot(); they never write and never hold references to live arrays.
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
const Spike := preload("res://sim/spike/spike.gd")

var params: RefCounted
var rngs: RefCounted
var substrates: RefCounted
var items: RefCounted
var flora: RefCounted
var world: RefCounted
var time: RefCounted
var env: RefCounted
var spike: RefCounted = null
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
	_setup_env()
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
	_setup_env()
	params.lock_structural()
	return true


func _load_tables() -> bool:
	substrates = Substrates.new()
	items = Items.new()
	flora = FloraTable.new()
	if not substrates.load_file():
		error = "; ".join(substrates.errors)
	elif not items.load_file():
		error = "; ".join(items.errors)
	elif not flora.load_file(substrates, items):
		error = "; ".join(flora.errors)
	return error.is_empty()


func _setup_env() -> void:
	time = TimeSystem.new()
	time.setup(params)
	env = EnvSystem.new()
	env.setup(world, substrates, flora, items, time, params, rngs)


func spawn_spike(n: int) -> int:
	clear_spike()
	if n <= 0:
		return 0
	spike = Spike.new()
	spike.setup(world, substrates, params, rngs)
	return spike.spawn(n)


func clear_spike() -> void:
	if spike != null:
		spike.despawn()
		spike = null


func spike_count() -> int:
	return spike.count if spike != null else 0


func step() -> void:
	tick += 1
	env.tick(tick)
	if spike != null:
		spike.tick(tick)


func world_hash() -> String:
	return world.hash_state()


## Hash of everything that determines the future: tick, seed, layers, entities, RNG state.
## Time and weather are pure functions of the tick and seed, so they need no hashing.
func full_hash() -> String:
	var h := StateHash.new()
	h.add_int(tick)
	h.add_int(rngs.master_seed)
	h.add_string(world_hash())
	h.add_string(spike.hash_state() if spike != null else "")
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
	return {
		"cell": cell,
		"x": cell % w.width,
		"y": cell / w.width,
		"substrate": substrates.names[w.substrate[cell]],
		"fertility": w.fertility[cell],
		"moisture": w.moisture[cell],
		"flora": flora.names[t] if t > 0 else "",
		"biomass": w.flora_biomass[cell],
		"occupant": w.occupancy[cell],
	}


## Read-only copies of what the renderer needs, taken between ticks on the sim thread.
## `layers` names world layers to copy (16 MB each at 4096x4096). slice(0) makes a real copy;
## duplicate() would share the buffer copy-on-write and the next sim write would pay for it,
## possibly inside a parallel phase.
func render_snapshot(layers: PackedStringArray = PackedStringArray()) -> Dictionary:
	var snap := {"tick": tick, "spike_count": spike_count(), "layers": {}}
	if spike != null:
		snap["spike_x"] = spike.x.to_byte_array()
		snap["spike_y"] = spike.y.to_byte_array()
	for layer_name in layers:
		var data: Variant = world.get(layer_name)
		if data is PackedByteArray:
			snap["layers"][layer_name] = (data as PackedByteArray).slice(0)
	return snap
