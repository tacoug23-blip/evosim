## Draws a ring around the inspected entity (position from the inspector's latest probe).
extends Node2D

const RING_PX := 2.0
const RING_RADIUS_PX := 9.0
const RING_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const RING_SEGMENTS := 32

var view: Node2D
var cell := Vector2i(-1, -1)


func show_at(c: Vector2i) -> void:
	cell = c
	queue_redraw()


func hide_ring() -> void:
	cell = Vector2i(-1, -1)
	queue_redraw()


func _process(_delta: float) -> void:
	if cell.x >= 0:
		queue_redraw()  # keep the ring a constant screen size while zooming


func _draw() -> void:
	if cell.x < 0 or view == null:
		return
	var zoom: float = view.camera.zoom.x
	var radius := maxf(RING_RADIUS_PX / zoom, 0.9)
	draw_arc(Vector2(cell) + Vector2(0.5, 0.5), radius, 0.0, TAU, RING_SEGMENTS, RING_COLOR, RING_PX / zoom)
