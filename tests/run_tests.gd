## Headless test runner. Runs every test_* method in every tests/test_*.gd file, each on a
## fresh instance, and exits non-zero if any check failed.
##
##   godot --headless --path . --script res://tests/run_tests.gd [-- --filter=<substring>]
extends SceneTree

const TEST_DIR := "res://tests/"


func _initialize() -> void:
	var filter := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			filter = arg.trim_prefix("--filter=")
	var files := PackedStringArray()
	for f in DirAccess.get_files_at(TEST_DIR):
		if f.begins_with("test_") and f.ends_with(".gd"):
			files.append(f)
	files.sort()

	var run := 0
	var failed := 0
	var t_all := Time.get_ticks_msec()
	for f in files:
		var script: GDScript = load(TEST_DIR + f)
		if script == null or not script.can_instantiate():
			# A parse error must fail the run, not silently skip the file's tests.
			run += 1
			failed += 1
			print("FAIL  %s  (script failed to load or compile)" % f.get_basename())
			continue
		var methods := PackedStringArray()
		for m: Dictionary in script.get_script_method_list():
			var method_name: String = m["name"]
			if method_name.begins_with("test_") and not method_name in methods:
				methods.append(method_name)
		for method_name in methods:
			var label := "%s::%s" % [f.get_basename(), method_name]
			if not filter.is_empty() and not filter in label:
				continue
			var inst: RefCounted = script.new()
			inst.current = label
			var t0 := Time.get_ticks_msec()
			inst.call(method_name)
			var ms := Time.get_ticks_msec() - t0
			run += 1
			if inst.failures.is_empty():
				print("PASS  %s  (%d ms)" % [label, ms])
			else:
				failed += 1
				print("FAIL  %s  (%d ms)" % [label, ms])
				for msg in inst.failures:
					print("        " + msg)
	print("\n%d run, %d failed, %.1f s" % [run, failed, (Time.get_ticks_msec() - t_all) / 1000.0])
	quit(1 if failed > 0 or run == 0 else 0)
