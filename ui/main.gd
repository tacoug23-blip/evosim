## App entry. Builds the sim from the registry, starts the threaded runner, and wires the
## world view and HUD.
##
## Command line (after `--`):
##   --preset=NAME --seed=N --size=N --speed=pause|1|2|5|20|max
##   --founders[=GROUPS]                         spawn founder groups at start (founders.* params)
##   --set=param.id=value                        (repeatable)
##   --autotest-brush                            plant + harvest through the debug brush, probe, screenshot
##   --autotest-render[=SECONDS] [--no-vsync]    scripted pan/zoom sweep, prints frame-time
##                                               stats, saves screenshots, then quits
##   --autotest-inspect                          select an entity through the click path, check
##                                               the inspector, colour modes, founders clear/spawn
##     diagnostics for the autotest: --hold-zoom=Z (static view, 0 = fit), --sweep=pan|zoom,
##     --no-hud, --hide-overlays
extends Node

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SimRunner := preload("res://sim/core/sim_runner.gd")
const SaveLoad := preload("res://sim/io/save_load.gd")
const WorldView := preload("res://ui/world_view.gd")
const Hud := preload("res://ui/hud.gd")
const Inspector := preload("res://ui/inspector.gd")

const SAVE_PATH := "user://saves/quicksave.evosave"
const KEY_SPEEDS := {KEY_1: 1.0, KEY_2: 2.0, KEY_3: 5.0, KEY_4: 20.0, KEY_5: SimRunner.SPEED_MAX}
const SHOT_DIR := "res://batch_output/"
## Render autotest: deepest zoom of the sweep, in screen pixels per cell.
const AUTOTEST_MAX_ZOOM := 24.0
const AUTOTEST_WARMUP_FRAMES := 10
## Brush autotest layout: disc radius, gap between the plant and harvest discs, camera zoom,
## and how many frames to wait for the sim thread and texture uploads.
const AUTOTEST_BRUSH_RADIUS := 6
const AUTOTEST_BRUSH_GAP := 20
const AUTOTEST_BRUSH_ZOOM := 16.0
const AUTOTEST_SETTLE_FRAMES := 90

var params: Registry
var core: SimCore
var runner: SimRunner
var view: WorldView
var hud: Hud
var inspector: Inspector

var _args := {}
var _resume_speed := 1.0
var _snapshot_interval := 0.1
var _snapshot_timer := 0.0
var _layer_interval := 1.0
var _layer_timer := 0.0
var _inspect_timer := 0.0
var _pending_select := -1
## Last snapshot handed to the view (autotests read entity positions from it).
var _last_snap := {}


func _ready() -> void:
	_args = _parse_args()
	params = Registry.new()
	if not params.load_file():
		_fatal("parameter registry failed to load: " + "; ".join(params.errors))
		return
	if _args.has("preset") and not params.apply_preset(_args["preset"]):
		_fatal("unknown preset " + _args["preset"])
		return
	if _args.has("seed"):
		params.set_value("world.seed", int(_args["seed"]))
	if _args.has("size"):
		params.set_value("world.width", int(_args["size"]))
		params.set_value("world.height", int(_args["size"]))
	for kv: String in _args["set"]:
		var parts := kv.split("=", true, 1)
		params.set_value(parts[0], str_to_var(parts[1]))
	if params.get_int("sim.worker_threads") == 0:
		# Sim phases that use every core starve the render thread and cause frame hitches.
		params.set_value("sim.worker_threads", maxi(1,
				OS.get_processor_count() - params.get_int("ui.render_reserved_threads")))

	hud = Hud.new()
	hud.visible = not _args.has("no-hud")
	add_child(hud)
	hud.set_status("Generating %dx%d world (seed %d)..." % [params.get_int("world.width"),
			params.get_int("world.height"), params.get_int("world.seed")])
	await get_tree().process_frame
	await get_tree().process_frame

	core = SimCore.new()
	if not core.init_new(params):
		_fatal(core.error)
		return
	if _args.has("founders"):
		core.spawn_founders({} if _args["founders"] == "true" else {"groups": int(_args["founders"])})

	view = WorldView.new()
	add_child(view)
	move_child(view, 0)
	view.setup(core, params)
	if _args.has("hide-overlays"):  # diagnostics: draw nothing but the clear color
		for o in view.overlays:
			o.visible = false

	runner = SimRunner.new()
	runner.start(core, params.get_float("sim.base_tps"))
	view.brush.runner = runner
	inspector = Inspector.new()
	add_child(inspector)
	inspector.ticks_per_day = core.time.ticks_per_day
	inspector.ticks_per_hour = core.time.ticks_per_hour
	view.cell_clicked.connect(_on_cell_clicked)
	_snapshot_interval = 1.0 / params.get_float("ui.entity_snapshot_hz")
	_layer_interval = 1.0 / params.get_float("ui.layer_refresh_hz")
	runner.request_snapshot()
	hud.bind(self)
	hud.set_status("Terrain generated in %.1f s" % (core.terrain_stats["total_ms"] / 1000.0), 4.0)
	set_speed(_parse_speed(_args.get("speed", "pause")))

	if _args.has("autotest-render"):
		_autotest_render()
	elif _args.has("autotest-brush"):
		_autotest_brush()
	elif _args.has("autotest-inspect"):
		_autotest_inspect()


