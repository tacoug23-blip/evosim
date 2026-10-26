## Corpse table (spec section 4.4): SoA records plus the world's corpse_id layer, which holds
## index + 1 for the corpse lying on a cell (0 = none). At most one corpse per cell: a corpse
## created or dropped on an occupied cell merges into the one already there. A carried corpse
## occupies no cell and does not decay.
##
## Decay: every corpse.update_interval ticks each lying corpse releases a share of its
## remaining soil nutrients (spread evenly over the land cells within corpse.spread_radius,
## raising fertility), and is removed when its decay time runs out.
##
## All methods are sequential-only (the entity system calls them from sequential phases).
extends RefCounted

const Units := preload("res://sim/core/units.gd")
const StateHash := preload("res://sim/core/state_hash.gd")

const NO_CELL := -1
const BYTE_MAX := 255

var world: RefCounted
var capacity := 0
var count := 0
var alive := PackedByteArray()
## Cell the corpse lies on, or NO_CELL while carried.
var cell := PackedInt32Array()
## Milli-mass.
var mass := PackedInt32Array()
## Milli fertility units still to release into the soil.
var nutrients := PackedInt32Array()
## Ticks of lying time left before it has decayed completely.
var decay_left := PackedInt32Array()
## Carrier entity slot + 1, or 0 when lying.
var carried_by := PackedInt32Array()
## Spec field; always 0 until tribes exist (Phase 8).
var owner_tribe := PackedInt32Array()

var created := 0
var decayed := 0
var eaten_milli := 0
var released_fertility := 0
var timing_usec := 0

var edible := false
var _mass_milli := 0
var _nutrients_per_mass := 0.0
var _nutrition_per_mass := 0.0
var _bite_milli := 0
var _decay_ticks := 1
var _spread := 0
var _interval := 1
var _water := 0
var _free := PackedInt32Array()
## Lying corpses per perception block (entity.perception_block cells square), so perception
## only reads corpse_id inside blocks that have one.
var block_count := PackedInt32Array()
var block := 1
var blocks_w := 1


func setup(p_world: RefCounted, subs: RefCounted, params: RefCounted, time: RefCounted) -> void:
	world = p_world
	edible = params.get_bool("corpse.edible")
	_mass_milli = Units.to_milli(params.get_float("corpse.mass"))
	_nutrients_per_mass = params.get_float("corpse.soil_nutrients_per_mass")
	_nutrition_per_mass = params.get_float("corpse.nutrition_per_mass")
	_bite_milli = maxi(1, Units.to_milli(params.get_float("corpse.bite_mass")))
	_decay_ticks = maxi(1, roundi(params.get_float("corpse.decay_days") * time.ticks_per_day))
	_spread = params.get_int("corpse.spread_radius")
	_interval = params.get_int("corpse.update_interval")
	_water = subs.id_of("water")
	block = params.get_int("entity.perception_block")
	blocks_w = ceili(float(world.width) / block)
	block_count.resize(blocks_w * ceili(float(world.height) / block))
	block_count.fill(0)


## Perception block of cell c.
func _block_of(c: int) -> int:
	var w: int = world.width
	@warning_ignore("integer_division")
	return ((c / w) / block) * blocks_w + (c % w) / block


## Rebuild block counts from the corpse table (after loading).
func rebuild_blocks() -> void:
	block_count.fill(0)
	for k in capacity:
		if alive[k] == 1 and cell[k] != NO_CELL:
			block_count[_block_of(cell[k])] += 1


## Leave a fresh corpse on cell c (merging into one already there). Returns its index.
func create(c: int) -> int:
	created += 1
	var existing: int = world.corpse_id[c]
	if existing != 0:
		var k := existing - 1
		mass[k] += _mass_milli
		nutrients[k] += _soil_milli(_mass_milli)
		decay_left[k] = _decay_ticks
		return k
	var k := _alloc()
	cell[k] = c
	mass[k] = _mass_milli
	nutrients[k] = _soil_milli(_mass_milli)
	decay_left[k] = _decay_ticks
	carried_by[k] = 0
	owner_tribe[k] = 0
	world.corpse_id[c] = k + 1
	block_count[_block_of(c)] += 1
	return k


