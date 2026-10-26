## Entity inspector: click an entity to see its state, genome, memory, current action and the
## utility scores of its last decision (the chosen action is the highest score). Data comes
## from SimRunner.request_entity_probe, answered on the sim thread between ticks.
extends CanvasLayer

const PANEL_WIDTH := 380
const MARGIN := 8
const TOP := 130

var selected_slot := -1
var selected_generation := -1
## Last data shown ({} when nothing is selected or the entity died).
var data := {}
## From the sim's time system (set by main).
var ticks_per_day := 1.0
var ticks_per_hour := 1.0

var _panel := PanelContainer.new()
var _text := RichTextLabel.new()


func _ready() -> void:
	layer = 2
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -PANEL_WIDTH - MARGIN
	_panel.offset_right = -MARGIN
	_panel.offset_top = TOP
	_panel.offset_bottom = TOP + 640
	_panel.visible = false
	add_child(_panel)
	_text.bbcode_enabled = true
	_text.fit_content = false
	_text.scroll_active = true
	_text.custom_minimum_size = Vector2(PANEL_WIDTH - 16, 620)
	_panel.add_child(_text)


func select(slot: int, generation: int) -> void:
	selected_slot = slot
	selected_generation = generation
	data = {}
	_panel.visible = slot >= 0
	_text.text = "[i]loading...[/i]"


func clear() -> void:
	select(-1, -1)


func show_data(d: Dictionary) -> void:
	if selected_slot < 0:
		return
	if d.is_empty():
		data = {}
		_text.text = "[b]Entity %d[/b] (generation %d)\n\n[i]no longer alive[/i]" % [selected_slot + 1, selected_generation]
		return
	data = d
	var lines := PackedStringArray()
	lines.append("[b]Entity %d[/b]  slot %d, generation %d" % [d["id"], d["slot"], d["generation"]])
	lines.append("%s, age %.1f days, at (%d, %d)" % [d["sex"], d["age_ticks"] / ticks_per_day, d["x"], d["y"]])
	lines.append("energy [b]%.0f[/b] / %.0f   hp %.0f   meals %d" % [d["energy"], d["max_energy"], d["hp"], d["meals"]])
	var target: Array = d["target"]
	lines.append("action [b]%s[/b]%s%s" % [d["action"], (" -> (%d, %d)" % [target[0], target[1]]) if target.size() == 2 else "",
			"" if d["decided"] == d["action"] else "  (decided %s; ended or given up since)" % d["decided"]])
	lines.append("carrying %s   neighbours in sight %d   nearest water %s   stuck %d" % [
			"corpse %d" % d["carrying"] if d["carrying"] >= 0 else "nothing", d["neighbors"],
			"%d cells" % d["water_dist"] if d["water_dist"] >= 0 else "not in sight", d["stuck"]])
	lines.append("\n[b]Utility scores[/b] (last decision; the highest is chosen)")
	var sc: Dictionary = d["scores"]
	var names: Array = sc.keys()
	names.sort_custom(func(a: String, b: String) -> bool: return sc[a] > sc[b])
	for n: String in names:
		if n == "none":
			continue
		var mark := "[color=#7fe07f]>[/color] " if n == d["decided"] else "   "
		lines.append("%s%-16s %.3f" % [mark, n, sc[n]])
	var costs: Dictionary = d["costs"]
	lines.append("\n[b]Derived costs[/b] (from the genome below; not genes)")
	lines.append("  %-20s %.3f /tick (resting %.3f)" % ["base_burn", costs["base_burn"], costs["rest_burn"]])
	lines.append("  %-20s %.3f /tick" % ["sense_burn", costs["sense_burn"]])
	lines.append("  %-20s %.3f /cell on cost-1 terrain" % ["move_cost", costs["move_cost"]])
	lines.append("[b]Genome[/b]")
	var g: Dictionary = d["genome"]
	for k: String in g:
		lines.append("  %-20s %.3f" % [k, g[k]])
	lines.append("\n[b]Memory[/b]")
	var mem: Array = d["memory"]
	if mem.is_empty():
		lines.append("  (empty)")
	for m: Dictionary in mem:
		lines.append("  %s at (%d, %d), %.1f h ago" % [m["kind"], m["x"], m["y"], m["age_ticks"] / ticks_per_hour])
	_text.text = "[code]" + "\n".join(lines) + "[/code]"
