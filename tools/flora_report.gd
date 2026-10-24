## Multi-year flora run (Phase 2 acceptance): logs coverage, biomass, harvestable yield, growth,
## births, and deaths per type per season; checks winter stalls against config; judges whether
## coverage settles into a stable band; writes CSV, SVG charts, and a markdown summary.
##
##   godot --headless --path . --script res://tools/flora_report.gd -- [--years=10]
##       [--preset=NAME] [--size=N] [--seed=N] [--set=param.id=value ...]
##       [--out=res://batch_output/flora]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")
const SvgChart := preload("res://tools/svg_chart.gd")

const WINTER := 3
## Stability judgement: the last STABLE_YEARS years, compared season by season.
const STABLE_YEARS := 5
## Same-season total coverage may vary by at most this (absolute share of plantable land)
## across the stable window.
const STABLE_BAND := 0.10
## "Saturated" = flora on more than this share of plantable land.
const SATURATED := 0.95


func _initialize() -> void:
	var args := _parse_args()
	var params := Registry.new()
	if not params.load_file():
		quit(2)
		return
	if args.has("preset"):
		params.apply_preset(args["preset"])
	if args.has("size"):
		params.set_value("world.width", int(args["size"]))
		params.set_value("world.height", int(args["size"]))
	if args.has("seed"):
		params.set_value("world.seed", int(args["seed"]))
	for kv: String in args["set"]:
		var parts := kv.split("=", true, 1)
		params.set_value(parts[0], str_to_var(parts[1]))
	var years := int(args.get("years", 10))
	var out_dir: String = args.get("out", "res://batch_output/flora")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var t_gen := Time.get_ticks_msec()
	var core := SimCore.new()
	if not core.init_new(params):
		push_error(core.error)
		quit(2)
		return
	var env: RefCounted = core.env
	var time: RefCounted = core.time
	var flora: RefCounted = core.flora
	var types: int = flora.count()
	var plantable_land := _plantable_land(core)
	print("world %dx%d (seed %d) in %.1f s; %d plantable land cells; %d samples/tick, %.2f days per cell update; year = %d ticks" % [
			core.world.width, core.world.height, params.get_int("world.seed"),
			(Time.get_ticks_msec() - t_gen) / 1000.0, plantable_land, env.samples_per_tick,
			env.dt_days, time.ticks_per_year])

	var rows := []  # one Dictionary per season
	env.take_period_stats()
	rows.append(_row(core, env.take_period_stats(), -1, plantable_land))  # initial state
	var seasons: int = years * 4
	var t0 := Time.get_ticks_msec()
	env.timing_usec = 0
	# A season's period covers the ticks whose season_count equals it; close it before stepping
	# into the next season's first tick so no growth is attributed to the wrong season. Stop at
	# the end of the last season (tick 0 is the initial state and never stepped).
	while time.season_count(core.tick + 1) < seasons:
		var current: int = time.season_count(core.tick + 1)
		core.step()
		if time.season_count(core.tick + 1) != current:
			rows.append(_row(core, env.take_period_stats(), current, plantable_land))
			var r: Dictionary = rows[-1]
			if r["season"] == WINTER:
				print("  year %2d done: total cover %.1f%%  (%s)  moisture %.2f  fertility %.2f  [%.0f s]" % [
						r["year"] + 1, r["total_share"] * 100.0, _type_shares(r, flora), r["mean_moisture"],
						r["mean_fertility"], (Time.get_ticks_msec() - t0) / 1000.0])
	var run_s := (Time.get_ticks_msec() - t0) / 1000.0
	var env_ms: float = env.timing_usec / 1000.0 / maxi(core.tick, 1)

	var verdict := _judge(rows, flora, types)
	var stalls := _winter_stalls(rows, flora, types)
	_write_csv(out_dir + "/flora_seasons.csv", rows, flora, types)
	_write_charts(out_dir, rows, flora, types)
	var summary := _summary(core, rows, verdict, stalls, years, run_s, env_ms, plantable_land)
	var f := FileAccess.open(out_dir + "/flora_summary.md", FileAccess.WRITE)
	f.store_string(summary)
	f.close()
	print("\n" + summary)
	print("wrote %s/{flora_seasons.csv, flora_coverage.svg, flora_yield.svg, flora_summary.md}" % ProjectSettings.globalize_path(out_dir))
	quit(0 if verdict["stable"] and stalls["ok"] else 1)


func _row(core: RefCounted, st: Dictionary, season_count: int, plantable_land: int) -> Dictionary:
	var flora: RefCounted = core.flora
	var season := posmod(season_count, 4) if season_count >= 0 else -1
	var total := 0
	var yield_by_type := PackedFloat64Array([0.0])
	for t in range(1, flora.count() + 1):
		total += st["coverage"][t]
		yield_by_type.append(st["biomass"][t] * (flora.seasonal_yield[t * 4 + season] if season >= 0 else 0.0))
	@warning_ignore("integer_division")
	return {
		"season_index": season_count,
		"year": season_count / 4 if season_count >= 0 else -1,
		"season": season,
		"coverage": st["coverage"], "biomass": st["biomass"], "growth": st["growth"],
		"births": st["births"], "deaths": st["deaths"], "yield": yield_by_type,
		"total": total, "total_share": float(total) / plantable_land,
		"mean_moisture": st["mean_moisture"], "mean_fertility": st["mean_fertility"],
	}


