## Flora overlay: color by flora type, opacity by biomass (relative to the type's max), with an
## optional season tint. Two R8 textures (flora_type, flora_biomass) refreshed from periodic
## snapshots, uploaded on separate frames.
extends "res://ui/overlays/overlay.gd"

const SHADER := preload("res://ui/shaders/flora.gdshader")
const PALETTE_SIZE := 256
## Season tints (rgb, strength in a), [spring, summer, autumn, winter]. Presentation only.
const SEASON_TINTS := [Color(0.75, 1.0, 0.55, 0.12), Color(1.0, 0.95, 0.6, 0.0),
		Color(0.95, 0.55, 0.2, 0.4), Color(0.88, 0.92, 1.0, 0.55)]

var season_tint_enabled := false

var _sprite := Sprite2D.new()
var _material := ShaderMaterial.new()
var _type_tex: ImageTexture
var _bio_tex: ImageTexture
var _size := Vector2i.ZERO
var _pending_type := PackedByteArray()
var _pending_bio := PackedByteArray()
var _time: RefCounted
var _tick := 0


func _init() -> void:
	overlay_id = "flora"
	display_name = "Flora"
	_material.shader = SHADER
	_sprite.material = _material
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)


func setup(core: RefCounted, params: RefCounted) -> void:
	var w: RefCounted = core.world
	_size = Vector2i(w.width, w.height)
	_time = core.time
	_tick = core.tick
	season_tint_enabled = params.get_bool("ui.season_tint")
	_material.set_shader_parameter("cells", Vector2(_size))
	_material.set_shader_parameter("max_taps", params.get_int("ui.layer_supersample_max"))
	_material.set_shader_parameter("opacity", params.get_float("ui.overlay_opacity") * 1.4)
	_material.set_shader_parameter("palette", _palette(core.flora))
	_type_tex = _texture_from((w.flora_type as PackedByteArray).slice(0), _type_tex)
	_bio_tex = _texture_from((w.flora_biomass as PackedByteArray).slice(0), _bio_tex)
	_sprite.texture = _type_tex
	_material.set_shader_parameter("type_tex", _type_tex)
	_material.set_shader_parameter("biomass_tex", _bio_tex)
	_pending_type = PackedByteArray()
	_pending_bio = PackedByteArray()
	_apply_tint()


func needed_layers() -> PackedStringArray:
	return PackedStringArray(["flora_type", "flora_biomass"]) if visible else PackedStringArray()


func on_snapshot(snap: Dictionary) -> void:
	_tick = snap.get("tick", _tick)
	var layers: Dictionary = snap.get("layers", {})
	if layers.has("flora_type") and layers.has("flora_biomass"):
		_pending_type = layers["flora_type"]
		_pending_bio = layers["flora_biomass"]
	_apply_tint()


func flush_upload() -> bool:
	if not _pending_type.is_empty():
		_type_tex = _texture_from(_pending_type, _type_tex)
		_pending_type = PackedByteArray()
		return true
	if not _pending_bio.is_empty():
		_bio_tex = _texture_from(_pending_bio, _bio_tex)
		_pending_bio = PackedByteArray()
		return true
	return false


func set_season_tint(on: bool) -> void:
	season_tint_enabled = on
	_apply_tint()


func _apply_tint() -> void:
	var tint: Color = SEASON_TINTS[_time.season(_tick)] if season_tint_enabled and _time != null \
			else Color(1, 1, 1, 0)
	_material.set_shader_parameter("season_tint", tint)


func _texture_from(bytes: PackedByteArray, existing: ImageTexture) -> ImageTexture:
	var img := Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_R8, bytes)
	if existing != null and Vector2i(existing.get_size()) == _size:
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


## Palette: rgb = type color, a = max_biomass / 255 (so the shader can normalize biomass).
static func _palette(flora: RefCounted) -> ImageTexture:
	var img := Image.create(PALETTE_SIZE, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 1, 1))
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	for t in range(1, flora.count() + 1):
		var c: Color = flora.colors[t]
		img.set_pixel(t, 0, Color(c.r, c.g, c.b, flora.max_biomass[t] / 255.0))
	return ImageTexture.create_from_image(img)
