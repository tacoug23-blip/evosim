## Assertion helpers and fixtures shared by the test files. Test files extend this and define
## test_* methods; tests/run_tests.gd calls each one on a fresh instance.
extends RefCounted

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")

const TMP_DIR := "user://test_tmp/"

var current := ""
var failures := PackedStringArray()


func check(cond: bool, message: String) -> bool:
	if not cond:
		failures.append(message)
	return cond


func check_eq(actual: Variant, expected: Variant, message: String) -> bool:
	return check(actual == expected, "%s (got %s, expected %s)" % [message, str(actual), str(expected)])


## Registry with defaults, then a preset, then explicit overrides.
func make_params(preset: String = "test_tiny", overrides: Dictionary = {}) -> RefCounted:
	var params := Registry.new()
	check(params.load_file(), "registry loads: %s" % "; ".join(params.errors))
	if not preset.is_empty():
		check(params.apply_preset(preset), "preset %s applies" % preset)
	if not overrides.is_empty():
		check(params.apply_overrides(overrides), "overrides apply: %s" % "; ".join(params.errors))
	return params


func make_core(preset: String = "test_tiny", overrides: Dictionary = {}) -> RefCounted:
	var core := SimCore.new()
	check(core.init_new(make_params(preset, overrides)), "core builds: %s" % core.error)
	return core


func tmp_path(file_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	return TMP_DIR + file_name
