## Perception structure benchmark (Phase 3 scope 5: "choose hash or direct grid scan by
## profiling"). On the real map with founder-placed entities, single-threaded:
##   grid_all     one scan of the sense window reading flora, occupancy, corpses, substrate
##                (decide's first version)
##   grid_flora   the same scan reading flora only (food must be scanned on the grid either way)
##   grid_flora+occ  flora plus occupancy per cell
##   hash_build   per tick: bucket every entity into a spatial hash (counting sort)
##   hash_query   per decision: entities within the sense radius via the hash buckets
##   occ_rows     entities in sight counted natively per row (slice + count), as decide does
##                after the Phase 3 optimisation
## Entity perception costs (grid_flora+occ - grid_flora) per decision on the grid, or occ_rows,
## versus hash_build / decisions + hash_query per decision with a hash.
##
##   godot --headless --path . --script res://tools/perception_bench.gd -- [--counts=10000,50000,100000]
##       [--radius=5] [--bucket=16] [--samples=10000] [--env-warmup=N]
extends SceneTree

const Registry := preload("res://sim/params/registry.gd")
const SimCore := preload("res://sim/core/sim_core.gd")

const REPEATS := 3


func _initialize() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var r := int(args.get("radius", 5))
	var bucket := int(args.get("bucket", 16))
	var samples := int(args.get("samples", 10000))
	var params := Registry.new()
	params.load_file()
	var core := SimCore.new()
	core.init_new(params)
	for t in int(args.get("env-warmup", 0)):
		core.step()
	var interval: int = params.get_int("entity.decision_interval")
	print("perception bench: radius %d (%d cells), bucket %d, %d sampled decisions, decisions/tick = entities / %d" % [
			r, (2 * r + 1) * (2 * r + 1), bucket, samples, interval])
	print("| entities | grid_all us/decision | grid_flora+occ us/decision | grid_flora us/decision | entity part on grid us | occ_rows us/decision | hash_build ms/tick | hash_query us/decision | entity part with hash us/decision | grid entity ms/tick | hash entity ms/tick |")
	print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	for n_text in str(args.get("counts", "10000,50000,100000")).split(","):
		var n := int(n_text)
		core.entities.clear()
		@warning_ignore("integer_division")
		var groups := maxi(1, n / 250)
		core.spawn_founders({"groups": groups, "size_min": 250, "size_max": 250,
				"spacing": int(sqrt(16777216.0 / groups) * 0.5)})
		var cells := _sample_cells(core, samples)
		var t_all := _best(func() -> int: return _grid_all(core, cells, r))
		var t_flora := _best(func() -> int: return _grid_flora(core, cells, r))
		var t_occ := _best(func() -> int: return _grid_flora_occ(core, cells, r))
		var t_rows := _best(func() -> int: return _grid_occ_rows(core, cells, r))
		var hash := {}
		var t_build := _best(func() -> int: return _hash_build(core, bucket, hash))
		var t_query := _best(func() -> int: return _hash_query(core, cells, r, bucket, hash))
		var per := float(cells.size())
		var decisions := float(core.entities.count) / interval
		var grid_entity_us := (t_occ - t_flora) / per
		var hash_entity_us := t_build / decisions + t_query / per
		print("| %d | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |" % [core.entities.count,
				t_all / per, t_occ / per, t_flora / per, grid_entity_us, t_rows / per, t_build / 1000.0, t_query / per,
				hash_entity_us, grid_entity_us * decisions / 1000.0, hash_entity_us * decisions / 1000.0])
	quit()


## Fastest of REPEATS runs, in microseconds.
static func _best(fn: Callable) -> int:
	var best := 1 << 62
	for k in REPEATS:
		var t0 := Time.get_ticks_usec()
		fn.call()
		best = mini(best, Time.get_ticks_usec() - t0)
	return best


static func _sample_cells(core: RefCounted, n: int) -> PackedInt32Array:
	var e: RefCounted = core.entities
	var out := PackedInt32Array()
	var w: int = core.world.width
	for i in e.capacity:
		if e.alive[i] == 1:
			out.append(e.y[i] * w + e.x[i])
			if out.size() >= n:
				break
	return out


## The decide scan: flora + occupancy + corpses + substrate per cell.
static func _grid_all(core: RefCounted, cells: PackedInt32Array, r: int) -> int:
	var w: int = core.world.width
	var h: int = core.world.height
	var ft: PackedByteArray = core.world.flora_type
	var fb: PackedByteArray = core.world.flora_biomass
	var occ: PackedInt32Array = core.world.occupancy
	var cid: PackedInt32Array = core.world.corpse_id
	var sub: PackedByteArray = core.world.substrate
	var sink := 0
	for self_cell in cells:
		var cx := self_cell % w
		@warning_ignore("integer_division")
		var cy := self_cell / w
		var near := 0
		var best := 0
		var water_d := 255
		for yy in range(maxi(cy - r, 0), mini(cy + r, h - 1) + 1):
			var row := yy * w
			var ady := absi(yy - cy)
			for xx in range(maxi(cx - r, 0), mini(cx + r, w - 1) + 1):
				var c := row + xx
				var adx := absi(xx - cx)
				var d := adx if adx > ady else ady
				var o := occ[c]
				if o != 0 and c != self_cell:
					near += 1
				var t := ft[c]
				if t != 0 and (o == 0 or c == self_cell):
					var g := fb[c] * t
					if g > best:
						best = g
				if cid[c] != 0:
					best += 1
				if d < water_d and sub[c] == 0:
					water_d = d
		sink += near + best + water_d
	return sink


