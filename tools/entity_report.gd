## Phase 3 acceptance scenarios on the default map.
##   abundant  grow flora for --flora-years, spawn 5,000 founders (20 groups of 250), run
##             --days; log survival, energy, bites and meals per day, deaths by cause and
##             substrate, meals by item. Pass: >= 95% survive and >= 90% of survivors ate 3+
##             meals (they keep cycling through food).
##   low       the same, with the grown flora thinned to --low-share (10%) of its plants:
##             survival, deaths by cause and substrate, meals by item, and fertility around
##             corpse sites (corpses that fully decayed before the end) against control land
##             over the same days. Informational: no pass threshold.
##   scarce    clear all flora, spawn the same founders, run until they starve plus the corpse
##             decay time; log fertility around corpse sites against random control land cells.
##             Pass: everyone starves, corpses appear, and fertility at corpse sites rises.
## Writes CSV, SVG charts and a markdown summary.
##
##   godot --headless --path . --script res://tools/entity_report.gd -- [--scenario=all]
##       (all | abundant | low | scarce | both = abundant + scarce)
##       [--flora-years=2] [--days=60] [--founders=5000] [--low-share=0.1] [--out=res://batch_output/entities]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SvgChart := preload("res://tools/svg_chart.gd")

const GROUP_SIZE := 250
const SURVIVAL_PASS := 0.95
const MEALS_PASS := 0.9
const MEALS_MIN := 3
## Fertility is averaged over this Chebyshev radius around each site (matches the default
## corpse.spread_radius; read from params at run time).
const CONTROL_MIN_DIST := 12
## Death diagnostics: plant count radius, and how many survivors to sample.
const DIAG_RADIUS := 10
const DIAG_SAMPLE := 2000


func _initialize() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() == 2 else "true"
	var scenario: String = args.get("scenario", "all")
	var out_dir: String = args.get("out", "res://batch_output/entities")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var summary := PackedStringArray(["# Phase 3 entity scenarios", ""])
	var ok := true
	if scenario in ["abundant", "both", "all"]:
		ok = _abundant(args, out_dir, summary) and ok
	if scenario in ["low", "all"]:
		_low(args, out_dir, summary)
	if scenario in ["scarce", "both", "all"]:
		ok = _scarce(args, out_dir, summary) and ok
	var f := FileAccess.open(out_dir + "/entity_summary.md", FileAccess.WRITE)
	f.store_string("\n".join(summary) + "\n")
	f.close()
	print("\n".join(summary))
	print("wrote %s/" % ProjectSettings.globalize_path(out_dir))
	quit(0 if ok else 1)


func _new_core() -> RefCounted:
	var params := Registry.new()
	params.load_file()
	var core := SimCore.new()
	core.init_new(params)
	return core


func _spawn(core: RefCounted, n: int) -> int:
	@warning_ignore("integer_division")
	var groups := maxi(1, n / GROUP_SIZE)
	return core.spawn_founders({"groups": groups, "size_min": GROUP_SIZE, "size_max": GROUP_SIZE})["spawned"]


