## Packed-array write-through rules the sim relies on (Godot 4.6), and a scan for the one pattern
## that silently loses writes: a mutating call on an `as Packed*Array` cast, which acts on a
## temporary copy. That was the version-1 load bug (occupancy never cleared); see
## test_save_load.test_reads_pre_v3_layouts for the bug itself.
extends "res://tests/test_base.gd"

const MUTATORS := ["fill", "set", "append", "append_array", "push_back", "resize", "sort", "reverse",
		"remove_at", "insert", "clear", "erase"]


class Holder:
	var arr := PackedInt32Array([1, 2, 3])
	var dict := {"k": PackedInt32Array([1, 2, 3])}
	var lists: Array[PackedInt32Array] = [PackedInt32Array([1, 2, 3])]


func test_write_through_rules() -> void:
	var h := Holder.new()
	var r: RefCounted = h
	(r.arr as PackedInt32Array).fill(0)
	check_eq(h.arr, PackedInt32Array([1, 2, 3]), "a mutating call on an `as` cast is lost (temporary copy)")
	var t: PackedInt32Array = r.arr
	t.fill(0)
	check_eq(h.arr, PackedInt32Array([0, 0, 0]), "a typed local writes through")
	h.arr = PackedInt32Array([1, 2, 3])
	r.arr[1] = 7
	check_eq(h.arr, PackedInt32Array([1, 7, 3]), "an index write through a property writes through")
	h.dict["k"].append(4)
	check_eq(h.dict["k"], PackedInt32Array([1, 2, 3, 4]), "a call on a Dictionary element writes through")
	var lst := h.lists[0]
	lst.resize(0)
	check_eq(h.lists[0].size(), 0, "a local from a typed Array element writes through")


func test_no_mutating_call_on_a_cast() -> void:
	var re := RegEx.new()
	re.compile("as\\s+Packed\\w*Array\\s*\\)\\s*\\.\\s*(%s)\\s*\\(" % "|".join(MUTATORS))
	var hits := PackedStringArray()
	var scanned := 0
	for dir_path: String in ["res://sim", "res://ui", "res://tools", "res://tests"]:
		for path: String in _scripts(dir_path):
			if path == get_script().resource_path:
				continue  # this file demonstrates the trap on purpose
			scanned += 1
			var lines := FileAccess.get_file_as_string(path).split("\n")
			for n in lines.size():
				var code := lines[n].get_slice("#", 0)
				if re.search(code) != null:
					hits.append("%s:%d" % [path, n + 1])
	check(scanned > 30, "scanned %d scripts" % scanned)
	check_eq(hits, PackedStringArray(), "no mutating call on an `as Packed*Array` cast (use a typed local)")


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path + "/" + f)
	for sub in d.get_directories():
		out.append_array(_scripts(dir_path + "/" + sub))
	return out
