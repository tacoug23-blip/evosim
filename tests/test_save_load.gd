extends "res://tests/test_base.gd"

const SaveLoad := preload("res://sim/io/save_load.gd")


func _running_core(seed_value: int, ticks: int) -> RefCounted:
	var core := make_core("test_tiny", {"world.seed": seed_value})
	core.spawn_spike(800)
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


func test_world_only_roundtrip() -> void:
	var core := make_core("test_tiny", {"world.seed": 3})
	var path := tmp_path("world_only.evosave")
	check_eq(SaveLoad.save(core, path), OK, "save succeeds")
	var loaded: RefCounted = SaveLoad.load_file(path)["core"]
	check(loaded != null and loaded.world_hash() == core.world_hash(), "world hash identical")
	check(loaded != null and loaded.spike == null, "no spike when none was saved")


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
	for stream_name in ["terrain", "flora.init", "spike.spawn", "spike.resolve"]:
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


func test_corrupted_layer_detected() -> void:
	SaveLoad.quiet = true
	var core := make_core("test_tiny", {"world.seed": 8})
	var path := tmp_path("corrupt.evosave")
	SaveLoad.save(core, path)
	# Flip one byte near the end of the file (inside the last world/spike block payload).
	var bytes := FileAccess.get_file_as_bytes(path)
	bytes[bytes.size() - 3] = bytes[bytes.size() - 3] ^ 0xFF
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	check(SaveLoad.load_file(path)["core"] == null, "corruption detected")
