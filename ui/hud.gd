## Top bar: speed controls, save/load, spike spawner, overlay and shading toggles, debug brush,
## live stats with the in-game clock, and the cell under the cursor. Talks to main.gd; reads
## sim state only through the runner (stats, probes), never directly.
extends CanvasLayer

const SPIKE_CHOICES := [0, 1000, 10000, 50000, 100000]
const MAX_BRUSH_RADIUS := 64

var _main: Node
var _status: Label
var _stats: Label
var _cell: Label
var _overlay_row: HBoxContainer
var _speed_buttons := {}
var _spike_choice: OptionButton
var _brush_choice: OptionButton
var _brush_radius: SpinBox
var _refresh_interval := 0.25
var _refresh_timer := 0.0
var _last_ticks := 0
var _last_time_usec := 0
var _tps := 0.0
var _status_until := 0
var _probe_cell := -1


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(panel)
	var col := VBoxContainer.new()
	panel.add_child(col)

	var row := HBoxContainer.new()
	col.add_child(row)
	var group := ButtonGroup.new()
	for entry: Array in [["Pause", 0.0], ["1x", 1.0], ["2x", 2.0], ["5x", 5.0], ["20x", 20.0], ["Max", -1.0]]:
		var b := Button.new()
		b.text = entry[0]
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: _main.set_speed(entry[1]))
		row.add_child(b)
		_speed_buttons[entry[1]] = b
	_add_button(row, "Step", func() -> void: _main.step_once())
	row.add_child(VSeparator.new())
	_add_button(row, "Save", func() -> void: _main.quick_save())
	_add_button(row, "Load", func() -> void: _main.quick_load())
	row.add_child(VSeparator.new())
	_add_label(row, "Spike:")
	_spike_choice = OptionButton.new()
	for n: int in SPIKE_CHOICES:
		_spike_choice.add_item(str(n) if n > 0 else "none")
	row.add_child(_spike_choice)
	_add_button(row, "Spawn", func() -> void: _main.respawn_spike(SPIKE_CHOICES[_spike_choice.selected]))
	row.add_child(VSeparator.new())
	_add_label(row, "Brush:")
	_brush_choice = OptionButton.new()
	row.add_child(_brush_choice)
	_add_label(row, "radius")
	_brush_radius = SpinBox.new()
	_brush_radius.min_value = 0
	_brush_radius.max_value = MAX_BRUSH_RADIUS
	row.add_child(_brush_radius)
	row.add_child(VSeparator.new())
	_status = Label.new()
	row.add_child(_status)

	_overlay_row = HBoxContainer.new()
	col.add_child(_overlay_row)
	_add_label(_overlay_row, "Overlays:")

	_stats = Label.new()
	col.add_child(_stats)
	_cell = Label.new()
	col.add_child(_cell)

	var help := Label.new()
	help.text = "Drag: pan   Wheel: zoom   WASD/arrows: pan   Home: fit   Space: pause   1-4: speed   5: max   N: step   F5/F9: save/load   Brush: left-drag paints (pan with middle/right)"
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help.position.y -= 28
	help.position.x += 8
	add_child(help)


func set_status(text: String, seconds: float = 0.0) -> void:
	_status.text = text
	_status_until = Time.get_ticks_msec() + int(seconds * 1000.0) if seconds > 0.0 else 0


func bind(main: Node) -> void:
	_main = main
	_refresh_interval = 1.0 / main.params.get_float("ui.hud_refresh_hz")
	for o: Node2D in main.view.overlays:
		_add_overlay_toggle(o)
	main.view.overlay_registered.connect(_add_overlay_toggle)
	_overlay_row.add_child(VSeparator.new())
	_add_toggle(_overlay_row, "Season tint", main.view.flora_overlay.season_tint_enabled,
			func(on: bool) -> void: main.view.flora_overlay.set_season_tint(on))
	_add_toggle(_overlay_row, "Day/night", main.view.daynight_enabled,
			func(on: bool) -> void: main.view.daynight_enabled = on)
	var n: int = main.core.spike_count()
	_spike_choice.select(maxi(0, SPIKE_CHOICES.find(n)))
	_bind_brush(main)
	_last_time_usec = Time.get_ticks_usec()


