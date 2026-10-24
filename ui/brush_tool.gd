## Debug brush: harvest everything, or plant mature flora, in a disc under the cursor.
## Left-drag paints while a mode is active (the camera then pans with middle/right drag only).
## Edits go through SimRunner.submit, so they run on the sim thread between ticks.
extends Node2D

const EnvSystem := preload("res://sim/env/env_system.gd")

enum Mode { OFF, HARVEST, PLANT }

## Seconds between snapshot requests while painting (each copies two 16 MB layers).
const FEEDBACK_INTERVAL_MSEC := 200
const OUTLINE_PX := 1.5
const OUTLINE_COLOR := Color(1.0, 0.95, 0.4, 0.9)
const OUTLINE_SEGMENTS := 48

var mode := Mode.OFF
var plant_type := 1
var radius := 4
var runner: RefCounted
var view: Node2D

var _painting := false
var _last_cell := Vector2i(-1, -1)
var _last_feedback_msec := 0


func is_active() -> bool:
	return mode != Mode.OFF


func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.OFF or runner == null:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_painting = event.pressed
		_last_cell = Vector2i(-1, -1)
		if _painting:
			_paint()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _painting:
		_paint()
		get_viewport().set_input_as_handled()


func _paint() -> void:
	paint_at(view.cell_under_mouse())


## Apply the current brush centred on `c` (also used by the scripted app check).
func paint_at(c: Vector2i) -> void:
	if c == _last_cell:
		return
	_last_cell = c
	var brush := EnvSystem.Brush.HARVEST if mode == Mode.HARVEST else EnvSystem.Brush.PLANT
	var t := plant_type
	var r := radius
	runner.submit(func(core: RefCounted) -> void: core.env.apply_brush(c.x, c.y, r, brush, t))
	var now := Time.get_ticks_msec()
	if now - _last_feedback_msec >= FEEDBACK_INTERVAL_MSEC:
		_last_feedback_msec = now
		runner.request_snapshot(view.needed_layers())


func _process(_delta: float) -> void:
	if mode != Mode.OFF or _painting:
		queue_redraw()


func _draw() -> void:
	if mode == Mode.OFF or view == null:
		return
	var c: Vector2i = view.cell_under_mouse()
	var zoom: float = view.camera.zoom.x
	draw_arc(Vector2(c) + Vector2(0.5, 0.5), radius + 0.5, 0.0, TAU, OUTLINE_SEGMENTS,
			OUTLINE_COLOR, OUTLINE_PX / zoom)