## Corpse index lying on cell c, or -1.
func at(c: int) -> int:
	return world.corpse_id[c] - 1


func pick_up(k: int, carrier_slot: int) -> void:
	world.corpse_id[cell[k]] = 0
	block_count[_block_of(cell[k])] -= 1
	cell[k] = NO_CELL
	carried_by[k] = carrier_slot + 1


## Put a carried corpse down on cell c; merges into a corpse already there. Returns the index
## of the corpse now lying on c.
func drop(k: int, c: int) -> int:
	carried_by[k] = 0
	var existing: int = world.corpse_id[c]
	if existing != 0:
		var into := existing - 1
		mass[into] += mass[k]
		nutrients[into] += nutrients[k]
		decay_left[into] = maxi(decay_left[into], decay_left[k])
		_release_slot(k)
		return into
	cell[k] = c
	world.corpse_id[c] = k + 1
	block_count[_block_of(c)] += 1
	return k


## Eat up to one bite. Returns the energy (milli, before digest) the eaten mass provides.
## Nutrients shrink with the mass; an eaten-up corpse is removed.
func bite(k: int) -> int:
	var m := mass[k]
	var eaten := mini(_bite_milli, m)
	if eaten <= 0:
		return 0
	@warning_ignore("integer_division")
	nutrients[k] -= nutrients[k] * eaten / m
	mass[k] = m - eaten
	eaten_milli += eaten
	if mass[k] <= 0:
		_remove(k)
	return roundi(eaten * _nutrition_per_mass)


## Energy (milli, before digest) one bite of a corpse with this much mass would give.
func bite_energy(mass_milli: int) -> int:
	return roundi(mini(_bite_milli, mass_milli) * _nutrition_per_mass)


func tick(tick_number: int) -> void:
	if tick_number % _interval != 0 or count == 0:
		return
	var t0 := Time.get_ticks_usec()
	for k in capacity:
		if alive[k] == 0 or carried_by[k] != 0:
			continue
		var left := decay_left[k]
		var share := nutrients[k] if left <= _interval else \
				(nutrients[k] * _interval) / left
		_fertilise(k, share)
		decay_left[k] = left - _interval
		if decay_left[k] <= 0:
			decayed += 1
			_remove(k)
	timing_usec += Time.get_ticks_usec() - t0


## Spread up to `amount` milli fertility units over the land cells around corpse k. Whole units
## only; the remainder stays in the corpse for the next update.
func _fertilise(k: int, amount: int) -> void:
	if amount <= 0:
		return
	var c := cell[k]
	var w: int = world.width
	var h: int = world.height
	var cx := c % w
	@warning_ignore("integer_division")
	var cy := c / w
	var sub: PackedByteArray = world.substrate
	var fe: PackedByteArray = world.fertility
	var land := PackedInt32Array()
	for y in range(maxi(0, cy - _spread), mini(h - 1, cy + _spread) + 1):
		for x in range(maxi(0, cx - _spread), mini(w - 1, cx + _spread) + 1):
			var n := y * w + x
			if sub[n] != _water:
				land.append(n)
	if land.is_empty():
		nutrients[k] -= amount  # nowhere to go (all water): lost
		return
	@warning_ignore("integer_division")
	var per_cell := amount / (land.size() * Units.MILLI)
	if per_cell <= 0:
		return
	for n in land:
		var before := fe[n]
		fe[n] = mini(BYTE_MAX, before + per_cell)
		released_fertility += fe[n] - before
	nutrients[k] -= per_cell * land.size() * Units.MILLI


func _remove(k: int) -> void:
	if cell[k] != NO_CELL:
		_fertilise(k, nutrients[k])
		world.corpse_id[cell[k]] = 0
		block_count[_block_of(cell[k])] -= 1
	_release_slot(k)