func set_speed(multiplier: float) -> void:
	if multiplier != SimRunner.SPEED_PAUSED:
		_resume_speed = multiplier
	runner.set_speed(multiplier)
	hud.show_speed(multiplier)


func toggle_pause() -> void:
	set_speed(_resume_speed if runner.get_speed() == SimRunner.SPEED_PAUSED else SimRunner.SPEED_PAUSED)


func step_once() -> void:
	runner.step_once()
	hud.show_speed(SimRunner.SPEED_PAUSED)


func quick_save() -> void:
	hud.set_status("Saving...")
	await get_tree().process_frame
	runner.hold()
	var t0 := Time.get_ticks_msec()
	var err := SaveLoad.save(core, SAVE_PATH)
	runner.release()
	if err == OK:
		hud.set_status("Saved tick %d to %s (%.1f s)" % [core.tick,
				ProjectSettings.globalize_path(SAVE_PATH), (Time.get_ticks_msec() - t0) / 1000.0], 6.0)
	else:
		hud.set_status("Save failed: %s" % error_string(err), 6.0)


func quick_load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		hud.set_status("No quicksave yet", 4.0)
		return
	hud.set_status("Loading...")
	await get_tree().process_frame
	runner.hold()
	var res := SaveLoad.load_file(SAVE_PATH)
	if res["core"] == null:
		runner.release()
		hud.set_status("Load failed: %s" % res["error"], 6.0)
		return
	if res["core"].world.width != core.world.width or res["core"].world.height != core.world.height:
		# The view was built for the old map size; rebuilding the camera is not worth it here.
		runner.release()
		hud.set_status("Load failed: save is %dx%d, running world is %dx%d" % [
				res["core"].world.width, res["core"].world.height, core.world.width, core.world.height], 6.0)
		return
	core = res["core"]
	params = core.params
	view.rebind(core)
	runner.release(core)
	runner.request_snapshot()
	set_speed(SimRunner.SPEED_PAUSED)
	hud.set_status("Loaded tick %d" % core.tick, 4.0)


## Spawn founder groups (founders.* params) between ticks, on the sim thread.
func spawn_founders() -> void:
	runner.submit(func(c: RefCounted) -> void: c.spawn_founders())
	runner.request_snapshot()
	hud.set_status("Spawning founder groups", 3.0)


## Remove every entity (no corpses) between ticks.
func clear_entities() -> void:
	runner.submit(func(c: RefCounted) -> void: c.entities.clear())
	runner.request_snapshot()
	inspector.clear()
	view.selection.hide_ring()


func _on_cell_clicked(cell: Vector2i) -> void:
	if not core.world.in_bounds(cell.x, cell.y):
		return
	_pending_select = core.world.index(cell.x, cell.y)
	runner.request_probe(_pending_select)


## Pick up the entity under a clicked cell once its probe arrives; keep the inspector fresh.
func _update_inspector(refresh: bool) -> void:
	if _pending_select >= 0:
		var p: Dictionary = runner.probe_result()
		if p.get("cell", -1) == _pending_select:
			_pending_select = -1
			if p["occupant"] > 0:
				inspector.select(p["occupant"] - 1, p["occupant_generation"])
				runner.request_entity_probe(inspector.selected_slot, inspector.selected_generation)
			else:
				inspector.clear()
				view.selection.hide_ring()
	if inspector.selected_slot < 0:
		return
	if refresh:
		runner.request_entity_probe(inspector.selected_slot, inspector.selected_generation)
	var er: Dictionary = runner.entity_probe_result()
	if er.get("requested", Vector2i(-2, -2)) != Vector2i(inspector.selected_slot, inspector.selected_generation):
		return
	var d := er.duplicate()
	d.erase("requested")
	inspector.show_data(d)
	if d.is_empty():
		view.selection.hide_ring()
	else:
		view.selection.show_at(Vector2i(d["x"], d["y"]))


