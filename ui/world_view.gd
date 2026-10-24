## World renderer: a camera, one child node per overlay, day/night shading, and the debug
## brush. Reads sim state only through snapshots; never writes it directly.
extends Node2D

signal overlay_registered(overlay: Node2D)

const CameraController := preload("res://ui/camera_controller.gd")
const LayerOverlay := preload("res://ui/overlays/layer_overlay.gd")
const FloraOverlay := preload("res://ui/overlays/flora_overlay.gd")
const SpikeEntityOverlay := preload("res://ui/overlays/spike_entity_overlay.gd")
const BrushTool := preload("res://ui/brush_tool.gd")

## Darkest tint at full night when day/night shading is on. Presentation only.
const NIGHT_TINT := Color(0.22, 0.26, 0.45)

var camera: CameraController
var brush: BrushTool
var flora_overlay: FloraOverlay
var overlays: Array[Node2D] = []
var daynight_enabled := false

var _core: RefCounted
var _params: RefCounted
var _shade := CanvasModulate.new()


func setup(core: RefCounted, params: RefCounted) -> void:
	_core = core
	_params = params
	camera = CameraController.new()
	add_child(camera)
	camera.make_current()
	camera.setup(params, Vector2(core.world.width, core.world.height))
	add_child(_shade)
	daynight_enabled = params.get_bool("ui.daynight_shading")
	register_overlay(LayerOverlay.new("terrain", "Terrain", "substrate",
			LayerOverlay.Mode.PALETTE), true)
	flora_overlay = FloraOverlay.new()
	register_overlay(flora_overlay, true)
	register_overlay(LayerOverlay.new("fertility", "Fertility", "fertility",
			LayerOverlay.Mode.RAMP, Color(0.35, 0.2, 0.05, 0.0), Color(0.55, 1.0, 0.15, 1.0), true), false)
	register_overlay(LayerOverlay.new("moisture", "Moisture", "moisture",
			LayerOverlay.Mode.RAMP, Color(0.8, 0.6, 0.2, 0.0), Color(0.1, 0.45, 1.0, 1.0), true), false)
	register_overlay(SpikeEntityOverlay.new(), true)
	# Added after the camera so it sees left clicks first.
	brush = BrushTool.new()
	brush.view = self
	brush.radius = params.get_int("ui.brush_radius")
	add_child(brush)
	camera.pan_with_left = func() -> bool: return not brush.is_active()


## Add an overlay above the existing ones. Later phases plug in here.
func register_overlay(overlay: Node2D, visible_at_start: bool) -> void:
	add_child(overlay)
	overlay.visible = visible_at_start
	overlay.setup(_core, _params)
	overlays.append(overlay)
	overlay_registered.emit(overlay)


## Point every overlay at a new core (after a load, sim parked).
func rebind(core: RefCounted) -> void:
	_core = core
	for o in overlays:
		o.setup(core, _params)


func on_snapshot(snap: Dictionary) -> void:
	for o in overlays:
		o.on_snapshot(snap)


## Layers the visible overlays want in the next periodic snapshot.
func needed_layers() -> PackedStringArray:
	var out := PackedStringArray()
	for o in overlays:
		for layer_name in o.needed_layers():
			if not out.has(layer_name):
				out.append(layer_name)
	return out


## Day/night factor from the sim's time system (1 = full day). Ignored while shading is off.
func set_daylight(daylight: float) -> void:
	_shade.color = NIGHT_TINT.lerp(Color.WHITE, daylight) if daynight_enabled else Color.WHITE


func cell_under_mouse() -> Vector2i:
	var p := camera.screen_to_world(get_viewport().get_mouse_position())
	return Vector2i(floori(p.x), floori(p.y))


func _process(_delta: float) -> void:
	var z := camera.zoom.x
	for o in overlays:
		o.on_zoom(z)
	for o in overlays:  # at most one texture upload per frame
		if o.flush_upload():
			break
