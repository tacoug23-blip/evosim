extends "res://tests/test_base.gd"

const World := preload("res://sim/world/world.gd")
const Substrates := preload("res://sim/world/substrates.gd")
const TerrainGen := preload("res://sim/world/terrain_gen.gd")
const Rng := preload("res://sim/core/rng.gd")


func test_layers_allocated_and_zeroed() -> void:
	var w := World.new(64, 32)
	check_eq(w.cell_count, 2048, "cell count")
	for layer_name in World.layer_names():
		var bytes: PackedByteArray = w.layer_bytes(layer_name)
		check_eq(bytes.size(), 2048 * World.layer_cell_bytes(layer_name), "%s size" % layer_name)
		check_eq(bytes.count(0), bytes.size(), "%s zeroed" % layer_name)
	w.set_structure_hp(w.index(5, 3), 54321)
	check_eq(w.get_structure_hp(w.index(5, 3)), 54321, "u16 structure_hp roundtrip")
	check_eq(w.get_structure_hp(w.index(6, 3)), 0, "neighbour hp untouched")


func test_terrain_same_seed_same_hash() -> void:
	var a := make_core("test_tiny", {"world.seed": 11})
	var b := make_core("test_tiny", {"world.seed": 11})
	var c := make_core("test_tiny", {"world.seed": 12})
	check_eq(a.world_hash(), b.world_hash(), "same seed, same world")
	check(a.world_hash() != c.world_hash(), "different seed, different world")


func test_world_hash_is_pinned() -> void:
	# Golden value: test_tiny preset, seed 1337, terrain only (pinned in Phase 1, unchanged since).
	# Terrain comes from FastNoiseLite, so this hash is pinned to the engine version recorded in
	# docs/DECISIONS.md. A mismatch means terrain generation changed (code, params,
	# substrates.json) or the engine did.
	var params := make_params("test_tiny", {"world.seed": 1337})
	var w := World.new(params.get_int("world.width"), params.get_int("world.height"))
	var subs := Substrates.new()
	subs.load_file()
	TerrainGen.generate(w, params, Rng.new(1337), subs)
	check_eq(w.hash_state(), GOLDEN_WORLD_HASH_TINY_1337,
			"terrain-only world hash for test_tiny / seed 1337 (engine %s, pinned on %s)" % [
			Engine.get_version_info()["string"], PINNED_ENGINE])


func test_initial_world_hash_is_pinned() -> void:
	# Golden value: the full initial world (terrain + initial flora) for test_tiny / seed 1337.
	# Pinned in Phase 2; changes if world generation or flora seeding (flora.json) changes.
	var core := make_core("test_tiny", {"world.seed": 1337})
	check_eq(core.world_hash(), GOLDEN_INITIAL_WORLD_HASH_TINY_1337,
			"initial world hash for test_tiny / seed 1337 (engine %s)" % Engine.get_version_info()["string"])


func test_terrain_is_valid_and_varied() -> void:
	var core := make_core("test_tiny", {"world.width": 512, "world.height": 512})
	var w: RefCounted = core.world
	var subs: RefCounted = core.substrates
	var present := 0
	for id in subs.count():
		if w.substrate.count(id) > 0:
			present += 1
	check_eq(w.substrate.size() - _count_below(w.substrate, subs.count()), 0, "all substrate ids valid")
	check(present >= 4, "at least 4 substrate types present (got %d)" % present)
	var water_frac: float = core.terrain_stats["fractions"]["water"]
	check(water_frac > 0.05 and water_frac < 0.7, "water fraction plausible (%.2f)" % water_frac)
	var water: int = subs.id_of("water")
	for i in range(0, w.cell_count, 97):
		if w.substrate[i] == water:
			check_eq(w.moisture[i], 255, "water is saturated")
			check_eq(w.fertility[i], 0, "water is infertile")
			break
	check(w.fertility.count(0) < w.cell_count, "some fertile land")


func test_hash_sees_every_layer() -> void:
	var w := World.new(16, 16)
	var base := w.hash_state()
	w.occupancy[17] = 3
	var h1 := w.hash_state()
	check(h1 != base, "occupancy change alters hash")
	w.set_structure_hp(200, 1)
	check(w.hash_state() != h1, "structure_hp change alters hash")


func _count_below(bytes: PackedByteArray, limit: int) -> int:
	var n := 0
	for v in limit:
		n += bytes.count(v)
	return n


const PINNED_ENGINE := "4.6.1-stable (official)"
const GOLDEN_WORLD_HASH_TINY_1337 := "8ad937c4c170a5a0a0833553704110a580db7a6f5d6b7477af4da45db4a98ece"
const GOLDEN_INITIAL_WORLD_HASH_TINY_1337 := "9c8798ab99fe7177834d157af8778d8044307d9c71a129a7d808b9484cddd32c"