func _process(delta: float) -> void:
	if runner == null:
		return
	_snapshot_timer += delta
	if _snapshot_timer >= _snapshot_interval:
		_snapshot_timer = 0.0
		runner.request_snapshot()
	# Dynamic layers (flora, fertility, moisture) are 16 MB each at 4096x4096: copied less often,
	# and only the ones a visible overlay needs.
	_layer_timer += delta
	if _layer_timer >= _layer_interval:
		_layer_timer = 0.0
		var layers := view.needed_layers()
		if not layers.is_empty():
			runner.request_snapshot(layers)
	var snap := runner.take_snapshot()
	if not snap.is_empty():
		view.on_snapshot(snap)
		_last_snap = snap
	view.set_daylight(core.time.daylight(runner.stats()["tick"]))
	_inspect_timer += delta
	var refresh := _inspect_timer >= 1.0 / params.get_float("ui.hud_refresh_hz")
	if refresh:
		_inspect_timer = 0.0
	_update_inspector(refresh)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if runner == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_SPACE:
		toggle_pause()
	elif KEY_SPEEDS.has(k.keycode):
		set_speed(KEY_SPEEDS[k.keycode])
	elif k.keycode == KEY_N or k.keycode == KEY_PERIOD:
		step_once()
	elif k.keycode == KEY_F5:
		quick_save()
	elif k.keycode == KEY_F9:
		quick_load()


func _exit_tree() -> void:
	if runner != null:
		runner.stop()


## Sweeps the camera from fit-to-map down to AUTOTEST_MAX_ZOOM and back while orbiting the
## map, records wall-clock frame intervals, saves three screenshots, prints a summary, quits.
func _autotest_render() -> void:
	var seconds: float = float(_args["autotest-render"]) if _args["autotest-render"] != "true" else 10.0
	if _args.has("no-vsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_move_to_foreground()
	for i in AUTOTEST_WARMUP_FRAMES:
		await get_tree().process_frame
	var cam := view.camera
	var fit := cam.fit_zoom()
	var size := Vector2(core.world.width, core.world.height)
	var shots := {0.0: "overview", 0.3: "mid", 0.5: "close"}
	var frame_ms := PackedFloat64Array()
	var t_start := Time.get_ticks_usec()
	var t_prev := t_start
	var elapsed := 0.0
	var focused_at_start := DisplayServer.window_is_focused()
	var hold_zoom := float(_args.get("hold-zoom", "0"))
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	var gpu_ms := PackedFloat64Array()
	var cpu_ms := PackedFloat64Array()
	while elapsed < seconds:
		var phase := elapsed / seconds
		var z := fit * pow(AUTOTEST_MAX_ZOOM / fit, sin(phase * PI))
		var orbit := Vector2(cos(phase * TAU * 2.0), sin(phase * TAU * 2.0)) * size * 0.3
		if _args.get("sweep", "") == "pan":
			z = fit * 4.0
		elif _args.get("sweep", "") == "zoom":
			orbit = Vector2.ZERO
		if hold_zoom > 0.0:  # --hold-zoom=Z (0 = fit): fixed view, isolates cost per zoom level
			z = hold_zoom
			orbit = Vector2.ZERO
		elif _args.has("hold-zoom"):
			z = fit
			orbit = Vector2.ZERO
		cam.set_view(size / 2.0 + orbit, z)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var shot_taken := false
		for key: float in shots.keys():
			if phase >= key:
				await RenderingServer.frame_post_draw
				var path := SHOT_DIR + "render_%s.png" % shots[key]
				get_viewport().get_texture().get_image().save_png(path)
				print("screenshot %s" % ProjectSettings.globalize_path(path))
				shots.erase(key)
				shot_taken = true
				now = Time.get_ticks_usec()
		if not shot_taken:  # readback stalls the GPU; keep those frames out of the stats
			frame_ms.append((now - t_prev) / 1000.0)
			gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
			cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
		t_prev = now
		elapsed = (now - t_start) / 1e6
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var total := 0.0
	for v in frame_ms:
		total += v
	var n := sorted.size()
	var slow := 0
	for v in frame_ms:
		if v > 1000.0 / 55.0:
			slow += 1
	print("RENDER_TEST world=%dx%d frames=%d avg_fps=%.1f p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms frames_over_18ms=%d vsync=%s entities=%d sim_speed=%s ticks_during_test=%d" % [
			core.world.width, core.world.height, n, 1000.0 * n / total, sorted[n / 2],
			sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1], slow,
			"off" if _args.has("no-vsync") else "on", runner.stats()["entities"], _args.get("speed", "pause"),
			runner.stats()["ticks_run"]])
	print("RENDER_FOCUS start=%s end=%s" % [focused_at_start, DisplayServer.window_is_focused()])
	print("RENDER_BREAKDOWN gpu_render p50=%.2fms p95=%.2fms  cpu_render p50=%.2fms p95=%.2fms" % [
			_pct(gpu_ms, 0.5), _pct(gpu_ms, 0.95), _pct(cpu_ms, 0.5), _pct(cpu_ms, 0.95)])
	get_tree().quit()


