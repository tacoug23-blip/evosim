## Gene table from config/genes.json. A genome is one float per gene, in table order; the
## entity system stores genomes entity-major in one flat array ([slot * count() + gene]).
extends RefCounted

const DEFAULT_PATH := "res://config/genes.json"
const REQUIRED_FIELDS := ["name", "group", "min", "max", "default", "desc", "cost"]

var names := PackedStringArray()
var groups := PackedStringArray()
var minimum := PackedFloat64Array()
var maximum := PackedFloat64Array()
var default_value := PackedFloat64Array()
var descriptions := PackedStringArray()
var costs := PackedStringArray()
var errors := PackedStringArray()
## Tests set this to keep expected failures out of the log.
var quiet := false
## SHA-256 of the config file, stored in save files to detect a changed table on load.
var source_hash := ""

var _by_name := {}


func load_file(path: String = DEFAULT_PATH) -> bool:
	errors.clear()
	if not FileAccess.file_exists(path):
		return _fail("gene file not found: %s" % path)
	var text := FileAccess.get_file_as_string(path)
	source_hash = text.sha256_text()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("genes")) != TYPE_ARRAY:
		return _fail("%s: expected an object with a 'genes' array" % path)
	for e: Variant in data["genes"]:
		if typeof(e) != TYPE_DICTIONARY:
			return _fail("gene entry is not an object")
		for field: String in REQUIRED_FIELDS:
			if not e.has(field):
				return _fail("gene %s is missing '%s'" % [e.get("name", "?"), field])
		var n: String = e["name"]
		if _by_name.has(n):
			return _fail("duplicate gene: %s" % n)
		var lo := float(e["min"])
		var hi := float(e["max"])
		var dv := float(e["default"])
		if not (lo <= dv and dv <= hi):
			return _fail("gene %s: default %s outside [%s, %s]" % [n, dv, lo, hi])
		_by_name[n] = names.size()
		names.append(n)
		groups.append(str(e["group"]))
		minimum.append(lo)
		maximum.append(hi)
		default_value.append(dv)
		descriptions.append(str(e["desc"]))
		costs.append(str(e["cost"]))
	if names.is_empty():
		return _fail("no genes defined")
	return true


func count() -> int:
	return names.size()


## Gene index, or -1.
func index_of(gene_name: String) -> int:
	return _by_name.get(gene_name, -1)


## A genome of all defaults.
func defaults() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	for v in default_value:
		g.append(v)
	return g


func clamp_gene(i: int, v: float) -> float:
	return clampf(v, minimum[i], maximum[i])


func _fail(message: String) -> bool:
	errors.append(message)
	if not quiet:
		push_error("GeneTable: " + message)
	return false