func _bind_brush(main: Node) -> void:
	var brush: Node2D = main.view.brush
	var flora: RefCounted = main.core.flora
	_brush_choice.clear()
	_brush_choice.add_item("off")
	_brush_choice.add_item("harvest")
	for t in range(1, flora.count() + 1):
		_brush_choice.add_item("plant " + flora.names[t])
	_brush_choice.select(0)
	_brush_choice.item_selected.connect(func(i: int) -> void:
		if i == 0:
			brush.mode = brush.Mode.OFF
		elif i == 1:
			brush.mode = brush.Mode.HARVEST
		else:
			brush.mode = brush.Mode.PLANT
			brush.plant_type = i - 1)
	_brush_radius.value = brush.radius
	_brush_radius.value_changed.connect(func(v: float) -> void: brush.radius = int(v))


func show_speed(multiplier: float) -> void:
	if _speed_buttons.has(multiplier):
		(_speed_buttons[multiplier] as Button).button_pressed = true


func _add_overlay_toggle(o: Node2D) -> void:
	_add_toggle(_overlay_row, o.display_name, o.visible, func(on: bool) -> void: o.visible = on)


func _add_toggle(parent: Control, text: String, on: bool, action: Callable) -> void:
	var cb := CheckBox.new()
	cb.text = text
	cb.button_pressed = on
	cb.toggled.connect(action)
	parent.add_child(cb)


func _add_button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)


func _add_label(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	parent.add_child(l)


func _process(delta: float) -> void:
	if _main == null or _main.runner == null:
		return
	if _status_until > 0 and Time.get_ticks_msec() > _status_until:
		set_status("")
	_update_cell()
	_refresh_timer += delta
	if _refresh_timer < _refresh_interval:
		return
	_refresh_timer = 0.0
	var s: Dictionary = _main.runner.stats()
	var now := Time.get_ticks_usec()
	var ticks: int = s["ticks_run"]
	_tps = (ticks - _last_ticks) / maxf((now - _last_time_usec) / 1e6, 1e-6)
	_last_ticks = ticks
	_last_time_usec = now
	var speed: float = s["speed"]
	var speed_text := "paused" if speed == 0.0 else ("max" if speed < 0.0 else "%dx" % int(speed))
	var time: RefCounted = _main.core.time
	_stats.text = "%s   tick %d   %s   %.1f ticks/s   tick %.1f ms   render %d fps   zoom %.2f px/cell   %dx%d   %d spike entities" % [
			time.describe(s["tick"]), s["tick"], speed_text, _tps, s["tick_ms_ema"],
			Engine.get_frames_per_second(), _main.view.camera.zoom.x, _main.core.world.width,
			_main.core.world.height, _main.core.spike_count()]
	if _probe_cell >= 0:
		_main.runner.request_probe(_probe_cell)  # refresh values under a still cursor


func _update_cell() -> void:
	var c: Vector2i = _main.view.cell_under_mouse()
	var w: RefCounted = _main.core.world
	if not w.in_bounds(c.x, c.y):
		_probe_cell = -1
		_cell.text = ""
		return
	var i: int = w.index(c.x, c.y)
	if i != _probe_cell:
		_probe_cell = i
		_main.runner.request_probe(i)
	var p: Dictionary = _main.runner.probe_result()
	if p.get("cell", -1) != i:
		return
	var plant: String = "%s (biomass %d)" % [p["flora"], p["biomass"]] if p["flora"] != "" else "no plant"
	_cell.text = "cell (%d, %d)   %s   fertility %d   moisture %d   %s   occupant %d" % [
			p["x"], p["y"], p["substrate"], p["fertility"], p["moisture"], plant, p["occupant"]]
