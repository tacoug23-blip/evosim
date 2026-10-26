## Item table from config/items.json. Index = item id (the u8 in the item_type layer);
## every item is edible, and its food value is `nutrition` (the only place nutrition lives);
## index 0 is "none".
extends RefCounted

const DEFAULT_PATH := "res://config/items.json"
const MAX_ITEMS := 256

var names := PackedStringArray([""])
## Energy per item eaten, before the eater's digest_efficiency. Index 0 ("none") is 0.
var nutrition := PackedFloat64Array([0.0])
var errors := PackedStringArray()

var _by_name := {}


func load_file(path: String = DEFAULT_PATH) -> bool:
	errors.clear()
	if not FileAccess.file_exists(path):
		return _fail("item file not found: %s" % path)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("items")) != TYPE_ARRAY:
		return _fail("%s: expected an object with an 'items' array" % path)
	var entries: Array = data["items"]
	if entries.size() >= MAX_ITEMS:
		return _fail("too many items (max %d)" % (MAX_ITEMS - 1))
	for i in entries.size():
		var e: Dictionary = entries[i]
		if not e.has("id") or not e.has("name") or not e.has("nutrition"):
			return _fail("item %d needs id, name and nutrition" % i)
		if int(e["id"]) != i + 1:
			return _fail("item ids must be contiguous from 1; entry %d has id %s" % [i, e["id"]])
		var n: String = e["name"]
		if _by_name.has(n):
			return _fail("duplicate item name: %s" % n)
		_by_name[n] = i + 1
		if float(e["nutrition"]) <= 0.0:
			return _fail("%s: nutrition must be > 0 (every item is edible)" % n)
		names.append(n)
		nutrition.append(float(e["nutrition"]))
	return true


func count() -> int:
	return names.size()


func id_of(item_name: String) -> int:
	return _by_name.get(item_name, -1)


func _fail(message: String) -> bool:
	errors.append(message)
	push_error("Items: " + message)
	return false
