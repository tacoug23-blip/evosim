## Entities as GPU points, one draw call for any count, colored by energy or by sex.
##
## The mesh is one point vertex per entity slot; the vertex shader reads the slot's x, y,
## energy and max_energy from RGBA8 textures holding the raw little-endian int32 arrays of the
## snapshot (one texel per slot), and sex from an R8 texture. Dead slots have x = -1 and are
## hidden. Updating is a few native buffer uploads per snapshot, no per-entity GDScript.
extends "res://ui/overlays/overlay.gd"

const SHADER := preload("res://ui/shaders/points.gdshader")
## Width of the per-slot textures; height = ceil(capacity / width). Layout constant.
const TEX_WIDTH := 2048
const INT_LAYERS := ["entity_x", "entity_y", "entity_energy", "entity_max_energy"]

enum ColorMode { ENERGY, SEX }

var color_mode := ColorMode.ENERGY

var _mesh_instance := MeshInstance2D.new()
var _material := ShaderMaterial.new()
var _textures := {}
var _capacity := -1
var _rows := 0
var _world_size := Vector2.ZERO
var _min_px := 1.0


func _init() -> void:
	overlay_id = "entities"
	display_name = "Entities"
	_material.shader = SHADER
	_mesh_instance.material = _material
	add_child(_mesh_instance)


func setup(core: RefCounted, params: RefCounted) -> void:
	_world_size = Vector2(core.world.width, core.world.height)
	_min_px = params.get_float("ui.entity_point_min_px")
	_material.set_shader_parameter("tex_width", TEX_WIDTH)
	set_color_mode(ColorMode.SEX if params.get_bool("ui.entity_color_by_sex") else ColorMode.ENERGY)
	_capacity = -1
	_build(0)


func set_color_mode(mode: ColorMode) -> void:
	color_mode = mode
	_material.set_shader_parameter("color_mode", int(mode))


func on_snapshot(snap: Dictionary) -> void:
	var n: int = snap.get("entity_capacity", 0)
	if n != _capacity:
		_build(n)
	if n == 0:
		return
	for key: String in INT_LAYERS:
		_upload(key, snap[key], 4)
	_upload("entity_sex", snap["entity_sex"], 1)


func on_zoom(zoom: float) -> void:
	_material.set_shader_parameter("point_px", maxf(zoom, _min_px))


func _build(n: int) -> void:
	_capacity = n
	if n == 0:
		_mesh_instance.mesh = null
		return
	@warning_ignore("integer_division")
	_rows = (n + TEX_WIDTH - 1) / TEX_WIDTH
	var verts := PackedVector2Array()
	verts.resize(n)
	verts.fill(Vector2.ZERO)
	# Real positions come from the textures; these corners only give the mesh an AABB covering
	# the whole map so the canvas never culls it.
	verts[n - 1] = _world_size
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	_mesh_instance.mesh = mesh
	for key: String in INT_LAYERS:
		_textures[key] = _blank(Image.FORMAT_RGBA8)
		_material.set_shader_parameter(key, _textures[key])
	_textures["entity_sex"] = _blank(Image.FORMAT_R8)
	_material.set_shader_parameter("entity_sex", _textures["entity_sex"])


func _blank(format: Image.Format) -> ImageTexture:
	var img := Image.create(TEX_WIDTH, _rows, false, format)
	img.fill(Color(1, 1, 1, 1))  # x = 0xFFFFFFFF = -1 = hidden
	return ImageTexture.create_from_image(img)


func _upload(key: String, bytes: PackedByteArray, bytes_per_texel: int) -> void:
	var padded := bytes.duplicate()
	padded.resize(TEX_WIDTH * _rows * bytes_per_texel)
	var format := Image.FORMAT_RGBA8 if bytes_per_texel == 4 else Image.FORMAT_R8
	(_textures[key] as ImageTexture).update(Image.create_from_data(TEX_WIDTH, _rows, false, format, padded))