## Scripted brush check: through the real brush tool, plants trees in one disc and harvests a
## second disc, waits for the overlay refresh, prints probes of both centres, saves a
## screenshot, quits. Calls the brush directly instead of moving the OS cursor.
func _autotest_brush() -> void:
	for i in AUTOTEST_WARMUP_FRAMES:
		await get_tree().process_frame
	var w: RefCounted = core.world
	var soil: int = core.substrates.id_of("soil")
	var plant_at := Vector2i(-1, -1)
	var center := Vector2i(w.width / 2, w.height / 2)
	# Substrate never changes after generation, so reading it here is safe.
	for r in range(0, w.width / 2):
		for dx in range(-r, r + 1):
			var c := center + Vector2i(dx, -r)
			var c2 := c + Vector2i(AUTOTEST_BRUSH_GAP, 0)
			if plant_at.x < 0 and w.in_bounds(c2.x, c2.y) and w.substrate[w.index(c.x, c.y)] == soil \
					and w.substrate[w.index(c2.x, c2.y)] == soil:
				plant_at = c
		if plant_at.x >= 0:
			break
	var harvest_at := plant_at + Vector2i(AUTOTEST_BRUSH_GAP, 0)
	view.camera.set_view(Vector2(plant_at) + Vector2(AUTOTEST_BRUSH_GAP / 2.0, 0.0), AUTOTEST_BRUSH_ZOOM)
	var brush: Node2D = view.brush
	brush.radius = AUTOTEST_BRUSH_RADIUS
	brush.mode = brush.Mode.PLANT
	brush.plant_type = core.flora.id_of("tree")
	brush.paint_at(plant_at)
	brush.mode = brush.Mode.HARVEST
	brush.paint_at(harvest_at)
	brush.mode = brush.Mode.OFF
	runner.request_snapshot(view.needed_layers())
	for i in AUTOTEST_SETTLE_FRAMES:
		await get_tree().process_frame
	for cell: Vector2i in [plant_at, harvest_at]:
		runner.request_probe(w.index(cell.x, cell.y))
		var p := {}
		for i in AUTOTEST_SETTLE_FRAMES:
			await get_tree().process_frame
			p = runner.probe_result()
			if p.get("cell", -1) == w.index(cell.x, cell.y):
				break
		print("BRUSH_TEST %s at %s: %s" % ["plant tree" if cell == plant_at else "harvest",
				cell, ("%s biomass %d" % [p["flora"], p["biomass"]]) if p.get("flora", "") != "" else "no plant"])
	await RenderingServer.frame_post_draw
	var path := SHOT_DIR + "brush_test.png"
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot %s" % ProjectSettings.globalize_path(path))
	get_tree().quit()


