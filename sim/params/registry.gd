## Parameter registry: the single source of truth for every tunable number (spec section 12).
##
## Definitions come from config/parameters.json. Presets in config/presets/ are partial
## override sets. Sim code reads values once at setup through the typed getters, so nothing
## under sim/ hardcodes a tunable. Structural params (map size, seed, terrain shape) are
## locked once a world exists; everything else can be overridden at runtime.
extends RefCounted

signal value_changed(id: String, value: Variant)

const DEFAULT_PATH := "res://config/parameters.json"
const PRESET_DIR := "res://config/presets/"
const TYPES := ["int", "float", "bool"]
const REQUIRED_FIELDS := ["id", "group", "type", "default", "min", "max", "desc", "tuned"]

## Messages from the most recent failing call. Also sent to push_error unless quiet.
var errors := PackedStringArray()
var quiet := false

var _defs := {}
var _values := {}
var _ids := PackedStringArray()
var _structural_locked := false


func load_file(path: String = DEFAULT_PATH) -> bool:
	errors.clear()
	_defs.clear()
	_values.clear()
	_ids.clear()
	_structural_locked = false
	if not FileAccess.file_exists(path):
		return _fail("parameter file not found: %s" % path)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("params")) != TYPE_ARRAY:
		return _fail("%s: expected an object with a 'params' array" % path)
	for raw: Variant in data["params"]:
		_add_definition(raw)
	return errors.is_empty()


func has(id: String) -> bool:
	return _defs.has(id)


func ids() -> PackedStringArray:
	return _ids.duplicate()


func definition(id: String) -> Dictionary:
	return (_defs[id] as Dictionary).duplicate() if _defs.has(id) else {}


func groups() -> PackedStringArray:
	var seen := {}
	for id in _ids:
		seen[_defs[id]["group"]] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


func ids_in_group(group: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id in _ids:
		if _defs[id]["group"] == group:
			out.append(id)
	return out


func untuned_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _ids:
		if not _defs[id]["tuned"]:
			out.append(id)
	return out


func is_structural(id: String) -> bool:
	return _defs.has(id) and _defs[id]["structural"]


func get_value(id: String) -> Variant:
	if not _defs.has(id):
		_fail("unknown parameter: %s" % id)
		return null
	return _values[id]


func get_int(id: String) -> int:
	return _typed(id, "int")


func get_float(id: String) -> float:
	return _typed(id, "float")


func get_bool(id: String) -> bool:
	return _typed(id, "bool")


## Runtime override. Values outside [min, max] are clamped (and reported in `errors`).
## Structural params are refused while locked.
func set_value(id: String, value: Variant) -> bool:
	errors.clear()
	return _assign(id, value, false)


## Apply {id: value} overrides. Stops at nothing: every valid entry is applied, every invalid
## one is reported. Returns false if any entry was rejected.
func apply_overrides(overrides: Dictionary) -> bool:
	errors.clear()
	var ok := true
	for id: String in overrides:
		ok = _assign(id, overrides[id], false) and ok
	return ok


func list_presets() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(PRESET_DIR):
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out


func apply_preset(preset_name: String) -> bool:
	var path := PRESET_DIR + preset_name + ".json"
	if not FileAccess.file_exists(path):
		errors.clear()
		return _fail("unknown preset: %s" % preset_name)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("overrides")) != TYPE_DICTIONARY:
		errors.clear()
		return _fail("%s: expected an object with an 'overrides' object" % path)
	return apply_overrides(data["overrides"])


func reset_to_defaults() -> void:
	for id in _ids:
		_values[id] = _defs[id]["default"]


## Current values, id -> value. Saved with every save file and batch run.
func snapshot() -> Dictionary:
	return _values.duplicate()


## Restore a snapshot from a save file: defaults first, then every known id in the snapshot.
## Ignores the structural lock (the world is being rebuilt from the save).
func restore_snapshot(snap: Dictionary) -> bool:
	errors.clear()
	reset_to_defaults()
	var ok := true
	for id: String in snap:
		if not _defs.has(id):
			errors.append("snapshot has unknown parameter %s (ignored)" % id)
			continue
		ok = _assign(id, snap[id], true) and ok
	return ok


func lock_structural() -> void:
	_structural_locked = true


func unlock_structural() -> void:
	_structural_locked = false


func _typed(id: String, type: String) -> Variant:
	if not _defs.has(id):
		_fail("unknown parameter: %s" % id)
		return _zero(type)
	if _defs[id]["type"] != type:
		_fail("parameter %s is %s, read as %s" % [id, _defs[id]["type"], type])
		return _zero(type)
	return _values[id]


func _assign(id: String, value: Variant, ignore_lock: bool) -> bool:
	if not _defs.has(id):
		return _fail("unknown parameter: %s" % id)
	var def: Dictionary = _defs[id]
	if def["structural"] and _structural_locked and not ignore_lock:
		return _fail("parameter %s is structural and locked; rebuild the world to change it" % id)
	var v: Variant = _coerce(def["type"], value)
	if v == null:
		return _fail("parameter %s expects %s, got %s" % [id, def["type"], var_to_str(value)])
	if def["type"] != "bool":
		var clamped: Variant = clamp(v, def["min"], def["max"])
		if clamped != v:
			errors.append("parameter %s=%s clamped to %s" % [id, str(v), str(clamped)])
			v = clamped
	_values[id] = v
	value_changed.emit(id, v)
	return true


func _add_definition(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("parameter entry is not an object: %s" % var_to_str(raw))
		return
	for field: String in REQUIRED_FIELDS:
		if not raw.has(field):
			_fail("parameter %s is missing '%s'" % [raw.get("id", "?"), field])
			return
	var id: String = raw["id"]
	if _defs.has(id):
		_fail("duplicate parameter id: %s" % id)
		return
	var type: String = raw["type"]
	if not type in TYPES:
		_fail("parameter %s has unknown type %s" % [id, type])
		return
	var def := {
		"id": id,
		"group": str(raw["group"]),
		"type": type,
		"default": _coerce(type, raw["default"]),
		"min": _coerce(type, raw["min"]),
		"max": _coerce(type, raw["max"]),
		"desc": str(raw["desc"]),
		"tuned": bool(raw["tuned"]),
		"structural": bool(raw.get("structural", false)),
	}
	if def["default"] == null or def["min"] == null or def["max"] == null:
		_fail("parameter %s: default/min/max must all be %s" % [id, type])
		return
	if type != "bool" and not (def["min"] <= def["default"] and def["default"] <= def["max"]):
		_fail("parameter %s: default %s outside [%s, %s]" % [id, def["default"], def["min"], def["max"]])
		return
	_defs[id] = def
	_values[id] = def["default"]
	_ids.append(id)


static func _coerce(type: String, value: Variant) -> Variant:
	var t := typeof(value)
	match type:
		"int":
			if t == TYPE_INT:
				return value
			if t == TYPE_FLOAT and is_equal_approx(value, roundf(value)):
				return int(value)
		"float":
			if t == TYPE_INT or t == TYPE_FLOAT:
				return float(value)
		"bool":
			if t == TYPE_BOOL:
				return value
	return null


static func _zero(type: String) -> Variant:
	match type:
		"int":
			return 0
		"float":
			return 0.0
	return false


func _fail(message: String) -> bool:
	errors.append(message)
	if not quiet:
		push_error("ParamRegistry: " + message)
	return false