func _abundant(args: Dictionary, out_dir: String, summary: PackedStringArray) -> bool:
	var core := _new_core()
	var years := float(args.get("flora-years", 2))
	var days := int(args.get("days", 60))
	var t0 := Time.get_ticks_msec()
	for t in roundi(years * core.time.ticks_per_year):
		core.step()
	var plants := 0
	for t in range(1, core.flora.count() + 1):
		plants += core.env.coverage[t]
	var n0 := _spawn(core, int(args.get("founders", 5000)))
	print("abundant: flora grown %.1f years (%d plants) in %.0f s; %d founders at %s" % [years, plants,
			(Time.get_ticks_msec() - t0) / 1000.0, n0, core.time.describe(core.tick)])
	var e: RefCounted = core.entities
	var rows := []
	var deaths := {"cells": {}, "substrate": {}, "plants": 0, "n": 0}
	for day in days + 1:
		if day > 0:
			for k in core.time.ticks_per_day:
				core.step()
		_note_new_corpses(core, deaths)
		var mean := 0.0
		var lo := 1.0
		var meals_sum := 0
		for i in e.capacity:
			if e.alive[i] == 1:
				var share: float = float(e.energy[i]) / e.max_energy[i]
				mean += share
				lo = minf(lo, share)
				meals_sum += e.meals[i]
		var alive: int = e.count
		rows.append({"day": day, "alive": alive, "deaths": e.deaths_by_cause[0], "bites": e.bites,
				"mean_energy": mean / maxi(alive, 1), "min_energy": lo if alive > 0 else 0.0,
				"meals_mean": float(meals_sum) / maxi(alive, 1), "time": core.time.describe(core.tick)})
		if day % 10 == 0:
			var r: Dictionary = rows[-1]
			print("  day %3d  alive %d  deaths %d  energy mean %.2f min %.2f  meals/entity %.1f  [%s]" % [
					day, r["alive"], r["deaths"], r["mean_energy"], r["min_energy"], r["meals_mean"], r["time"]])
	var cycled := 0
	var meal_hist := {}
	for i in e.capacity:
		if e.alive[i] == 1:
			if e.meals[i] >= MEALS_MIN:
				cycled += 1
			var m: int = mini(e.meals[i], 10)
			meal_hist[m] = meal_hist.get(m, 0) + 1
	# Where did the dead die? Substrate under each corpse (noted the day it appeared, since corpses
	# decay), and plants nearby then vs near survivors at the end.
	var alive_plants := 0
	var alive_seen := 0
	for i in e.capacity:
		if e.alive[i] == 1 and alive_seen < DIAG_SAMPLE:
			alive_plants += _plants_near(core, e.y[i] * core.world.width + e.x[i], DIAG_RADIUS)
			alive_seen += 1
	var survival := float(e.count) / maxi(n0, 1)
	var cycled_share := float(cycled) / maxi(e.count, 1)
	var pass_a := survival >= SURVIVAL_PASS and cycled_share >= MEALS_PASS
	_write_csv(out_dir + "/abundant_daily.csv", rows, ["day", "alive", "deaths", "bites", "mean_energy", "min_energy", "meals_mean"])
	var labels := PackedStringArray()
	var alive_pct := PackedFloat64Array()
	var energy := PackedFloat64Array()
	var low := PackedFloat64Array()
	for r: Dictionary in rows:
		labels.append("day %d" % r["day"] if r["day"] % 10 == 0 else "")
		alive_pct.append(100.0 * r["alive"] / n0)
		energy.append(100.0 * r["mean_energy"])
		low.append(100.0 * r["min_energy"])
	_store(out_dir + "/abundant.svg", SvgChart.line_chart(
			"Abundant flora: %d founders over %d days" % [n0, days], "%", labels,
			[{"name": "alive (% of founders)", "color": Color(0.2, 0.45, 0.8), "values": alive_pct},
			{"name": "mean energy (% of max)", "color": Color(0.3, 0.7, 0.3), "values": energy},
			{"name": "lowest energy (% of max)", "color": Color(0.85, 0.35, 0.2), "values": low, "dash": true}], 1))
	summary.append("## Abundant flora")
	summary.append("")
	summary.append("- Flora grown %.1f years first (%d plants); %d founders (%d groups of %d) spawned at %s; ran %d days." % [
			years, plants, n0, n0 / GROUP_SIZE, GROUP_SIZE, rows[0]["time"], days])
	summary.append("- **Survival %.1f%%** (%d of %d; %d starved). Pass threshold %.0f%%." % [100.0 * survival, e.count, n0,
			e.deaths_by_cause[0], 100.0 * SURVIVAL_PASS])
	summary.append("- **%.1f%% of survivors ate %d+ meals** (pass threshold %.0f%%); mean %.1f meals per entity; %d bites in total." % [
			100.0 * cycled_share, MEALS_MIN, 100.0 * MEALS_PASS, rows[-1]["meals_mean"], e.bites])
	summary.append("- Mean energy stayed %.0f-%.0f%% of max after day 10." % [_min_after(rows, "mean_energy", 10) * 100.0,
			_max_after(rows, "mean_energy", 10) * 100.0])
	var hist_line := PackedStringArray()
	for m in range(0, 11):
		hist_line.append("%s: %d" % ["10+" if m == 10 else str(m), meal_hist.get(m, 0)])
	summary.append("- Meals per survivor: " + ", ".join(hist_line))
	summary.append("- Meals by item (share of all meals; share of energy eaten): %s." % _item_shares(core))
	summary.append("- Deaths by cause: %s." % _causes(e))
	if deaths["n"] > 0:
		summary.append("- Deaths by substrate under the corpse: %s; plants within %d cells of a new corpse %.1f on average, vs %.1f around survivors." % [
				deaths["substrate"], DIAG_RADIUS, float(deaths["plants"]) / deaths["n"], float(alive_plants) / maxi(alive_seen, 1)])
	summary.append("- **Result: %s**" % ("PASS" if pass_a else "FAIL"))
	summary.append("")
	return pass_a


