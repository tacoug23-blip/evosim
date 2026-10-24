## Base class for anything drawn over the world. To add an overlay: subclass, set overlay_id
## and display_name, implement setup() (and on_snapshot()/on_zoom()/needed_layers() if needed),
## then call WorldView.register_overlay(). The HUD lists every registered overlay as a toggle.
## Overlays read sim state only through snapshots; they never write it and never keep
## references to live sim arrays.
extends Node2D

var overlay_id := ""
var display_name := ""


## Build or rebuild GPU resources from the core. Called again after a load (sim parked).
func setup(_core: RefCounted, _params: RefCounted) -> void:
	pass


## Called with each render snapshot the sim thread publishes (see SimCore.render_snapshot).
func on_snapshot(_snap: Dictionary) -> void:
	pass


## Called every frame with the camera scale (screen pixels per cell).
func on_zoom(_zoom: float) -> void:
	pass


## World layers this overlay wants copied in the next periodic snapshot (only while visible).
func needed_layers() -> PackedStringArray:
	return PackedStringArray()


## Upload at most one pending texture; returns true if it did. WorldView calls this for one
## overlay per frame so 16 MB uploads do not pile into a single frame.
func flush_upload() -> bool:
	return false
