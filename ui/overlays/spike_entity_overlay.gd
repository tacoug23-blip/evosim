## Draws the spike's dummy entities as GPU points, one draw call for any count.
##
## The mesh is N point vertices whose positions are ignored: the vertex shader reads each
## entity's x and y from two RGBA8 textures (the raw little-endian int32 arrays from the
## snapshot, one texel per entity) using VERTEX_ID. Updating positions is therefore two native
## buffer uploads per snapshot, with no per-entity GDScript work on the main thread.
extends "res://ui/overlays/overlay.gd"

const SHADER := preload("res://ui/shaders/points.gdshader")
## Width of the position textures; height = ceil(count / width). Layout constant.
const TEX_WIDTH := 2048
const BYTES_PER_TEXEL := 4

var _mesh_instance := MeshInstance2D.new()
var _material := ShaderMaterial.new()
var _tex_x: ImageTexture
var _tex_y: ImageTexture
var _count := -1
var _rows := 0
var _world_size := Vector2.ZERO
var _min_px := 1.0


func _init() -> void:
	overlay_id = "spike_entities"
	display_name = "Spike entities"
	_material.shader = SHADER
	_mesh_instance.material = _material
	add_child(_mesh_instance)


func setup(core: RefCounted, params: RefCounted) -> void:
	_world_size = Vector2(core.world.width, core.world.height)
	_min_px = params.get_float("ui.entity_point_min_px")
	_material.set_shader_parameter("tex_width", TEX_WIDTH)
	_count = -1
	_build(0)


func on_snapshot(snap: Dictionary) -> void:
	var n: int = snap.get("spike_count", 0)
	if n != _count:
		_build(n)
	if n == 0:
		return
	_upload(_tex_x, snap["spike_x"])
	_upload(_tex_y, snap["spike_y"])


func on_zoom(zoom: float) -> void:
	_material.set_shader_parameter("point_px", maxf(zoom, _min_px))


func _build(n: int) -> void:
	_count = n
	if n == 0:
		_mesh_instance.mesh = null
		return
	@warning_ignore("integer_division")
	_rows = (n + TEX_WIDTH - 1) / TEX_WIDTH
	var verts := PackedVector2Array()
	verts.resize(n)
	verts.fill(Vector2.ZERO)
	# Real positions come from the textures; these two corners only give the mesh an AABB
	# covering the whole map so the canvas never culls it.
	verts[n - 1] = _world_size
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	_mesh_instance.mesh = mesh
	_tex_x = _blank_texture()
	_tex_y = _blank_texture()
	_material.set_shader_parameter("pos_x", _tex_x)
	_material.set_shader_parameter("pos_y", _tex_y)


func _blank_texture() -> ImageTexture:
	var img := Image.create(TEX_WIDTH, _rows, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))  # 0xFFFFFFFF = -1 = hidden
	return ImageTexture.create_from_image(img)


func _upload(tex: ImageTexture, bytes: PackedByteArray) -> void:
	var padded := bytes.duplicate()
	padded.resize(TEX_WIDTH * _rows * BYTES_PER_TEXEL)
	tex.update(Image.create_from_data(TEX_WIDTH, _rows, false, Image.FORMAT_RGBA8, padded))
