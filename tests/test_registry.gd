extends "res://tests/test_base.gd"


func test_defaults_load_and_are_complete() -> void:
	var p := Registry.new()
	check(p.load_file(), "default parameters load: %s" % "; ".join(p.errors))
	check(p.ids().size() > 20, "registry has parameters")
	for id in p.ids():
		var d: Dictionary = p.definition(id)
		check(not d["group"].is_empty(), "%s has a group" % id)
		check(not d["desc"].is_empty(), "%s has a description" % id)
		check(d.has("tuned"), "%s has a tuned flag" % id)
	check_eq(p.untuned_ids().size(), p.ids().size(), "every Phase 1 value is a placeholder")
	check_eq(p.get_int("world.width"), 4096, "default width")
	check(p.groups().has("world.terrain"), "groups listed")
	check(p.ids_in_group("spike").has("spike.perception_radius"), "group membership")


func test_typed_access() -> void:
	var p := make_params("")
	check_eq(typeof(p.get_value("world.width")), TYPE_INT, "int param holds an int")
	check_eq(typeof(p.get_value("sim.base_tps")), TYPE_FLOAT, "float param holds a float")
	p.quiet = true
	check_eq(p.get_float("world.width"), 0.0, "reading an int as float is refused")
	check(not p.errors.is_empty(), "type mismatch reported")
	check_eq(p.get_int("no.such.param"), 0, "unknown id reads as zero")


func test_set_value_validates_and_clamps() -> void:
	var p := make_params("")
	p.quiet = true
	check(p.set_value("sim.base_tps", 20), "int accepted for float param")
	check_eq(p.get_float("sim.base_tps"), 20.0, "value stored")
	check(p.set_value("sim.base_tps", 99999.0), "out-of-range value accepted with clamp")
	check_eq(p.get_float("sim.base_tps"), 1000.0, "clamped to max")
	check(not p.errors.is_empty(), "clamp reported")
	check(not p.set_value("sim.base_tps", "fast"), "string refused for float")
	check(not p.set_value("world.width", 100.5), "fraction refused for int")
	check(not p.set_value("no.such.param", 1), "unknown id refused")
	var seen := []
	p.value_changed.connect(func(id: String, v: Variant) -> void: seen.append([id, v]))
	p.set_value("spike.perception_radius", 4)
	check_eq(seen, [["spike.perception_radius", 4]], "value_changed emitted")


func test_structural_lock() -> void:
	var p := make_params("")
	p.quiet = true
	p.lock_structural()
	check(not p.set_value("world.width", 512), "structural param refused while locked")
	check_eq(p.get_int("world.width"), 4096, "locked value unchanged")
	check(p.set_value("sim.base_tps", 5.0), "non-structural param still changes")
	var snap: Dictionary = p.snapshot()
	snap["world.width"] = 512
	check(p.restore_snapshot(snap), "restore ignores the lock")
	check_eq(p.get_int("world.width"), 512, "restored structural value")


func test_presets() -> void:
	var p := make_params("")
	p.quiet = true
	check(p.list_presets().has("test_tiny"), "test_tiny listed")
	check(p.list_presets().has("small_world"), "small_world listed")
	check(p.apply_preset("small_world"), "preset applies")
	check_eq(p.get_int("world.width"), 1024, "preset value")
	check_eq(p.get_int("spike.perception_radius"), 8, "untouched value keeps default")
	check(not p.apply_preset("no_such_preset"), "unknown preset refused")


func test_snapshot_survives_json() -> void:
	var p := make_params("test_tiny", {"sim.base_tps": 12.345678901234, "world.seed": 2147483000})
	var text := JSON.stringify(p.snapshot(), "", true, true)
	var q := make_params("")
	check(q.restore_snapshot(JSON.parse_string(text)), "snapshot restores")
	for id in p.ids():
		check_eq(q.get_value(id), p.get_value(id), "value of %s survives JSON" % id)
		check_eq(typeof(q.get_value(id)), typeof(p.get_value(id)), "type of %s survives JSON" % id)


func test_rejects_invalid_definitions() -> void:
	var cases := {
		"duplicate": [_param("a.x", "int", 1, 0, 2), _param("a.x", "int", 1, 0, 2)],
		"out_of_range": [_param("a.x", "int", 5, 0, 2)],
		"bad_type": [_param("a.x", "string", 1, 0, 2)],
		"int_fraction": [_param("a.x", "int", 1.5, 0, 2)],
		"missing_field": [{"id": "a.x", "type": "int", "default": 1, "min": 0, "max": 2}],
	}
	for case_name: String in cases:
		var path := tmp_path("bad_%s.json" % case_name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"params": cases[case_name]}))
		f.close()
		var p := Registry.new()
		p.quiet = true
		check(not p.load_file(path), "%s definition rejected" % case_name)
		check(not p.errors.is_empty(), "%s reported" % case_name)


func _param(id: String, type: String, def: Variant, lo: Variant, hi: Variant) -> Dictionary:
	return {"id": id, "group": "g", "type": type, "default": def, "min": lo, "max": hi,
			"desc": "d", "tuned": false}
