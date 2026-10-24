extends "res://tests/test_base.gd"

const Substrates := preload("res://sim/world/substrates.gd")
const Items := preload("res://sim/env/items.gd")
const FloraTable := preload("res://sim/env/flora_table.gd")

var _subs: RefCounted
var _items: RefCounted


func _tables() -> void:
	_subs = Substrates.new()
	check(_subs.load_file(), "substrates load")
	_items = Items.new()
	check(_items.load_file(), "items load")


func test_default_flora_loads() -> void:
	_tables()
	var f := FloraTable.new()
	check(f.load_file(_subs, _items), "flora loads: %s" % "; ".join(f.errors))
	check(f.count() >= 4 and f.count() <= 6, "4-6 flora types (got %d)" % f.count())
	for type_name in ["grass", "shrub", "berry_bush", "tree", "reeds", "fungus"]:
		check(f.id_of(type_name) > 0, "%s defined" % type_name)
	for t in range(1, f.count() + 1):
		check_eq(f.allowed[t * 256 + _subs.id_of("water")], 0, "%s never on water" % f.names[t])
		check_eq(f.allowed[t * 256 + _subs.id_of("rock")], 0, "%s never on rock" % f.names[t])
		check(_items.names[f.harvest_item[t]] != "", "%s has a harvest item" % f.names[t])
	check_eq(f.allowed[f.id_of("grass") * 256 + _subs.id_of("sand")], 1, "grass grows on sand")
	check_eq(f.allowed[f.id_of("reeds") * 256 + _subs.id_of("mud")], 1, "reeds grow on mud")
	check_eq(f.allowed[f.id_of("tree") * 256 + _subs.id_of("sand")], 0, "trees do not grow on sand")


func test_rejects_bad_definitions() -> void:
	_tables()
	var good: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FloraTable.DEFAULT_PATH))
	var cases := {
		"missing_field": func(e: Dictionary) -> void: e.erase("growth_rate"),
		"unknown_substrate": func(e: Dictionary) -> void: e["substrate_mask"] = ["lava"],
		"short_season_array": func(e: Dictionary) -> void: e["seasonal_yield"] = [1.0, 1.0],
		"unknown_item": func(e: Dictionary) -> void: e["harvest_item"] = "gold",
		"biomass_out_of_range": func(e: Dictionary) -> void: e["max_biomass"] = 300,
		"negative_growth": func(e: Dictionary) -> void: e["seasonal_growth"] = [1.0, -1.0, 1.0, 0.0],
	}
	for case_name: String in cases:
		var data: Dictionary = good.duplicate(true)
		(cases[case_name] as Callable).call(data["flora"][0])
		var path := tmp_path("flora_%s.json" % case_name)
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(data))
		file.close()
		var f := FloraTable.new()
		f.quiet = true
		check(not f.load_file(_subs, _items, path), "%s rejected" % case_name)
