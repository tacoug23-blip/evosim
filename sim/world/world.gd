## The layered grid (spec section 3): one packed array per layer, one element per cell,
## row-major (index = y * width + x). No per-cell objects.
extends RefCounted

const StateHash := preload("res://sim/core/state_hash.gd")

## [name, bytes per cell]. This order is the save and hash order: append new layers at the
## end and bump the save format version.
## Godot has no packed u16/u32 arrays: u16 layers are PackedByteArray with 2 bytes per cell
## (little-endian, via encode_u16/decode_u16); u32 layers are PackedInt32Array (ids < 2^31).
const LAYERS := [
	["substrate", 1],
	["fertility", 1],
	["moisture", 1],
	["flora_type", 1],
	["flora_biomass", 1],
	["structure_type", 1],
	["structure_material", 1],
	["structure_hp", 2],
	["item_type", 1],
	["item_qty", 1],
	["corpse_id", 4],
	["occupancy", 4],
]

var width: int
var height: int
var cell_count: int

var substrate := PackedByteArray()
var fertility := PackedByteArray()
var moisture := PackedByteArray()
var flora_type := PackedByteArray()
var flora_biomass := PackedByteArray()
var structure_type := PackedByteArray()
var structure_material := PackedByteArray()
var structure_hp := PackedByteArray()
var item_type := PackedByteArray()
var item_qty := PackedByteArray()
var corpse_id := PackedInt32Array()
## Entity id occupying the cell, 0 = empty. Strictly one entity per cell.
var occupancy := PackedInt32Array()


func _init(p_width: int, p_height: int) -> void:
	width = p_width
	height = p_height
	cell_count = width * height
	for layer: Array in LAYERS:
		var arr: Variant = get(layer[0])
		var elements: int = cell_count * layer[1] if layer[1] < 4 else cell_count
		arr.resize(elements)
		arr.fill(0)  # resize does not guarantee zeroed memory; determinism needs it.
		set(layer[0], arr)


func index(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height


func get_structure_hp(cell: int) -> int:
	return structure_hp.decode_u16(cell * 2)


func set_structure_hp(cell: int, hp: int) -> void:
	structure_hp.encode_u16(cell * 2, hp)


static func layer_names() -> PackedStringArray:
	var out := PackedStringArray()
	for layer: Array in LAYERS:
		out.append(layer[0])
	return out


static func layer_cell_bytes(layer_name: String) -> int:
	for layer: Array in LAYERS:
		if layer[0] == layer_name:
			return layer[1]
	return 0


## Raw little-endian bytes of a layer (a copy for 4-byte layers).
func layer_bytes(layer_name: String) -> PackedByteArray:
	var arr: Variant = get(layer_name)
	if arr is PackedInt32Array:
		return arr.to_byte_array()
	return arr


func set_layer_bytes(layer_name: String, bytes: PackedByteArray) -> bool:
	var per_cell := layer_cell_bytes(layer_name)
	if per_cell == 0 or bytes.size() != cell_count * per_cell:
		push_error("World: bad data for layer %s (%d bytes)" % [layer_name, bytes.size()])
		return false
	set(layer_name, bytes.to_int32_array() if per_cell == 4 else bytes)
	return true


func hash_state() -> String:
	var h := StateHash.new()
	h.add_int(width)
	h.add_int(height)
	for layer: Array in LAYERS:
		h.add_string(layer[0])
		h.add_bytes(layer_bytes(layer[0]))
	return h.finish_hex()
