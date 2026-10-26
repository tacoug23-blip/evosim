extends "res://tests/test_base.gd"

const SaveLoad := preload("res://sim/io/save_load.gd")


func _running_core(seed_value: int, ticks: int) -> RefCounted:
	var core := make_core("test_tiny", {"world.seed": seed_value})
	core.spawn_founders()
	for t in ticks:
		core.step()
	return core


func test_roundtrip_preserves_everything() -> void:
	var core := _running_core(21, 25)
	var path := tmp_path("roundtrip.evosave")
	check_eq(SaveLoad.save(core, path), OK, "save succeeds")
	var res := SaveLoad.load_file(path)
	check_eq(res["error"], "", "load succeeds")
	var loaded: RefCounted = res["core"]
	if loaded == null:
		return
	check_eq(loaded.world_hash(), core.world_hash(), "world hash identical after load")
	check_eq(loaded.full_hash(), core.full_hash(), "full hash identical after load")
	check_eq(loaded.tick, core.tick, "tick restored")
	check_eq(loaded.rngs.master_seed, 21, "seed restored")
	check_eq(loaded.params.snapshot(), core.params.snapshot(), "parameter snapshot restored")
	check_eq(loaded.rngs.get_state(), core.rngs.get_state(), "rng streams restored")


func test_derived_costs_survive_save_load() -> void:
	# Jittered genomes, so the derived costs differ from entity to entity.
	var core := make_core("test_tiny", {"world.seed": 8, "founders.gene_jitter": 0.2})
	core.spawn_founders()
	var e: RefCounted = core.entities
	var distinct := {}
	for i in e.capacity:
		if e.alive[i] == 1:
			distinct[e.base_burn[i]] = true
	check(distinct.size() > 10, "jittered founders have varied base burn (%d distinct values)" % distinct.size())
	var path := tmp_path("derived.evosave")
	check_eq(SaveLoad.save(core, path), OK, "save succeeds")
	var loaded: RefCounted = SaveLoad.load_file(path)["core"]
	if not check(loaded != null, "load succeeds"):
		return
	for arr: String in ["base_burn", "rest_burn", "sense_burn", "move_cost"]:
		check_eq(loaded.entities.get(arr), e.get(arr), "%s identical after load" % arr)


func test_world_only_roundtrip() -> void:
	var core := make_core("test_tiny", {"world.seed": 3})
	var path := tmp_path("world_only.evosave")
	check_eq(SaveLoad.save(core, path), OK, "save succeeds")
	var loaded: RefCounted = SaveLoad.load_file(path)["core"]
	check(loaded != null and loaded.world_hash() == core.world_hash(), "world hash identical")
	check(loaded != null and loaded.entities.count == 0, "no entities when none were saved")


func test_continuing_after_load_matches_uninterrupted_run() -> void:
	var core := _running_core(33, 20)
	var path := tmp_path("continue.evosave")
	SaveLoad.save(core, path)
	for t in 40:
		core.step()
	var loaded: RefCounted = SaveLoad.load_file(path)["core"]
	if not check(loaded != null, "load succeeds"):
		return
	for t in 40:
		loaded.step()
	check_eq(loaded.full_hash(), core.full_hash(), "save/load does not perturb the future")


func test_rejects_foreign_and_future_files() -> void:
	SaveLoad.quiet = true
	var junk := tmp_path("junk.evosave")
	var f := FileAccess.open(junk, FileAccess.WRITE)
	f.store_string("definitely not a save file")
	f.close()
	check(SaveLoad.load_file(junk)["core"] == null, "bad magic rejected")

	var future := tmp_path("future.evosave")
	f = FileAccess.open(future, FileAccess.WRITE)
	f.store_buffer("EVOS".to_ascii_buffer())
	f.store_32(SaveLoad.FORMAT_VERSION + 1)
	f.store_32(2)
	f.store_string("{}")
	f.close()
	var res := SaveLoad.load_file(future)
	check(res["core"] == null and "version" in res["error"], "newer format version rejected")

	check(SaveLoad.load_file(tmp_path("missing.evosave"))["core"] == null, "missing file rejected")


