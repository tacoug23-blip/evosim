## World renderer: a camera plus one child node per overlay. Reads sim state, never writes.
extends Node2D

signal overlay_registered(overlay: Node2D)

const CameraController := preload("res://ui/camera_controller.gd")
const LayerOverlay := preload("res://ui/overlays/layer_overlay.gd")
const SpikeEntityOverlay := preload("res://ui/overlays/spike_entity_overlay.gd")

var camera: CameraController
var overlays: Array[Node2D] = []

var _core: RefCounted
var _params: RefCounted


func setup(core: RefCounted, params: RefCounted) -> void:
	_core = core
	_params = params
	camera = CameraController.new()
	add_child(camera)
	camera.make_current()
	camera.setup(params, Vector2(core.world.width, core.world.height))
	register_overlay(LayerOverlay.new("terrain", "Terrain", "substrate",
			LayerOverlay.Mode.PALETTE), true)
	register_overlay(LayerOverlay.new("fertility", "Fertility", "fertility",
			LayerOverlay.Mode.RAMP, Color(0.35, 0.2, 0.05, 0.0), Color(0.55, 1.0, 0.15, 1.0)), false)
	register_overlay(LayerOverlay.new("moisture", "Moisture", "moisture",
			LayerOverlay.Mode.RAMP, Color(0.8, 0.6, 0.2, 0.0), Color(0.1, 0.45, 1.0, 1.0)), false)
	register_overlay(SpikeEntityOverlay.new(), true)


## Add an overlay above the existing ones. Later phases plug in here.
func register_overlay(overlay: Node2D, visible_at_start: bool) -> void:
	add_child(overlay)
	overlay.visible = visible_at_start
	overlay.setup(_core, _params)
	overlays.append(overlay)
	overlay_registered.emit(overlay)


## Point every overlay at a new core (after a load).
func rebind(core: RefCounted) -> void:
	_core = core
	for o in overlays:
		o.setup(core, _params)


func on_snapshot(snap: Dictionary) -> void:
	for o in overlays:
		o.on_snapshot(snap)


func cell_under_mouse() -> Vector2i:
	var p := camera.screen_to_world(get_viewport().get_mouse_position())
	return Vector2i(floori(p.x), floori(p.y))


func _process(_delta: float) -> void:
	var z := camera.zoom.x
	for o in overlays:
		o.on_zoom(z)
