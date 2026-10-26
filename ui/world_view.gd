## World renderer: a camera, one child node per overlay, day/night shading, and the debug
## brush. Reads sim state only through snapshots; never writes it directly.
extends Node2D

signal overlay_registered(overlay: Node2D)
## Left click (press and release without dragging) on a cell, while the brush is off.
signal cell_clicked(cell: Vector2i)

const CameraController := preload("res://ui/camera_controller.gd")
const LayerOverlay := preload("res://ui/overlays/layer_overlay.gd")
const FloraOverlay := preload("res://ui/overlays/flora_overlay.gd")
const EntityOverlay := preload("res://ui/overlays/entity_overlay.gd")
const BrushTool := preload("res://ui/brush_tool.gd")
const SelectionRing := preload("res://ui/selection_ring.gd")

## Mouse travel (screen pixels) under which a left press+release counts as a click.
const CLICK_SLOP_PX := 5.0

## Darkest tint at full night when day/night shading is on. Presentation only.
const NIGHT_TINT := Color(0.22, 0.26, 0.45)

var camera: CameraController
var brush: BrushTool
var flora_overlay: FloraOverlay
var entity_overlay: EntityOverlay
var selection: SelectionRing
var overlays: Array[Node2D] = []
var daynight_enabled := false

var _core: RefCounted
var _params: RefCounted
var _shade := CanvasModulate.new()
var _press_pos := Vector2.ZERO
var _pressed := false


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
	entity_overlay = EntityOverlay.new()
	register_overlay(entity_overlay, true)
	selection = SelectionRing.new()
	selection.view = self
	add_child(selection)
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


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or brush.is_active():
		return
	if mb.pressed:
		_pressed = true
		_press_pos = mb.position
	elif _pressed:
		_pressed = false
		if mb.position.distance_to(_press_pos) <= CLICK_SLOP_PX:
			cell_clicked.emit(cell_under_mouse())