func _judge(rows: Array, flora: RefCounted, types: int) -> Dictionary:
	var last: Dictionary = rows[-1]
	var extinct := PackedStringArray()
	for t in range(1, types + 1):
		if last["coverage"][t] == 0:
			extinct.append(flora.names[t])
	var window := rows.filter(func(r: Dictionary) -> bool:
		return r["year"] >= rows[-1]["year"] - STABLE_YEARS + 1)
	var spread := 0.0
	var max_share := 0.0
	var min_share := 1.0
	for s in 4:
		var shares := window.filter(func(r: Dictionary) -> bool: return r["season"] == s) \
				.map(func(r: Dictionary) -> float: return r["total_share"])
		if shares.is_empty():
			continue
		spread = maxf(spread, shares.max() - shares.min())
		max_share = maxf(max_share, shares.max())
		min_share = minf(min_share, shares.min())
	var stable := extinct.is_empty() and spread <= STABLE_BAND and max_share < SATURATED and min_share > 0.0
	return {"stable": stable, "extinct": extinct, "spread": spread, "max_share": max_share,
			"min_share": min_share, "window": window.size()}


## Types with seasonal_growth[winter] == 0 must show zero growth and zero births in every winter.
func _winter_stalls(rows: Array, flora: RefCounted, types: int) -> Dictionary:
	var lines := PackedStringArray()
	var ok := true
	for t in range(1, types + 1):
		var cfg: float = flora.seasonal_growth[t * 4 + WINTER]
		var growth := 0
		var births := 0
		var winters := 0
		for r: Dictionary in rows:
			if r["season"] == WINTER:
				winters += 1
				growth += r["growth"][t]
				births += r["births"][t]
		var expect_stall := cfg == 0.0
		var pass_t := (growth == 0 and births == 0) if expect_stall else growth > 0
		ok = ok and pass_t
		lines.append("| %s | %.2f | %s | %d | %d | %s |" % [flora.names[t], cfg,
				"stall" if expect_stall else "slow growth", growth, births, "ok" if pass_t else "MISMATCH"])
	return {"ok": ok, "lines": lines}


