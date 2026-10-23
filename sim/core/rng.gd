## Deterministic RNG streams, one per subsystem (spec section 2.7).
##
## A stream's seed is derived from the master seed and the stream name alone, so adding a
## new subsystem (a new stream) never shifts the sequence any other subsystem sees.
extends RefCounted

const MASK32 := 0xFFFFFFFF
const MIX_MUL := 0x45d9f3b

var master_seed: int

var _streams := {}


func _init(seed_value: int = 0) -> void:
	master_seed = seed_value


func stream(stream_name: String) -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = _streams.get(stream_name)
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.seed = derive_seed(master_seed, stream_name)
		_streams[stream_name] = rng
	return rng


func stream_names() -> PackedStringArray:
	var out := PackedStringArray(_streams.keys())
	out.sort()
	return out


## SHA-256 of "evosim-rng|<master>|<name>", first 8 bytes as a signed 64-bit int.
## Stable across runs, platforms, and engine versions (unlike String.hash()).
static func derive_seed(master: int, stream_name: String) -> int:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("evosim-rng|%d|%s" % [master, stream_name]).to_utf8_buffer())
	return ctx.finish().decode_s64(0)


## Low 32 bits of the stream's derived seed, for counter-based draws.
func stream_seed32(stream_name: String) -> int:
	return derive_seed(master_seed, stream_name) & MASK32


## Counter-based randomness: a 32-bit value that depends only on (seed32, a, b). Order- and
## thread-independent, so parallel phases stay deterministic for any thread count. Every
## multiply keeps operands below 2^32 and 2^27, so nothing overflows 64-bit ints, and the
## result is bit-identical in any language (the Rust port can reproduce it exactly).
static func hash3(seed32: int, a: int, b: int) -> int:
	return mix32(mix32(mix32(seed32 ^ (a & MASK32)) ^ (b & MASK32)))


## 32-bit integer finalizer (Mueller's hash; constant < 2^27).
static func mix32(v: int) -> int:
	v = ((v >> 16) ^ v) * MIX_MUL & MASK32
	v = ((v >> 16) ^ v) * MIX_MUL & MASK32
	return (v >> 16) ^ v


## name -> PCG state as a decimal string (JSON numbers cannot hold 64-bit ints exactly).
func get_state() -> Dictionary:
	var out := {}
	for stream_name: String in _streams:
		out[stream_name] = str((_streams[stream_name] as RandomNumberGenerator).state)
	return out


func set_state(state: Dictionary) -> void:
	_streams.clear()
	for stream_name: String in state:
		stream(stream_name).state = str(state[stream_name]).to_int()
