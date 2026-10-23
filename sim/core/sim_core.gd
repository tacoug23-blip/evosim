## Headless sim state: params, RNG streams, substrate table, world layers, tick counter, and
## (Phase 1 only) the performance spike. No UI or scene-tree dependency: runs under
## `godot --headless`. Renderers read from it; they never write.
extends RefCounted

const Rng := preload("res://sim/core/rng.gd")
const StateHash := preload("res://sim/core/state_hash.gd")
const Substrates := preload("res://sim/world/substrates.gd")
const World := preload("res://sim/world/world.gd")
const TerrainGen := preload("res://sim/world/terrain_gen.gd")
const Spike := preload("res://sim/spike/spike.gd")

var params: RefCounted
var rngs: RefCounted
var substrates: RefCounted
var world: RefCounted
var spike: RefCounted = null
var tick := 0
var terrain_stats := {}
var error := ""


## Build a fresh world from the registry's current values, then lock structural params.
func init_new(p_params: RefCounted) -> bool:
	params = p_params
	substrates = Substrates.new()
	if not substrates.load_file():
		error = "; ".join(substrates.errors)
		return false
	rngs = Rng.new(params.get_int("world.seed"))
	world = World.new(params.get_int("world.width"), params.get_int("world.height"))
	terrain_stats = TerrainGen.generate(world, params, rngs, substrates)
	tick = 0
	params.lock_structural()
	return true


## Wire up pieces restored by the save loader.
func init_from_parts(p_params: RefCounted, p_substrates: RefCounted, p_rngs: RefCounted,
		p_world: RefCounted, p_tick: int) -> void:
	params = p_params
	substrates = p_substrates
	rngs = p_rngs
	world = p_world
	tick = p_tick
	params.lock_structural()


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
	if spike != null:
		spike.tick(tick)


func world_hash() -> String:
	return world.hash_state()


## Hash of everything that determines the future: tick, seed, layers, entities, RNG state.
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


## Read-only copy of what the renderer needs, taken between ticks.
func render_snapshot() -> Dictionary:
	var snap := {"tick": tick, "spike_count": spike_count()}
	if spike != null:
		snap["spike_x"] = spike.x.to_byte_array()
		snap["spike_y"] = spike.y.to_byte_array()
	return snap