## Record corpse cells not seen before: substrate and plants nearby, the day they appear.
func _note_new_corpses(core: RefCounted, deaths: Dictionary) -> void:
	var cells: Dictionary = deaths["cells"]
	for k in core.corpses.capacity:
		if core.corpses.alive[k] == 1 and core.corpses.cell[k] >= 0 and not cells.has(core.corpses.cell[k]):
			var c: int = core.corpses.cell[k]
			cells[c] = true
			var sname: String = core.substrates.names[core.world.substrate[c]]
			deaths["substrate"][sname] = deaths["substrate"].get(sname, 0) + 1
			deaths["plants"] += _plants_near(core, c, DIAG_RADIUS)
			deaths["n"] += 1


## "berries 41.0% / 52.3%, ..." for every item with meals: share of meals, share of energy.
func _item_shares(core: RefCounted) -> String:
	var e: RefCounted = core.entities
	var meals_total := 0
	var energy_total := 0
	for k in e.meals_by_item.size():
		meals_total += e.meals_by_item[k]
		energy_total += e.energy_eaten[k]
	var parts := PackedStringArray()
	for k in e.meals_by_item.size():
		if e.meals_by_item[k] > 0:
			parts.append("%s %.1f%% / %.1f%%" % ["corpses" if k == 0 else core.items.names[k],
					100.0 * e.meals_by_item[k] / maxi(meals_total, 1), 100.0 * e.energy_eaten[k] / maxi(energy_total, 1)])
	return ", ".join(parts) if not parts.is_empty() else "none"


static func _causes(e: RefCounted) -> String:
	var parts := PackedStringArray()
	for k in e.deaths_by_cause.size():
		parts.append("%s %d" % [e.CAUSE_NAMES[k], e.deaths_by_cause[k]])
	return ", ".join(parts)