## Flora only.
static func _grid_flora(core: RefCounted, cells: PackedInt32Array, r: int) -> int:
	var w: int = core.world.width
	var h: int = core.world.height
	var ft: PackedByteArray = core.world.flora_type
	var fb: PackedByteArray = core.world.flora_biomass
	var sink := 0
	for self_cell in cells:
		var cx := self_cell % w
		@warning_ignore("integer_division")
		var cy := self_cell / w
		var best := 0
		for yy in range(maxi(cy - r, 0), mini(cy + r, h - 1) + 1):
			var row := yy * w
			var ady := absi(yy - cy)
			for xx in range(maxi(cx - r, 0), mini(cx + r, w - 1) + 1):
				var c := row + xx
				var adx := absi(xx - cx)
				var d := adx if adx > ady else ady
				var t := ft[c]
				if t != 0:
					var g := fb[c] * t + d
					if g > best:
						best = g
		sink += best
	return sink


## Flora + occupancy (entities on the grid), no corpse or water reads.
static func _grid_flora_occ(core: RefCounted, cells: PackedInt32Array, r: int) -> int:
	var w: int = core.world.width
	var h: int = core.world.height
	var ft: PackedByteArray = core.world.flora_type
	var fb: PackedByteArray = core.world.flora_biomass
	var occ: PackedInt32Array = core.world.occupancy
	var sink := 0
	for self_cell in cells:
		var cx := self_cell % w
		@warning_ignore("integer_division")
		var cy := self_cell / w
		var near := 0
		var best := 0
		for yy in range(maxi(cy - r, 0), mini(cy + r, h - 1) + 1):
			var row := yy * w
			var ady := absi(yy - cy)
			for xx in range(maxi(cx - r, 0), mini(cx + r, w - 1) + 1):
				var c := row + xx
				var adx := absi(xx - cx)
				var d := adx if adx > ady else ady
				var o := occ[c]
				if o != 0 and c != self_cell:
					near += 1
				var t := ft[c]
				if t != 0 and (o == 0 or c == self_cell):
					var g := fb[c] * t + d
					if g > best:
						best = g
		sink += near + best
	return sink


## Entities in sight via native per-row counts (slice + count(0)), as decide does since the
## Phase 3 optimisation; the crowd centroid's y comes with it.
static func _grid_occ_rows(core: RefCounted, cells: PackedInt32Array, r: int) -> int:
	var w: int = core.world.width
	var h: int = core.world.height
	var occ: PackedInt32Array = core.world.occupancy
	var sink := 0
	for self_cell in cells:
		var cx := self_cell % w
		@warning_ignore("integer_division")
		var cy := self_cell / w
		var x0 := maxi(cx - r, 0)
		var x1 := mini(cx + r, w - 1)
		var near := 0
		var dy := 0
		for yy in range(maxi(cy - r, 0), mini(cy + r, h - 1) + 1):
			var seg := occ.slice(yy * w + x0, yy * w + x1 + 1)
			var n := seg.size() - seg.count(0)
			near += n
			dy += n * (yy - cy)
		sink += near + dy
	return sink


## Counting sort of alive entities into bucket x bucket cell buckets.
static func _hash_build(core: RefCounted, bucket: int, out: Dictionary) -> int:
	var e: RefCounted = core.entities
	@warning_ignore("integer_division")
	var bw: int = (core.world.width + bucket - 1) / bucket
	@warning_ignore("integer_division")
	var bh: int = (core.world.height + bucket - 1) / bucket
	var start := PackedInt32Array()
	start.resize(bw * bh + 1)
	start.fill(0)
	var xs: PackedInt32Array = e.x
	var ys: PackedInt32Array = e.y
	var alv: PackedByteArray = e.alive
	var cap: int = e.capacity
	for i in cap:
		if alv[i] == 1:
			@warning_ignore("integer_division")
			start[(ys[i] / bucket) * bw + xs[i] / bucket + 1] += 1
	for b in bw * bh:
		start[b + 1] += start[b]
	var fill := start.slice(0)
	var items := PackedInt32Array()
	items.resize(start[bw * bh])
	for i in cap:
		if alv[i] == 1:
			@warning_ignore("integer_division")
			var b: int = (ys[i] / bucket) * bw + xs[i] / bucket
			items[fill[b]] = i
			fill[b] += 1
	out["start"] = start
	out["items"] = items
	out["bw"] = bw
	return items.size()


## Entities within Chebyshev radius r of each sampled cell, via the hash.
static func _hash_query(core: RefCounted, cells: PackedInt32Array, r: int, bucket: int,
		hash: Dictionary) -> int:
	var w: int = core.world.width
	var start: PackedInt32Array = hash["start"]
	var items: PackedInt32Array = hash["items"]
	var bw: int = hash["bw"]
	@warning_ignore("integer_division")
	var bh: int = (core.world.height + bucket - 1) / bucket
	var xs: PackedInt32Array = core.entities.x
	var ys: PackedInt32Array = core.entities.y
	var sink := 0
	for self_cell in cells:
		var cx := self_cell % w
		@warning_ignore("integer_division")
		var cy := self_cell / w
		var near := 0
		@warning_ignore("integer_division")
		var bx0 := maxi(cx - r, 0) / bucket
		@warning_ignore("integer_division")
		var bx1 := mini(cx + r, w - 1) / bucket
		@warning_ignore("integer_division")
		var by0 := maxi(cy - r, 0) / bucket
		@warning_ignore("integer_division")
		var by1 := mini(cy + r, bh * bucket - 1) / bucket
		for by in range(by0, by1 + 1):
			for bx in range(bx0, bx1 + 1):
				var b := by * bw + bx
				for k in range(start[b], start[b + 1]):
					var i := items[k]
					if absi(xs[i] - cx) <= r and absi(ys[i] - cy) <= r:
						near += 1
		sink += near
	return sink
