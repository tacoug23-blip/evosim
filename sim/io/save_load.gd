## Binary save format (spec section 14).
##
##   "EVOS"                    4 bytes magic
##   format version            u32
##   header length, header     u32 + UTF-8 JSON: seed, tick, size, parameter snapshot,
##                             RNG stream states, config hashes, world hash
##   block count               u32
##   blocks                    name (u16 len + UTF-8), encoding u8, raw size u64,
##                             stored size u64, data
##
## Blocks are the world layers (World.LAYERS order) plus optional subsystem blocks (the
## spike's arrays). Each block is zstd-compressed when that is smaller. All integers are
## little-endian. Bump FORMAT_VERSION whenever block meaning, block layout, or required header
## content changes, and keep reading older versions where possible.
##
## Version history:
##   1  Phase 1: world layers, optional spike blocks.
##   2  Phase 2: flora, fertility, and moisture layers are live sim state; the header adds
##      env_counters (flora totals), flora_hash, and a readable time. Version 1 files still
##      load: their flora totals are recounted.
##
## Not saved, because they are pure functions of the seed and tick: in-game time, the climate
## grid, weather, and the stateless env.sample / env.weather hash seeds. Every stateful RNG
## stream (terrain, flora.init, spike.*) is saved in the header's "rng" map.
extends RefCounted

const Registry := preload("res://sim/params/registry.gd")
const Rng := preload("res://sim/core/rng.gd")
const World := preload("res://sim/world/world.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const Spike := preload("res://sim/spike/spike.gd")

const MAGIC := "EVOS"
const FORMAT_VERSION := 2
## Oldest format version this build still reads.
const MIN_READ_VERSION := 1
const ENCODING_RAW := 0
const ENCODING_ZSTD := 1

## Tests set this to keep expected failures out of the log.
static var quiet := false


static func save(core: RefCounted, path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var blocks := {}
	for layer_name in World.layer_names():
		blocks["world." + layer_name] = core.world.layer_bytes(layer_name)
	if core.spike != null:
		blocks.merge(core.spike.export_blocks())
	var header := {
		"format_version": FORMAT_VERSION,
		"engine": Engine.get_version_info()["string"],
		"seed": core.rngs.master_seed,
		"tick": core.tick,
		"time": core.time.describe(core.tick),
		"width": core.world.width,
		"height": core.world.height,
		"params": core.params.snapshot(),
		"rng": core.rngs.get_state(),
		"substrates_hash": core.substrates.source_hash,
		"flora_hash": core.flora.source_hash,
		"env_counters": core.env.get_counters(),
		"world_hash": core.world_hash(),
		"spike_count": core.spike_count(),
	}
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(FORMAT_VERSION)
	var header_bytes := JSON.stringify(header, "", true, true).to_utf8_buffer()
	f.store_32(header_bytes.size())
	f.store_buffer(header_bytes)
	f.store_32(blocks.size())
	for block_name: String in blocks:
		_store_block(f, block_name, blocks[block_name])
	var err := f.get_error()
	f.close()
	if err != OK:
		return err
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp_path, path)


## Returns {"core": SimCore or null, "error": String}. With verify, the rebuilt world is
## re-hashed and compared with the hash recorded at save time.
static func load_file(path: String, verify: bool = true) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err("cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	if f.get_length() < 12 or f.get_buffer(4).get_string_from_ascii() != MAGIC:
		return _err("%s is not an EvoSim save" % path)
	var version := f.get_32()
	if version < MIN_READ_VERSION or version > FORMAT_VERSION:
		return _err("save format version %d is not supported (this build reads %d-%d)" % [
				version, MIN_READ_VERSION, FORMAT_VERSION])
	var header: Variant = JSON.parse_string(f.get_buffer(f.get_32()).get_string_from_utf8())
	if typeof(header) != TYPE_DICTIONARY:
		return _err("corrupt save header")
	var blocks := {}
	var block_count := f.get_32()
	for b in block_count:
		var name_len := f.get_16()
		var block_name := f.get_buffer(name_len).get_string_from_utf8()
		var encoding := f.get_8()
		var raw_size := f.get_64()
		var stored_size := f.get_64()
		var data := f.get_buffer(stored_size)
		if data.size() != stored_size:
			return _err("truncated save (block %s)" % block_name)
		if encoding == ENCODING_ZSTD:
			data = data.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
		if data.size() != raw_size:
			return _err("block %s failed to decode" % block_name)
		blocks[block_name] = data

	var params := Registry.new()
	if not params.load_file():
		return _err("parameter registry failed to load: %s" % "; ".join(params.errors))
	params.restore_snapshot(header["params"])
	var rngs := Rng.new(int(header["seed"]))
	rngs.set_state(header["rng"])
	var world := World.new(int(header["width"]), int(header["height"]))
	for layer_name in World.layer_names():
		var key := "world." + layer_name
		if not blocks.has(key) or not world.set_layer_bytes(layer_name, blocks[key]):
			return _err("missing or bad layer block %s" % key)
	if verify and world.hash_state() != header.get("world_hash", ""):
		return _err("world hash mismatch after load")

	var core := SimCore.new()
	if not core.init_from_parts(params, rngs, world, int(header["tick"])):
		return _err("config tables failed to load: %s" % core.error)
	for table: Array in [["substrates", core.substrates], ["flora", core.flora]]:
		if table[1].source_hash != header.get(table[0] + "_hash", ""):
			push_warning("SaveLoad: config/%s.json changed since this save was written" % table[0])
	# Flora totals are kept incrementally; older saves without them get a full recount.
	if not core.env.set_counters(header.get("env_counters", {})):
		core.env.recount()
	var spike_count := int(header.get("spike_count", 0))
	if spike_count > 0:
		var spike := Spike.new()
		spike.setup(world, core.substrates, params, rngs)
		if not spike.import_blocks(blocks, spike_count):
			return _err("bad spike blocks")
		core.spike = spike
	return {"core": core, "error": ""}


static func _store_block(f: FileAccess, block_name: String, raw: PackedByteArray) -> void:
	var name_bytes := block_name.to_utf8_buffer()
	f.store_16(name_bytes.size())
	f.store_buffer(name_bytes)
	var data := raw
	var encoding := ENCODING_RAW
	if not raw.is_empty():
		var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
		if not packed.is_empty() and packed.size() < raw.size():
			data = packed
			encoding = ENCODING_ZSTD
	f.store_8(encoding)
	f.store_64(raw.size())
	f.store_64(data.size())
	f.store_buffer(data)


static func _err(message: String) -> Dictionary:
	if not quiet:
		push_error("SaveLoad: " + message)
	return {"core": null, "error": message}