func test_saves_all_rng_streams_and_flora() -> void:
	var core := _running_core(41, 30)
	var path := tmp_path("streams.evosave")
	SaveLoad.save(core, path)
	var loaded: RefCounted = SaveLoad.load_file(path)["core"]
	if not check(loaded != null, "load succeeds"):
		return
	for stream_name in ["terrain", "flora.init", "founders", "entity.resolve"]:
		check(loaded.rngs.stream_names().has(stream_name), "stream %s saved" % stream_name)
	check_eq(loaded.rngs.get_state(), core.rngs.get_state(), "every stream state restored")
	check_eq(loaded.env.coverage, core.env.coverage, "flora coverage totals restored")
	check_eq(loaded.env.biomass, core.env.biomass, "flora biomass totals restored")
	check_eq(loaded.time.describe(loaded.tick), core.time.describe(core.tick), "time derives from the saved tick")
	check_eq(loaded.env.climate, core.env.climate, "climate grid regenerates identically from the seed")


func test_reads_version_1_saves() -> void:
	var core := _running_core(42, 10)
	var path := tmp_path("v1.evosave")
	SaveLoad.save(core, path)
	# Rewrite the version field (bytes 4-7) to 1, as a Phase 1 build would have written it.
	var bytes := FileAccess.get_file_as_bytes(path)
	bytes.encode_u32(4, 1)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	var res := SaveLoad.load_file(path)
	check_eq(res["error"], "", "version 1 save loads")
	if res["core"] != null:
		check_eq(res["core"].full_hash(), core.full_hash(), "and restores the same state")


## Version 1 and 2 files as those builds wrote them: world layers only, no entity or corpse
## blocks or header sections, a Phase 1/2 parameter snapshot (spike.* params, no entity.*);
## version 1 also has spike blocks and spike ids in the occupancy layer. Both load with no
## entities and an empty occupancy layer.
func test_reads_pre_v3_layouts() -> void:
	for version in [1, 2]:
		var core := make_core("test_tiny", {"world.seed": 5})
		for t in 5:
			core.step()
		var occ: PackedInt32Array = core.world.occupancy
		if version == 1:
			for k in 3:
				occ[core.world.index(10 + k, 10)] = k + 1
		var snap: Dictionary = core.params.snapshot()
		for id: String in snap.keys():
			if id.begins_with("entity.") or id.begins_with("corpse.") or id.begins_with("founders."):
				snap.erase(id)
		snap["spike.entity_count"] = 3
		var header := {"format_version": version, "seed": core.rngs.master_seed, "tick": core.tick,
				"width": core.world.width, "height": core.world.height, "params": snap, "rng": core.rngs.get_state(),
				"substrates_hash": core.substrates.source_hash, "flora_hash": core.flora.source_hash,
				"world_hash": core.world_hash()}
		if version == 2:
			header["env_counters"] = core.env.get_counters()
		else:
			header["spike_count"] = 3
		var path := tmp_path("v%d_layout.evosave" % version)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(SaveLoad.MAGIC.to_ascii_buffer())
		f.store_32(version)
		var hb := JSON.stringify(header).to_utf8_buffer()
		f.store_32(hb.size())
		f.store_buffer(hb)
		var names: Array = []
		for layer_name: String in core.world.layer_names():
			names.append(layer_name)
		f.store_32(names.size() + (1 if version == 1 else 0))
		for layer_name: String in names:
			SaveLoad._store_block(f, "world." + layer_name, core.world.layer_bytes(layer_name))
		if version == 1:
			SaveLoad._store_block(f, "spike.x", PackedInt32Array([10, 11, 12]).to_byte_array())
		f.close()
		SaveLoad.quiet = true
		var res := SaveLoad.load_file(path)
		SaveLoad.quiet = false
		check_eq(res["error"], "", "version %d layout loads" % version)
		var loaded: RefCounted = res["core"]
		if loaded == null:
			continue
		check_eq(loaded.entities.count, 0, "v%d: no entities" % version)
		check_eq((loaded.world.occupancy as PackedInt32Array).count(0), loaded.world.cell_count, "v%d: occupancy cleared" % version)
		check_eq(loaded.world.flora_type, core.world.flora_type, "v%d: flora restored" % version)
		check_eq(loaded.tick, core.tick, "v%d: tick restored" % version)
		loaded.spawn_founders()
		for t in 3:
			loaded.step()
		check_eq(loaded.entities.check_invariants(), "", "v%d: founders run on the loaded world" % version)


