## Base class for anything drawn over the world. To add an overlay: subclass, set overlay_id
## and display_name, implement setup() (and on_snapshot()/on_zoom() if needed), then call
## WorldView.register_overlay(). The HUD lists every registered overlay as a toggle.
## Overlays read sim state; they never write it.
extends Node2D

var overlay_id := ""
var display_name := ""


## Build or rebuild GPU resources from the core. Called again after a load.
func setup(_core: RefCounted, _params: RefCounted) -> void:
	pass


## Called with each render snapshot the sim thread publishes (see SimCore.render_snapshot).
func on_snapshot(_snap: Dictionary) -> void:
	pass


## Called every frame with the camera scale (screen pixels per cell).
func on_zoom(_zoom: float) -> void:
	pass