func _release_slot(k: int) -> void:
	alive[k] = 0
	cell[k] = NO_CELL
	mass[k] = 0
	nutrients[k] = 0
	decay_left[k] = 0
	carried_by[k] = 0
	count -= 1
	_free.append(k)


func _alloc() -> int:
	if _free.is_empty():
		_grow(maxi(16, capacity * 2))
	var k := _free[_free.size() - 1]
	_free.remove_at(_free.size() - 1)
	alive[k] = 1
	count += 1
	return k


func _grow(new_capacity: int) -> void:
	for arr_name: String in ["alive", "cell", "mass", "nutrients", "decay_left", "carried_by", "owner_tribe"]:
		var arr: Variant = get(arr_name)
		arr.resize(new_capacity)
		set(arr_name, arr)
	for k in range(capacity, new_capacity):
		alive[k] = 0
		cell[k] = NO_CELL
		mass[k] = 0
		nutrients[k] = 0
		decay_left[k] = 0
		carried_by[k] = 0
		owner_tribe[k] = 0
	# Free slots are handed out lowest index first.
	for k in range(new_capacity - 1, capacity - 1, -1):
		_free.append(k)
	capacity = new_capacity


func _soil_milli(mass_milli: int) -> int:
	return roundi(mass_milli * _nutrients_per_mass)


func hash_into(h: RefCounted) -> void:
	h.add_int(capacity)
	h.add_int(count)
	h.add_bytes(alive)
	for arr: PackedInt32Array in [cell, mass, nutrients, decay_left, carried_by, owner_tribe, _free]:
		h.add_i32(arr)


## "" if consistent, else the first problem. Every lying corpse is on its cell's corpse_id; no
## other cell has one.
func check_invariants() -> String:
	var lying := 0
	for k in capacity:
		if alive[k] == 0:
			continue
		if carried_by[k] == 0:
			lying += 1
			if cell[k] == NO_CELL or world.corpse_id[cell[k]] != k + 1:
				return "corpse %d not on its cell" % k
		elif cell[k] != NO_CELL:
			return "carried corpse %d still has a cell" % k
	var in_blocks := 0
	for b in block_count:
		if b < 0:
			return "negative corpse block count"
		in_blocks += b
	if in_blocks != lying:
		return "corpse block counts sum to %d for %d lying corpses" % [in_blocks, lying]
	var marked: int = world.cell_count - world.corpse_id.count(0)
	if marked != lying:
		return "%d cells marked with corpses for %d lying corpses" % [marked, lying]
	return ""


## Named raw blocks for the save file.
func export_blocks() -> Dictionary:
	return {
		"corpse.alive": alive, "corpse.cell": cell.to_byte_array(), "corpse.mass": mass.to_byte_array(),
		"corpse.nutrients": nutrients.to_byte_array(), "corpse.decay_left": decay_left.to_byte_array(),
		"corpse.carried_by": carried_by.to_byte_array(), "corpse.owner_tribe": owner_tribe.to_byte_array(),
		"corpse.free": _free.to_byte_array(),
	}


func import_blocks(blocks: Dictionary, header: Dictionary) -> bool:
	capacity = int(header.get("capacity", 0))
	count = int(header.get("count", 0))
	alive = blocks.get("corpse.alive", PackedByteArray())
	for key: String in ["cell", "mass", "nutrients", "decay_left", "carried_by", "owner_tribe"]:
		var bytes: PackedByteArray = blocks.get("corpse." + key, PackedByteArray())
		if bytes.size() != capacity * 4:
			push_error("Corpses: block corpse.%s has %d bytes, expected %d" % [key, bytes.size(), capacity * 4])
			return false
		set(key, bytes.to_int32_array())
	_free = (blocks.get("corpse.free", PackedByteArray()) as PackedByteArray).to_int32_array()
	for key: String in ["created", "decayed", "eaten_milli", "released_fertility"]:
		set(key, int(header.get(key, 0)))
	rebuild_blocks()
	return alive.size() == capacity


func header() -> Dictionary:
	return {"capacity": capacity, "count": count, "created": created, "decayed": decayed,
			"eaten_milli": eaten_milli, "released_fertility": released_fertility}