## A version 3 file as that build wrote it: entity and corpse blocks without the search sweep
## (entity.search_leg / entity.search_from, version 4) and a parameter snapshot without the search
## params. It loads with every entity intact and nobody mid-sweep, and the sim runs on.
func test_reads_version_3_layout() -> void:
	var core := _running_core(17, 30)
	var e: RefCounted = core.entities
	var swept := -1
	for i in e.capacity:
		if e.alive[i] == 1:
			swept = i
			break
	e.action[swept] = 4  # WANDER, mid-sweep
	e.search_leg[swept] = 2
	e.search_from[swept] = e.y[swept] * core.world.width + e.x[swept]
	var snap: Dictionary = core.params.snapshot()
	for id: String in ["entity.search_leg_radii", "entity.search_lookback_radii", "entity.search_rest_hunger"]:
		snap.erase(id)
	var header := {"format_version": 3, "seed": core.rngs.master_seed, "tick": core.tick,
			"width": core.world.width, "height": core.world.height, "params": snap, "rng": core.rngs.get_state(),
			"substrates_hash": core.substrates.source_hash, "flora_hash": core.flora.source_hash,
			"env_counters": core.env.get_counters(), "world_hash": core.world_hash(),
			"genes_hash": core.genes.source_hash, "entities": e.header(), "corpses": core.corpses.header()}
	var blocks := {}
	for layer_name: String in core.world.layer_names():
		blocks["world." + layer_name] = core.world.layer_bytes(layer_name)
	blocks.merge(e.export_blocks())
	blocks.merge(core.corpses.export_blocks())
	check(blocks.erase("entity.search_leg") and blocks.erase("entity.search_from"), "version 3 has no sweep blocks")
	var path := tmp_path("v3_layout.evosave")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(SaveLoad.MAGIC.to_ascii_buffer())
	f.store_32(3)
	var hb := JSON.stringify(header).to_utf8_buffer()
	f.store_32(hb.size())
	f.store_buffer(hb)
	f.store_32(blocks.size())
	for block_name: String in blocks:
		SaveLoad._store_block(f, block_name, blocks[block_name])
	f.close()
	var res := SaveLoad.load_file(path)
	check_eq(res["error"], "", "version 3 layout loads")
	var loaded: RefCounted = res["core"]
	if loaded == null:
		return
	var le: RefCounted = loaded.entities
	check_eq(loaded.world_hash(), core.world_hash(), "world identical")
	check_eq(le.count, e.count, "every entity loaded")
	check_eq(le.x, e.x, "positions identical")
	check_eq(le.energy, e.energy, "energy identical")
	check_eq(le.genome, e.genome, "genomes identical")
	check_eq(le.search_leg.size(), le.capacity, "sweep state sized to capacity")
	check_eq(le.search_leg.count(255), le.capacity, "nobody is mid-sweep after a version 3 load")
	check_eq(le.search_from.count(-1), le.capacity, "no sweep origins")
	for t in 5:
		loaded.step()
	check_eq(le.check_invariants(), "", "the sim runs on after the load")


func test_corrupted_layer_detected() -> void:
	SaveLoad.quiet = true
	var core := make_core("test_tiny", {"world.seed": 8})
	var path := tmp_path("corrupt.evosave")
	SaveLoad.save(core, path)
	# Flip one byte near the end of the file (inside the last block payload).
	var bytes := FileAccess.get_file_as_bytes(path)
	bytes[bytes.size() - 3] = bytes[bytes.size() - 3] ^ 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	check(SaveLoad.load_file(path)["core"] == null, "corruption detected")
