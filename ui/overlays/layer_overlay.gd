## Draws one u8 world layer as a single texture (one texel per cell) through layer.gdshader.
## PALETTE mode treats values as indices (substrate ids -> substrate colors); RAMP mode maps
## 0..255 onto a low->high color ramp. Dynamic layers refresh from periodic snapshots.
extends "res://ui/overlays/overlay.gd"

const SHADER := preload("res://ui/shaders/layer.gdshader")
const PALETTE_SIZE := 256

enum Mode { PALETTE, RAMP }

var layer_name: String
var mode: Mode
var ramp_low: Color
var ramp_high: Color
## True if the layer changes while the sim runs (re-copied from snapshots while visible).
var dynamic := false

var _sprite := Sprite2D.new()
var _material := ShaderMaterial.new()
var _texture: ImageTexture
var _size := Vector2i.ZERO
var _pending := PackedByteArray()


func _init(p_id: String, p_display_name: String, p_layer: String, p_mode: Mode,
		p_low: Color = Color.TRANSPARENT, p_high: Color = Color.WHITE, p_dynamic: bool = false) -> void:
	overlay_id = p_id
	display_name = p_display_name
	layer_name = p_layer
	mode = p_mode
	ramp_low = p_low
	ramp_high = p_high
	dynamic = p_dynamic
	_material.shader = SHADER
	_sprite.material = _material
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)


func setup(core: RefCounted, params: RefCounted) -> void:
	var w: RefCounted = core.world
	_size = Vector2i(w.width, w.height)
	_material.set_shader_parameter("mode", int(mode))
	_material.set_shader_parameter("cells", Vector2(_size))
	_material.set_shader_parameter("max_taps", params.get_int("ui.layer_supersample_max"))
	_material.set_shader_parameter("ramp_low", ramp_low)
	_material.set_shader_parameter("ramp_high", ramp_high)
	_material.set_shader_parameter("opacity",
			1.0 if mode == Mode.PALETTE else params.get_float("ui.overlay_opacity"))
	if mode == Mode.PALETTE:
		_material.set_shader_parameter("palette", _palette_texture(core.substrates.colors))
	# Called with the sim parked (startup or load); still copy, so no Image ever shares a
	# live sim buffer.
	_upload((w.get(layer_name) as PackedByteArray).slice(0))
	_pending = PackedByteArray()


func needed_layers() -> PackedStringArray:
	return PackedStringArray([layer_name]) if dynamic and visible else PackedStringArray()


func on_snapshot(snap: Dictionary) -> void:
	var layers: Dictionary = snap.get("layers", {})
	if layers.has(layer_name):
		_pending = layers[layer_name]


func flush_upload() -> bool:
	if _pending.is_empty():
		return false
	_upload(_pending)
	_pending = PackedByteArray()
	return true


func _upload(bytes: PackedByteArray) -> void:
	var img := Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_R8, bytes)
	if _texture != null and Vector2i(_texture.get_size()) == _size:
		_texture.update(img)
	else:
		_texture = ImageTexture.create_from_image(img)
		_sprite.texture = _texture


static func _palette_texture(colors: PackedColorArray) -> ImageTexture:
	var img := Image.create(PALETTE_SIZE, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.MAGENTA)  # unknown ids stand out
	for i in mini(colors.size(), PALETTE_SIZE):
		img.set_pixel(i, 0, colors[i])
	return ImageTexture.create_from_image(img)