func _low(args: Dictionary, out_dir: String, summary: PackedStringArray) -> void:
	var core := _new_core()
	var world: RefCounted = core.world
	var years := float(args.get("flora-years", 2))
	var share := float(args.get("low-share", 0.1))
	var days := int(args.get("days", 60))
	for t in roundi(years * core.time.ticks_per_year):
		core.step()
	var grown := _plant_count(core)
	# Keep each grown plant with probability `share` (fixed seed: the same thinning every run).
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for c in world.cell_count:
		if world.flora_type[c] != 0 and rng.randf() >= share:
			world.flora_type[c] = 0
			world.flora_biomass[c] = 0
	core.env.recount()
	var kept := _plant_count(core)
	var n0 := _spawn(core, int(args.get("founders", 5000)))
	print("low: flora grown %.1f years (%d plants), thinned to %d (%.1f%%); %d founders" % [years, grown, kept,
			100.0 * kept / maxi(grown, 1), n0])
	var e: RefCounted = core.entities
	var spread: int = core.params.get_int("corpse.spread_radius")
	var decay_days: float = core.params.get_float("corpse.decay_days")
	var candidates := _random_land(core, 4 * n0)
	# Fertility around every candidate control cell, every day (controls are chosen at the end,
	# once every corpse site is known, and compared over the same days as each site).
	var cand_daily: Array[PackedFloat32Array] = []
	var deaths := {"cells": {}, "substrate": {}, "plants": 0, "n": 0}
	var sites := PackedInt32Array()
	var site_day := PackedInt32Array()
	var site_start := PackedFloat64Array()
	var rows := []
	for day in days + 1:
		if day > 0:
			for k in core.time.ticks_per_day:
				core.step()
		for k in core.corpses.capacity:
			if core.corpses.alive[k] == 1 and core.corpses.cell[k] >= 0 and not deaths["cells"].has(core.corpses.cell[k]):
				sites.append(core.corpses.cell[k])
				site_day.append(day)
				site_start.append(_mean_around(world, PackedInt32Array([core.corpses.cell[k]]), spread))
		_note_new_corpses(core, deaths)
		var cf := PackedFloat32Array()
		for c in candidates:
			cf.append(_mean_around(world, PackedInt32Array([c]), spread))
		cand_daily.append(cf)
		var mean := 0.0
		var meals_sum := 0
		for i in e.capacity:
			if e.alive[i] == 1:
				mean += float(e.energy[i]) / e.max_energy[i]
				meals_sum += e.meals[i]
		rows.append({"day": day, "alive": e.count, "deaths": e.deaths_by_cause[0], "corpses": core.corpses.count,
				"mean_energy": mean / maxi(e.count, 1), "meals_mean": float(meals_sum) / maxi(e.count, 1)})
		if day % 10 == 0:
			print("  day %3d  alive %d  deaths %d  corpses %d" % [day, e.count, e.deaths_by_cause[0], core.corpses.count])
	# Fertility: sites whose corpse appeared early enough to have fully decayed by the end, against
	# control land (far from every site) over the same days.
	var site_blocks := _site_blocks(core, sites)
	var controls := PackedInt32Array()
	for k in candidates.size():
		if not _near_any(core, candidates[k], site_blocks):
			controls.append(k)
	var ctrl_mean := PackedFloat64Array()
	for day in days + 1:
		var s := 0.0
		for k in controls:
			s += cand_daily[day][k]
		ctrl_mean.append(s / maxi(controls.size(), 1))
	var cutoff := days - ceili(decay_days) - 1
	var n_sites := 0
	var site_change := 0.0
	var ctrl_change := 0.0
	for s in sites.size():
		if site_day[s] > cutoff:
			continue
		site_change += _mean_around(world, PackedInt32Array([sites[s]]), spread) - site_start[s]
		ctrl_change += ctrl_mean[days] - ctrl_mean[site_day[s]]
		n_sites += 1
	_write_csv(out_dir + "/low_daily.csv", rows, ["day", "alive", "deaths", "corpses", "mean_energy", "meals_mean"])
	var labels := PackedStringArray()
	var alive_pct := PackedFloat64Array()
	var energy := PackedFloat64Array()
	for r: Dictionary in rows:
		labels.append("day %d" % r["day"] if r["day"] % 10 == 0 else "")
		alive_pct.append(100.0 * r["alive"] / n0)
		energy.append(100.0 * r["mean_energy"])
	_store(out_dir + "/low.svg", SvgChart.line_chart(
			"Low flora (%.0f%% of grown plants): %d founders over %d days" % [100.0 * share, n0, days], "%", labels,
			[{"name": "alive (% of founders)", "color": Color(0.2, 0.45, 0.8), "values": alive_pct},
			{"name": "mean energy (% of max)", "color": Color(0.3, 0.7, 0.3), "values": energy}], 1))
	summary.append("## Low flora (%.0f%% of abundant)" % (100.0 * share))
	summary.append("")
	summary.append("- Flora grown %.1f years (%d plants), then thinned at random to %d (%.1f%%); %d founders spawned; ran %d days." % [
			years, grown, kept, 100.0 * kept / maxi(grown, 1), n0, days])
	summary.append("- **Survival %.1f%%** (%d of %d). Deaths by cause: %s." % [100.0 * e.count / maxi(n0, 1), e.count, n0, _causes(e)])
	if deaths["n"] > 0:
		summary.append("- Deaths by substrate under the corpse: %s; plants within %d cells of a new corpse %.1f on average." % [
				deaths["substrate"], DIAG_RADIUS, float(deaths["plants"]) / deaths["n"]])
	summary.append("- Meals by item (share of all meals; share of energy eaten): %s; mean %.1f meals per survivor." % [
			_item_shares(core), rows[-1]["meals_mean"]])
	if n_sites > 0:
		summary.append("- **Fertility around corpse sites** (%d sites whose corpse appeared by day %d, so fully decayed): %+.1f from appearance to day %d; control land (%d cells at least %d from any site) over the same days: %+.1f; **attributable to corpses %+.1f** fertility units." % [
				n_sites, cutoff, site_change / n_sites, days, controls.size(), CONTROL_MIN_DIST, ctrl_change / n_sites,
				(site_change - ctrl_change) / n_sites])
	else:
		summary.append("- No corpse appeared early enough to decay fully before day %d; no fertility comparison." % days)
	summary.append("")


