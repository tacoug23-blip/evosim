## Flora types from config/flora.json, flattened into arrays indexed by flora type id (the u8
## in the flora_type layer). Index 0 is "no plant" and holds zeros. Seasonal arrays are
## flattened as [id * 4 + season].
extends RefCounted

const DEFAULT_PATH := "res://config/flora.json"
const SEASONS := 4
const SUBSTRATE_SLOTS := 256
## Flora type ids index a u8 layer, and allows_flora bitmasks hold one bit per type.
const MAX_TYPES := 31
const REQUIRED_FIELDS := ["id", "name", "color", "substrate_mask", "growth_rate", "max_biomass",
		"maturity", "seed_spread_radius", "seed_chance", "mortality", "seasonal_growth",
		"seasonal_yield", "day_growth", "night_growth", "moisture_need", "fertility_consumption",
		"harvest_item", "nutrition", "initial_cover"]

var names := PackedStringArray([""])
var colors := PackedColorArray([Color.TRANSPARENT])
var growth_rate := PackedFloat64Array([0.0])
var max_biomass := PackedInt32Array([0])
var maturity := PackedFloat64Array([0.0])
var seed_spread_radius := PackedInt32Array([0])
var seed_chance := PackedFloat64Array([0.0])
var mortality := PackedFloat64Array([0.0])
var seasonal_growth := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var seasonal_yield := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var day_growth := PackedFloat64Array([0.0])
var night_growth := PackedFloat64Array([0.0])
var moisture_need := PackedFloat64Array([0.0])
var fertility_consumption := PackedFloat64Array([0.0])
var harvest_item := PackedInt32Array([0])
var nutrition := PackedInt32Array([0])
var initial_cover := PackedFloat64Array([0.0])
## 1 if type t may grow on substrate s: [t * 256 + s]. Both the flora's substrate_mask and the
## substrate's allows_flora bit (t - 1) must allow it.
var allowed := PackedByteArray()
var errors := PackedStringArray()
## Tests set this to keep expected failures out of the log.
var quiet := false
## SHA-256 of the config file, stored in save files to detect a changed table on load.
var source_hash := ""


## Highest type id (types are 1..count()).
func count() -> int:
	return names.size() - 1


func load_file(subs: RefCounted, items: RefCounted, path: String = DEFAULT_PATH) -> bool:
	errors.clear()
	if not FileAccess.file_exists(path):
		return _fail("flora file not found: %s" % path)
	var text := FileAccess.get_file_as_string(path)
	source_hash = text.sha256_text()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("flora")) != TYPE_ARRAY:
		return _fail("%s: expected an object with a 'flora' array" % path)
	var entries: Array = data["flora"]
	if entries.is_empty() or entries.size() > MAX_TYPES:
		return _fail("flora type count must be 1..%d" % MAX_TYPES)
	allowed.resize((entries.size() + 1) * SUBSTRATE_SLOTS)
	allowed.fill(0)
	for i in entries.size():
		if not _add(entries[i], i + 1, subs, items):
			return false
	return true


func _add(e: Dictionary, id: int, subs: RefCounted, items: RefCounted) -> bool:
	for field: String in REQUIRED_FIELDS:
		if not e.has(field):
			return _fail("flora %d is missing '%s'" % [id, field])
	var n: String = e["name"]
	if int(e["id"]) != id:
		return _fail("flora ids must be contiguous from 1; %s has id %s" % [n, e["id"]])
	if names.has(n):
		return _fail("duplicate flora name: %s" % n)
	var mb := int(e["max_biomass"])
	if mb < 1 or mb > 255:
		return _fail("%s: max_biomass must be 1..255" % n)
	if int(e["seed_spread_radius"]) < 1:
		return _fail("%s: seed_spread_radius must be >= 1" % n)
	for key: String in ["maturity", "seed_chance", "mortality", "moisture_need", "initial_cover"]:
		if float(e[key]) < 0.0 or float(e[key]) > 1.0:
			return _fail("%s: %s must be 0..1" % [n, key])
	for key: String in ["growth_rate", "day_growth", "night_growth", "fertility_consumption"]:
		if float(e[key]) < 0.0:
			return _fail("%s: %s must be >= 0" % [n, key])
	for key: String in ["seasonal_growth", "seasonal_yield"]:
		if typeof(e[key]) != TYPE_ARRAY or (e[key] as Array).size() != SEASONS:
			return _fail("%s: %s needs %d values" % [n, key, SEASONS])
		for v: Variant in e[key]:
			if float(v) < 0.0:
				return _fail("%s: %s values must be >= 0" % [n, key])
	var item: int = items.id_of(e["harvest_item"])
	if item < 0:
		return _fail("%s: unknown harvest_item %s" % [n, e["harvest_item"]])
	for sub_name: Variant in e["substrate_mask"]:
		var s: int = subs.id_of(str(sub_name))
		if s < 0:
			return _fail("%s: unknown substrate %s" % [n, sub_name])
		if subs.allows_flora[s] & (1 << (id - 1)):
			allowed[id * SUBSTRATE_SLOTS + s] = 1

	names.append(n)
	colors.append(Color.html(e["color"]))
	growth_rate.append(e["growth_rate"])
	max_biomass.append(mb)
	maturity.append(e["maturity"])
	seed_spread_radius.append(int(e["seed_spread_radius"]))
	seed_chance.append(e["seed_chance"])
	mortality.append(e["mortality"])
	for s in SEASONS:
		seasonal_growth.append(e["seasonal_growth"][s])
		seasonal_yield.append(e["seasonal_yield"][s])
	day_growth.append(e["day_growth"])
	night_growth.append(e["night_growth"])
	moisture_need.append(e["moisture_need"])
	fertility_consumption.append(e["fertility_consumption"])
	harvest_item.append(item)
	nutrition.append(int(e["nutrition"]))
	initial_cover.append(e["initial_cover"])
	return true


func id_of(type_name: String) -> int:
	var i := names.find(type_name)
	return i if i > 0 else -1


func _fail(message: String) -> bool:
	errors.append(message)
	if not quiet:
		push_error("FloraTable: " + message)
	return false
