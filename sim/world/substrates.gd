## Substrate table loaded from config/substrates.json, flattened into per-property arrays
## indexed by substrate id (the u8 stored in the substrate layer).
extends RefCounted

const Units := preload("res://sim/core/units.gd")

const DEFAULT_PATH := "res://config/substrates.json"
const MAX_SUBSTRATES := 256
const REQUIRED_FIELDS := ["id", "name", "color", "move_cost", "fertility_base", "allows_flora",
		"allows_building", "allows_water_crossing"]

var names := PackedStringArray()
var colors := PackedColorArray()
var move_cost_milli := PackedInt32Array()
var fertility_base := PackedFloat32Array()
var allows_flora := PackedInt32Array()
var allows_building := PackedByteArray()
## 1 if entities may enter the cell (allows_water_crossing in the config).
var passable := PackedByteArray()
var errors := PackedStringArray()
## SHA-256 of the config file, stored in save files to detect a changed table on load.
var source_hash := ""

var _by_name := {}


func load_file(path: String = DEFAULT_PATH) -> bool:
	errors.clear()
	if not FileAccess.file_exists(path):
		return _fail("substrate file not found: %s" % path)
	var text := FileAccess.get_file_as_string(path)
	source_hash = text.sha256_text()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("substrates")) != TYPE_ARRAY:
		return _fail("%s: expected an object with a 'substrates' array" % path)
	var entries: Array = data["substrates"]
	if entries.is_empty() or entries.size() > MAX_SUBSTRATES:
		return _fail("substrate count must be 1..%d" % MAX_SUBSTRATES)
	for i in entries.size():
		var e: Dictionary = entries[i]
		for field: String in REQUIRED_FIELDS:
			if not e.has(field):
				return _fail("substrate %d is missing '%s'" % [i, field])
		if int(e["id"]) != i:
			return _fail("substrate ids must be contiguous from 0; entry %d has id %s" % [i, e["id"]])
		var n: String = e["name"]
		if _by_name.has(n):
			return _fail("duplicate substrate name: %s" % n)
		_by_name[n] = i
		names.append(n)
		colors.append(Color.html(e["color"]))
		move_cost_milli.append(Units.to_milli(e["move_cost"]))
		fertility_base.append(e["fertility_base"])
		allows_flora.append(int(e["allows_flora"]))
		allows_building.append(1 if e["allows_building"] else 0)
		passable.append(1 if e["allows_water_crossing"] else 0)
		if move_cost_milli[i] <= 0:
			return _fail("substrate %s: move_cost must be > 0" % n)
	return true


func count() -> int:
	return names.size()


func id_of(substrate_name: String) -> int:
	return _by_name.get(substrate_name, -1)


func _fail(message: String) -> bool:
	errors.append(message)
	push_error("Substrates: " + message)
	return false
