## Incremental SHA-256 over sim state, for determinism tests and save verification.
## Every add_* call is length- or width-prefixed so field boundaries cannot alias.
extends RefCounted

var _ctx := HashingContext.new()
var _scratch := PackedByteArray()


func _init() -> void:
	_ctx.start(HashingContext.HASH_SHA256)
	_scratch.resize(8)


func add_int(value: int) -> void:
	_scratch.encode_s64(0, value)
	_ctx.update(_scratch)


func add_string(value: String) -> void:
	add_bytes(value.to_utf8_buffer())


func add_bytes(bytes: PackedByteArray) -> void:
	add_int(bytes.size())
	if not bytes.is_empty():
		_ctx.update(bytes)


func add_i32(values: PackedInt32Array) -> void:
	add_bytes(values.to_byte_array())


func finish_hex() -> String:
	return _ctx.finish().hex_encode()
