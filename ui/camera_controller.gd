## Pan/zoom camera over the world. Drag with any mouse button to pan (left is taken by the
## debug brush while it is active), wheel (or trackpad
## pinch) zooms toward the cursor with smoothing, WASD/arrows pan, Home fits the map.
extends Camera2D

## Trackpad pan gestures report small deltas; scale them to feel like a drag.
const PAN_GESTURE_SCALE := 20.0

var _min_zoom := 0.05
var _max_zoom := 48.0
var _step := 1.2
var _smoothing := 14.0
var _pan_speed := 900.0
var _world_size := Vector2.ONE
var _target_zoom := 1.0
var _anchor_world := Vector2.ZERO
var _anchor_screen := Vector2.ZERO
var _anchored := false
var _dragging := false
## Returns whether a left-drag should pan (false while the debug brush owns the left button).
var pan_with_left: Callable = func() -> bool: return true


func setup(params: RefCounted, world_size: Vector2) -> void:
	_min_zoom = params.get_float("ui.zoom_min")
	_max_zoom = params.get_float("ui.zoom_max")
	_step = params.get_float("ui.zoom_step")
	_smoothing = params.get_float("ui.zoom_smoothing")
	_pan_speed = params.get_float("ui.pan_key_speed")
	_world_size = world_size
	fit()


func fit_zoom() -> float:
	var vp := get_viewport_rect().size
	return clampf(minf(vp.x / _world_size.x, vp.y / _world_size.y), _min_zoom, _max_zoom)


func fit() -> void:
	set_view(_world_size / 2.0, fit_zoom())


## Jump to a view immediately (no smoothing). Used by fit() and the render autotest.
func set_view(center: Vector2, z: float) -> void:
	_target_zoom = clampf(z, _min_zoom, _max_zoom)
	zoom = Vector2.ONE * _target_zoom
	position = center
	_anchored = false
	_clamp()


func screen_to_world(screen_pos: Vector2) -> Vector2:
	return position + (screen_pos - get_viewport_rect().size / 2.0) / zoom.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_at(mb.position, _step)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_at(mb.position, 1.0 / _step)
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed and pan_with_left.call()
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		position -= (event as InputEventMouseMotion).relative / zoom.x
		_anchored = false
		_clamp()
	elif event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		_zoom_at(g.position, g.factor)
	elif event is InputEventPanGesture:
		position += (event as InputEventPanGesture).delta * PAN_GESTURE_SCALE / zoom.x
		_clamp()
	elif event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_HOME:
		fit()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_target_zoom = clampf(_target_zoom * factor, _min_zoom, _max_zoom)
	_anchor_screen = screen_pos
	_anchor_world = screen_to_world(screen_pos)
	_anchored = true


func _process(delta: float) -> void:
	var pan := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT))
				- float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN))
				- float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)))
	if pan != Vector2.ZERO:
		position += pan * _pan_speed * delta / zoom.x
		_anchored = false
	var z := zoom.x
	if z != _target_zoom:
		# Interpolate in log space so zooming feels uniform at every scale.
		var k := 1.0 if _smoothing <= 0.0 else 1.0 - exp(-_smoothing * delta)
		z = exp(lerpf(log(z), log(_target_zoom), k))
		if absf(z - _target_zoom) <= _target_zoom * 0.001:
			z = _target_zoom
		zoom = Vector2(z, z)
		if _anchored:
			# Keep the world point that was under the cursor under the cursor.
			position = _anchor_world - (_anchor_screen - get_viewport_rect().size / 2.0) / z
	_clamp()


func _clamp() -> void:
	position = position.clamp(Vector2.ZERO, _world_size)