func _plant_count(core: RefCounted) -> int:
	var n := 0
	for t in range(1, core.flora.count() + 1):
		n += core.env.coverage[t]
	return n


func _plants_near(core: RefCounted, c: int, radius: int) -> int:
	var w: int = core.world.width
	var h: int = core.world.height
	var cx := c % w
	@warning_ignore("integer_division")
	var cy := c / w
	var n := 0
	for y in range(maxi(0, cy - radius), mini(h - 1, cy + radius) + 1):
		for x in range(maxi(0, cx - radius), mini(w - 1, cx + radius) + 1):
			if core.world.flora_type[y * w + x] != 0:
				n += 1
	return n


func _scarce(args: Dictionary, out_dir: String, summary: PackedStringArray) -> bool:
	var core := _new_core()
	var world: RefCounted = core.world
	for c in world.cell_count:
		world.flora_type[c] = 0
		world.flora_biomass[c] = 0
	core.env.recount()
	var n0 := _spawn(core, int(args.get("founders", 5000)))
	print("scarce: no flora; %d founders" % n0)
	var e: RefCounted = core.entities
	var spread: int = core.params.get_int("corpse.spread_radius")
	var decay_days: float = core.params.get_float("corpse.decay_days")
	var sites := PackedInt32Array()
	# Per-site fertility around the site when its corpse first appeared (the baseline).
	var site_start_sum := 0.0
	# Control: random land, measured at the start and at the end.
	var candidates := _random_land(core, 4 * n0)
	var candidate_start := PackedFloat64Array()
	for c in candidates:
		candidate_start.append(_mean_around(world, PackedInt32Array([c]), spread))
	var site_set := {}
	var rows := []
	var day := 0
	var last_death_day := -1
	var first_corpse_day := -1
	while true:
		# Record every new corpse site with the fertility around it when it appeared.
		for k in core.corpses.capacity:
			if core.corpses.alive[k] == 1 and core.corpses.cell[k] >= 0 and not site_set.has(core.corpses.cell[k]):
				site_set[core.corpses.cell[k]] = true
				site_start_sum += _mean_around(world, PackedInt32Array([core.corpses.cell[k]]), spread)
				sites.append(core.corpses.cell[k])
				if first_corpse_day < 0:
					first_corpse_day = day
		if e.count == 0 and last_death_day < 0:
			last_death_day = day
		rows.append({"day": day, "alive": e.count, "corpses": core.corpses.count,
				"site_fertility": _mean_around(world, sites, spread), "sites": sites.size()})
		if last_death_day >= 0 and day >= last_death_day + ceili(decay_days) + 2:
			break
		for k in core.time.ticks_per_day:
			core.step()
		day += 1
	# Sites: fertility around each site when its corpse appeared vs after decay.
	# Control: random land far from every corpse site, at the start vs at the end (same span).
	var site_start := site_start_sum / maxi(sites.size(), 1)
	var site_end: float = rows[-1]["site_fertility"]
	var control_start := 0.0
	var control_end := 0.0
	var controls := 0
	var site_blocks := _site_blocks(core, sites)
	for k in candidates.size():
		if _near_any(core, candidates[k], site_blocks):
			continue
		control_start += candidate_start[k]
		control_end += _mean_around(world, PackedInt32Array([candidates[k]]), spread)
		controls += 1
	control_start /= maxi(controls, 1)
	control_end /= maxi(controls, 1)
	var pass_b: bool = e.count == 0 and sites.size() > 0
	var labels := PackedStringArray()
	var site_series := PackedFloat64Array()
	var alive_series := PackedFloat64Array()
	var corpse_series := PackedFloat64Array()
	for r: Dictionary in rows:
		labels.append("day %d" % r["day"] if r["day"] % 5 == 0 else "")
		site_series.append(r["site_fertility"])
		alive_series.append(100.0 * r["alive"] / n0)
		corpse_series.append(100.0 * r["corpses"] / n0)
	var peak := 0.0
	for r: Dictionary in rows:
		if r["sites"] == sites.size():
			peak = maxf(peak, r["site_fertility"])
	_write_csv(out_dir + "/scarce_daily.csv", rows, ["day", "alive", "corpses", "sites", "site_fertility"])
	_store(out_dir + "/scarce.svg", SvgChart.line_chart(
			"No flora: %d founders starve; corpses decay into the soil" % n0, "% of founders / fertility (0-255)", labels,
			[{"name": "alive (% of founders)", "color": Color(0.2, 0.45, 0.8), "values": alive_series},
			{"name": "corpses (% of founders)", "color": Color(0.45, 0.3, 0.2), "values": corpse_series},
			{"name": "fertility around corpse sites", "color": Color(0.3, 0.7, 0.3), "values": site_series}], 1))
	var rise := (site_end - site_start) - (control_end - control_start)
	pass_b = pass_b and site_end > site_start and rise > 0.0
	summary.append("## Scarce flora (none at all)")
	summary.append("")
	summary.append("- %d founders, no flora. All starved by day %d; first corpse on day %d; %d corpse sites (corpses merge when an entity dies on an existing corpse's cell)." % [
			n0, last_death_day, first_corpse_day, sites.size()])
	summary.append("- Corpses decay over %.0f days, releasing nutrients into land within %d cells." % [decay_days, spread])
	summary.append("- **Fertility around corpse sites: %.1f when the corpse appeared, %.1f after decay (%+.1f)**; peak %.1f." % [
			site_start, site_end, site_end - site_start, peak])
	summary.append("- Control land (%d random land cells at least %d cells from any corpse), same period: %.1f -> %.1f (%+.1f)." % [
			controls, CONTROL_MIN_DIST, control_start, control_end, control_end - control_start])
	summary.append("- Rise attributable to corpses (site change minus control change): **%+.1f** fertility units." % rise)
	summary.append("- **Result: %s**" % ("PASS" if pass_b else "FAIL"))
	summary.append("")
	return pass_b