## Scripted inspector check: lets founders run, pauses, picks a live entity from the latest
## snapshot and sends its cell through the same signal a mouse click emits, then checks the
## inspector against its utility scores, screenshots both colour modes, follows the entity for a
## few seconds, and finally clears and respawns founders through the HUD actions.
func _autotest_inspect() -> void:
	for i in AUTOTEST_WARMUP_FRAMES:
		await get_tree().process_frame
	if runner.stats()["entities"] == 0:
		spawn_founders()
	set_speed(20.0)
	for i in AUTOTEST_SETTLE_FRAMES * 2:
		await get_tree().process_frame
	set_speed(SimRunner.SPEED_PAUSED)
	_last_snap = {}
	runner.request_snapshot()
	while _last_snap.is_empty():
		await get_tree().process_frame
	var xs: PackedInt32Array = _last_snap["entity_x"].to_int32_array()
	var ys: PackedInt32Array = _last_snap["entity_y"].to_int32_array()
	var cell := Vector2i(-1, -1)
	for i in xs.size():
		if xs[i] >= 0:
			cell = Vector2i(xs[i], ys[i])
			break
	if cell.x < 0:
		print("INSPECT_TEST FAIL no live entity in the snapshot")
		get_tree().quit(1)
		return
	view.camera.set_view(Vector2(cell) + Vector2(0.5, 0.5), AUTOTEST_BRUSH_ZOOM)
	view.cell_clicked.emit(cell)
	var ok := await _await_inspector()
	var d := inspector.data
	var best := ""
	var best_score := 0.0
	if ok:
		for n: String in d["scores"]:
			if n != "none" and d["scores"][n] > best_score:
				best_score = d["scores"][n]
				best = n
	ok = ok and best == d["decided"] and Vector2i(d["x"], d["y"]) == cell
	print("INSPECT_TEST %s clicked %s: %s" % ["PASS" if ok else "FAIL", cell, "entity %d gen %d, action %s, decided %s, top score %s %.3f, energy %.0f/%.0f, %d neighbours, costs base %.3f rest %.3f sense %.3f move %.3f" % [
			d["id"], d["generation"], d["action"], d["decided"], best, best_score, d["energy"], d["max_energy"],
			d["neighbors"], d["costs"]["base_burn"], d["costs"]["rest_burn"], d["costs"]["sense_burn"], d["costs"]["move_cost"]]
			if not d.is_empty() else "inspector empty"])
	var females := 0
	for i in xs.size():
		if xs[i] >= 0 and _last_snap["entity_sex"][i] == 1:
			females += 1
	print("INSPECT_SEXES %d female of %d" % [females, _last_snap["entity_count"]])
	for mode in 2:
		hud.choose_color_mode(mode)
		for i in 10:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := SHOT_DIR + "inspect_%s.png" % ["energy", "sex"][mode]
		get_viewport().get_texture().get_image().save_png(path)
		print("screenshot %s" % ProjectSettings.globalize_path(path))
	hud.choose_color_mode(0)
	# Follow it: the panel refreshes from new probes while the sim runs.
	var age0: float = d.get("age_ticks", 0)
	set_speed(20.0)
	for i in AUTOTEST_SETTLE_FRAMES * 2:
		await get_tree().process_frame
	set_speed(SimRunner.SPEED_PAUSED)
	await _await_inspector()
	var d2 := inspector.data
	print("INSPECT_FOLLOW %s: age %d -> %d ticks, now %s at (%d, %d)" % ["PASS" if d2.get("age_ticks", 0) > age0 else "FAIL",
			age0, d2.get("age_ticks", 0), d2.get("action", "?"), d2.get("x", -1), d2.get("y", -1)])
	var before: int = runner.stats()["entities"]
	clear_entities()
	await _await_stat("entities", func(v: int) -> bool: return v == 0)
	var cleared: int = runner.stats()["entities"]
	spawn_founders()
	await _await_stat("entities", func(v: int) -> bool: return v > 0)
	var respawned: int = runner.stats()["entities"]
	print("FOUNDERS_TEST %s: %d entities -> clear -> %d -> spawn -> %d" % [
			"PASS" if cleared == 0 and respawned > 0 else "FAIL", before, cleared, respawned])
	get_tree().quit()


## Wait (bounded) for the inspector to show data for the selected entity.
func _await_inspector() -> bool:
	inspector.data = {}
	runner.request_entity_probe(inspector.selected_slot, inspector.selected_generation)
	for i in AUTOTEST_SETTLE_FRAMES:
		await get_tree().process_frame
		if not inspector.data.is_empty():
			return true
	return false


func _await_stat(key: String, done: Callable) -> void:
	for i in AUTOTEST_SETTLE_FRAMES:
		await get_tree().process_frame
		if done.call(runner.stats()[key]):
			return


static func _pct(values: PackedFloat64Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	return s[mini(s.size() - 1, int(s.size() * q))]


func _parse_speed(text: String) -> float:
	match text:
		"pause", "0":
			return SimRunner.SPEED_PAUSED
		"max":
			return SimRunner.SPEED_MAX
	return maxf(float(text), 0.0)


func _parse_args() -> Dictionary:
	var out := {"set": []}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv[0] == "set" and kv.size() == 2:
			out["set"].append(kv[1])
		else:
			out[kv[0]] = kv[1] if kv.size() == 2 else "true"
	return out


func _fatal(message: String) -> void:
	push_error(message)
	if hud != null:
		hud.set_status("ERROR: " + message)