func _write_csv(path: String, rows: Array, flora: RefCounted, types: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_line("season_index,year,season,type,coverage,coverage_share,biomass,mean_biomass,harvestable_yield,growth,births,deaths,mean_moisture,mean_fertility")
	for r: Dictionary in rows:
		for t in range(1, types + 1):
			var cov: int = r["coverage"][t]
			f.store_line("%d,%d,%s,%s,%d,%.5f,%d,%.1f,%.1f,%d,%d,%d,%.4f,%.4f" % [
					r["season_index"], r["year"] + 1, _season_name(r["season"]), flora.names[t], cov,
					cov / float(maxi(r["total"], 1)) * r["total_share"], r["biomass"][t],
					r["biomass"][t] / float(maxi(cov, 1)), r["yield"][t], r["growth"][t],
					r["births"][t], r["deaths"][t], r["mean_moisture"], r["mean_fertility"]])
	f.close()


func _write_charts(out_dir: String, rows: Array, flora: RefCounted, types: int) -> void:
	var labels := PackedStringArray()
	for r: Dictionary in rows:
		labels.append("start" if r["season"] < 0 else ("Y%d" % (r["year"] + 1) if r["season"] == 0 else ""))
	var cov_series := []
	var yield_series := []
	for t in range(1, types + 1):
		var cov := PackedFloat64Array()
		var yl := PackedFloat64Array()
		for r: Dictionary in rows:
			cov.append(r["coverage"][t] / float(maxi(r["total"], 1)) * r["total_share"] * 100.0)
			yl.append(r["yield"][t])
		cov_series.append({"name": flora.names[t], "color": flora.colors[t].darkened(0.15), "values": cov})
		yield_series.append({"name": flora.names[t], "color": flora.colors[t].darkened(0.15), "values": yl})
	var total := PackedFloat64Array()
	for r: Dictionary in rows:
		total.append(r["total_share"] * 100.0)
	cov_series.append({"name": "all flora", "color": Color(0.1, 0.1, 0.1), "values": total, "dash": true})
	_store(out_dir + "/flora_coverage.svg", SvgChart.line_chart(
			"Flora coverage by type, end of each season", "% of plantable land", labels, cov_series, 1))
	_store(out_dir + "/flora_yield.svg", SvgChart.line_chart(
			"Harvestable yield by type (biomass x seasonal yield), end of each season", "yield units",
			labels, yield_series, 1))


func _summary(core: RefCounted, rows: Array, verdict: Dictionary, stalls: Dictionary, years: int,
		run_s: float, env_ms: float, plantable_land: int) -> String:
	var flora: RefCounted = core.flora
	var types: int = flora.count()
	var out := PackedStringArray()
	out.append("# Flora report: %d years, %dx%d, seed %d" % [years, core.world.width, core.world.height,
			core.params.get_int("world.seed")])
	out.append("")
	out.append("- Run: %d ticks in %.0f s; environment pass %.2f ms/tick mean (%d samples/tick, %.2f days between updates of a cell)" % [
			core.tick, run_s, env_ms, core.env.samples_per_tick, core.env.dt_days])
	out.append("- Plantable land: %d cells" % plantable_land)
	out.append("- **Stable band: %s.** Last %d years, same-season total coverage spread %.1f points (limit %.0f); range %.1f%%-%.1f%% of plantable land (saturated at %.0f%%); extinct types: %s." % [
			"YES" if verdict["stable"] else "NO", STABLE_YEARS, verdict["spread"] * 100.0,
			STABLE_BAND * 100.0, verdict["min_share"] * 100.0, verdict["max_share"] * 100.0,
			SATURATED * 100.0, "none" if verdict["extinct"].is_empty() else ", ".join(verdict["extinct"])])
	out.append("- **Winter stalls match config: %s.**" % ("YES" if stalls["ok"] else "NO"))
	out.append("")
	out.append("## Coverage (% of plantable land) at the end of each season, final 2 years")
	out.append("")
	var head := "| year | season | total |"
	var sep := "|---:|---|---:|"
	for t in range(1, types + 1):
		head += " %s |" % flora.names[t]
		sep += "---:|"
	head += " moisture | fertility |"
	sep += "---:|---:|"
	out.append(head)
	out.append(sep)
	for r: Dictionary in rows.slice(maxi(0, rows.size() - 8)):
		var line := "| %d | %s | %.1f |" % [r["year"] + 1, _season_name(r["season"]), r["total_share"] * 100.0]
		for t in range(1, types + 1):
			line += " %.1f |" % (r["coverage"][t] / float(maxi(r["total"], 1)) * r["total_share"] * 100.0)
		line += " %.2f | %.2f |" % [r["mean_moisture"], r["mean_fertility"]]
		out.append(line)
	out.append("")
	out.append("## Per-type trend (winter coverage, points of plantable land per year, last 3 years)")
	out.append("")
	out.append("Total coverage is what the stability check judges. Individual types can still drift")
	out.append("slowly (succession toward long-lived woody plants); this table shows how fast.")
	out.append("")
	out.append("| type | winter coverage, final year | change per year |")
	out.append("|---|---:|---:|")
	var winters: Array = rows.filter(func(r: Dictionary) -> bool: return r["season"] == WINTER)
	if winters.size() >= 4:
		var a: Dictionary = winters[-4]
		var z: Dictionary = winters[-1]
		for t in range(1, types + 1):
			var za := _share(z, t) * 100.0
			out.append("| %s | %.1f%% | %+.2f |" % [flora.names[t], za, (za - _share(a, t) * 100.0) / 3.0])
	out.append("")
	out.append("## Harvestable yield by season, final year (biomass x seasonal_yield)")
	out.append("")
	out.append("| type | spring | summer | autumn | winter |")
	out.append("|---|---:|---:|---:|---:|")
	var final_year: Array = rows.filter(func(r: Dictionary) -> bool: return r["year"] == rows[-1]["year"])
	for t in range(1, types + 1):
		var cells := ["-", "-", "-", "-"]
		for r: Dictionary in final_year:
			cells[r["season"]] = "%.0f" % r["yield"][t]
		out.append("| %s | %s |" % [flora.names[t], " | ".join(cells)])
	out.append("")
	out.append("## Winter stalls (all winters)")
	out.append("")
	out.append("| type | seasonal_growth[winter] | expected | winter growth | winter births | check |")
	out.append("|---|---:|---|---:|---:|---|")
	out.append_array(stalls["lines"])
	out.append("")
	return "\n".join(out)


## Share of plantable land covered by type t in a row.
static func _share(r: Dictionary, t: int) -> float:
	return r["coverage"][t] / float(maxi(r["total"], 1)) * r["total_share"]


func _plantable_land(core: RefCounted) -> int:
	var n := 0
	for s in core.substrates.count():
		var any := false
		for t in range(1, core.flora.count() + 1):
			if core.flora.allowed[t * 256 + s] == 1:
				any = true
		if any:
			n += core.world.substrate.count(s)
	return n


func _type_shares(r: Dictionary, flora: RefCounted) -> String:
	var parts := PackedStringArray()
	for t in range(1, flora.count() + 1):
		parts.append("%s %.1f" % [flora.names[t], r["coverage"][t] / float(maxi(r["total"], 1)) * r["total_share"] * 100.0])
	return ", ".join(parts)


static func _season_name(s: int) -> String:
	return "start" if s < 0 else ["spring", "summer", "autumn", "winter"][s]


static func _store(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


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