## Mean fertility over land cells within `radius` of each cell in `cells`.
func _mean_around(world: RefCounted, cells: PackedInt32Array, radius: int) -> float:
	if cells.is_empty():
		return 0.0
	var w: int = world.width
	var h: int = world.height
	var total := 0
	var n := 0
	for c in cells:
		var cx := c % w
		@warning_ignore("integer_division")
		var cy := c / w
		for y in range(maxi(0, cy - radius), mini(h - 1, cy + radius) + 1):
			for x in range(maxi(0, cx - radius), mini(w - 1, cx + radius) + 1):
				var k := y * w + x
				if world.substrate[k] != 0:
					total += world.fertility[k]
					n += 1
	return float(total) / maxi(n, 1)


static func _min_after(rows: Array, key: String, from_day: int) -> float:
	var v := 1e9
	for r: Dictionary in rows:
		if r["day"] >= from_day:
			v = minf(v, r[key])
	return v


static func _max_after(rows: Array, key: String, from_day: int) -> float:
	var v := -1e9
	for r: Dictionary in rows:
		if r["day"] >= from_day:
			v = maxf(v, r[key])
	return v


static func _write_csv(path: String, rows: Array, keys: Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_line(",".join(PackedStringArray(keys)))
	for r: Dictionary in rows:
		var vals := PackedStringArray()
		for k: String in keys:
			vals.append(str(r[k]))
		f.store_line(",".join(vals))
	f.close()


static func _store(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## n random land (non-water) cells, deterministic.
func _random_land(core: RefCounted, n: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var water: int = core.substrates.id_of("water")
	var out := PackedInt32Array()
	while out.size() < n:
		var c := rng.randi_range(0, core.world.cell_count - 1)
		if core.world.substrate[c] != water:
			out.append(c)
	return out


## Blocks (CONTROL_MIN_DIST square) that contain a corpse site.
func _site_blocks(core: RefCounted, sites: PackedInt32Array) -> Dictionary:
	var w: int = core.world.width
	var out := {}
	for s in sites:
		@warning_ignore("integer_division")
		out[Vector2i((s % w) / CONTROL_MIN_DIST, (s / w) / CONTROL_MIN_DIST)] = true
	return out


## True if c's block or any neighbouring block holds a site (conservative: excludes land up to
## about 2 x CONTROL_MIN_DIST away).
func _near_any(core: RefCounted, c: int, blocks: Dictionary) -> bool:
	var w: int = core.world.width
	@warning_ignore("integer_division")
	var b := Vector2i((c % w) / CONTROL_MIN_DIST, (c / w) / CONTROL_MIN_DIST)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if blocks.has(b + Vector2i(dx, dy)):
				return true
	return false
