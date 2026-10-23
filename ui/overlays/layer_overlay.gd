## Draws one u8 world layer as a single texture (one texel per cell) through layer.gdshader.
## PALETTE mode treats values as indices (substrate ids -> substrate colors); RAMP mode maps
## 0..255 onto a low->high color ramp.
extends "res://ui/overlays/overlay.gd"

const SHADER := preload("res://ui/shaders/layer.gdshader")
const PALETTE_SIZE := 256

enum Mode { PALETTE, RAMP }

var layer_name: String
var mode: Mode
var ramp_low: Color
var ramp_high: Color

var _sprite := Sprite2D.new()
var _material := ShaderMaterial.new()
var _texture: ImageTexture


func _init(p_id: String, p_display_name: String, p_layer: String, p_mode: Mode,
		p_low: Color = Color.TRANSPARENT, p_high: Color = Color.WHITE) -> void:
	overlay_id = p_id
	display_name = p_display_name
	layer_name = p_layer
	mode = p_mode
	ramp_low = p_low
	ramp_high = p_high
	_material.shader = SHADER
	_sprite.material = _material
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)


func setup(core: RefCounted, params: RefCounted) -> void:
	var w: RefCounted = core.world
	_material.set_shader_parameter("mode", int(mode))
	_material.set_shader_parameter("cells", Vector2(w.width, w.height))
	_material.set_shader_parameter("max_taps", params.get_int("ui.layer_supersample_max"))
	_material.set_shader_parameter("ramp_low", ramp_low)
	_material.set_shader_parameter("ramp_high", ramp_high)
	_material.set_shader_parameter("opacity",
			1.0 if mode == Mode.PALETTE else params.get_float("ui.overlay_opacity"))
	if mode == Mode.PALETTE:
		_material.set_shader_parameter("palette", _palette_texture(core.substrates.colors))
	refresh(core)


## Re-upload the layer (call when the layer's data changed).
func refresh(core: RefCounted) -> void:
	var w: RefCounted = core.world
	var bytes: PackedByteArray = w.get(layer_name)
	var img := Image.create_from_data(w.width, w.height, false, Image.FORMAT_R8, bytes)
	if _texture != null and _texture.get_size() == Vector2(w.width, w.height):
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
