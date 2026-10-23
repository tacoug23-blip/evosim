## Top bar: speed controls, save/load, spike spawner, overlay toggles, live stats, and the
## cell under the cursor. Talks to main.gd; never touches sim state directly.
extends CanvasLayer

const SPIKE_CHOICES := [0, 1000, 10000, 50000, 100000]

var _main: Node
var _status: Label
var _stats: Label
var _cell: Label
var _overlay_row: HBoxContainer
var _speed_buttons := {}
var _spike_choice: OptionButton
var _refresh_interval := 0.25
var _refresh_timer := 0.0
var _last_ticks := 0
var _last_time_usec := 0
var _tps := 0.0
var _status_until := 0


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
	var spike_label := Label.new()
	spike_label.text = "Spike:"
	row.add_child(spike_label)
	_spike_choice = OptionButton.new()
	for n: int in SPIKE_CHOICES:
		_spike_choice.add_item(str(n) if n > 0 else "none")
	row.add_child(_spike_choice)
	_add_button(row, "Spawn", func() -> void: _main.respawn_spike(SPIKE_CHOICES[_spike_choice.selected]))
	row.add_child(VSeparator.new())
	_status = Label.new()
	row.add_child(_status)

	_overlay_row = HBoxContainer.new()
	col.add_child(_overlay_row)
	var ov_label := Label.new()
	ov_label.text = "Overlays:"
	_overlay_row.add_child(ov_label)

	_stats = Label.new()
	col.add_child(_stats)
	_cell = Label.new()
	col.add_child(_cell)

	var help := Label.new()
	help.text = "Drag: pan   Wheel: zoom   WASD/arrows: pan   Home: fit   Space: pause   1-4: speed   5: max   N: step   F5/F9: save/load"
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
	var n: int = main.core.spike_count()
	_spike_choice.select(maxi(0, SPIKE_CHOICES.find(n)))
	_last_time_usec = Time.get_ticks_usec()


func show_speed(multiplier: float) -> void:
	if _speed_buttons.has(multiplier):
		(_speed_buttons[multiplier] as Button).button_pressed = true


func _add_overlay_toggle(o: Node2D) -> void:
	var cb := CheckBox.new()
	cb.text = o.display_name
	cb.button_pressed = o.visible
	cb.toggled.connect(func(on: bool) -> void: o.visible = on)
	_overlay_row.add_child(cb)


func _add_button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)


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
	_stats.text = "tick %d   %s   %.1f ticks/s   tick %.1f ms   render %d fps   zoom %.2f px/cell   %dx%d   %d spike entities" % [
			s["tick"], speed_text, _tps, s["tick_ms_ema"], Engine.get_frames_per_second(),
			_main.view.camera.zoom.x, _main.core.world.width, _main.core.world.height,
			_main.core.spike_count()]


func _update_cell() -> void:
	var c: Vector2i = _main.view.cell_under_mouse()
	var w: RefCounted = _main.core.world
	if not w.in_bounds(c.x, c.y):
		_cell.text = ""
		return
	var i: int = w.index(c.x, c.y)
	# Reads of static terrain layers; occupancy may be mid-tick and is display-only.
	_cell.text = "cell (%d, %d)   %s   fertility %d   moisture %d   occupant %d" % [
			c.x, c.y, _main.core.substrates.names[w.substrate[i]], w.fertility[i],
			w.moisture[i], w.occupancy[i]]
