## Founder spawner (spec section 1): founders.groups groups of founders.size_min..size_max
## entities, centres at least founders.spacing apart on passable land, members placed on free
## passable cells within founders.spread of their centre. Centres sit on habitable land (fertility
## >= founders.centre_min_fertility). Genomes are the gene defaults, plus
## optional uniform jitter (founders.gene_jitter x each gene's range). Starting energy is
## uniform in [founders.energy_min, 1] x max_energy. Sequential only.
extends RefCounted

const STREAM := "founders"
## Placement retry budgets (not tunables): tries per centre, and per member before the spread
## radius grows.
const CENTRE_TRIES := 2000
const MEMBER_TRIES := 64
const SPREAD_GROWTH := 2


## Spawn groups and return {"groups": [{centre, size, placed}], "spawned": n}. `overrides` may
## replace any founders.* value (groups, size_min, size_max, spacing, spread, gene_jitter,
## energy_min).
static func spawn(entities: RefCounted, params: RefCounted, rngs: RefCounted,
		overrides: Dictionary = {}) -> Dictionary:
	var rng: RandomNumberGenerator = rngs.stream(STREAM)
	var world: RefCounted = entities.world
	var cfg := {}
	for key: String in ["groups", "size_min", "size_max", "spacing", "spread"]:
		cfg[key] = int(overrides.get(key, params.get_int("founders." + key)))
	cfg["gene_jitter"] = float(overrides.get("gene_jitter", params.get_float("founders.gene_jitter")))
	cfg["energy_min"] = float(overrides.get("energy_min", params.get_float("founders.energy_min")))
	var w: int = world.width
	var h: int = world.height
	var passable: PackedByteArray = entities.subs.passable
	var min_fert := roundi(float(overrides.get("centre_min_fertility", params.get_float("founders.centre_min_fertility"))) * 255.0)
	var centres := PackedVector2Array()
	var result := {"groups": [], "spawned": 0}
	var genes: RefCounted = entities.genes
	for g in cfg["groups"]:
		var centre := Vector2i(-1, -1)
		var spacing: int = cfg["spacing"]
		while centre.x < 0:
			for t in CENTRE_TRIES:
				var c := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
				var cc := c.y * w + c.x
				# Centres on habitable (passable, fertile) land, so groups do not start on bare rock.
				if passable[world.substrate[cc]] == 0 or world.fertility[cc] < min_fert:
					continue
				var ok := true
				for other in centres:
					if Vector2(c).distance_to(other) < spacing:
						ok = false
						break
				if ok:
					centre = c
					break
			spacing = spacing / 2  # crowded map: relax the spacing rule
			if spacing == 0 and centre.x < 0:
				break
		if centre.x < 0:
			break
		centres.append(Vector2(centre))
		var size := rng.randi_range(cfg["size_min"], maxi(cfg["size_min"], cfg["size_max"]))
		var spread: int = cfg["spread"]
		var placed := 0
		while placed < size:
			var done := false
			for t in MEMBER_TRIES:
				var c := Vector2i(clampi(centre.x + rng.randi_range(-spread, spread), 0, w - 1),
						clampi(centre.y + rng.randi_range(-spread, spread), 0, h - 1))
				var genome: PackedFloat32Array = genes.defaults()
				if cfg["gene_jitter"] > 0.0:
					for k in genome.size():
						var span: float = (genes.maximum[k] - genes.minimum[k]) * cfg["gene_jitter"]
						genome[k] = genes.clamp_gene(k, genome[k] + rng.randf_range(-span, span))
				var slot: int = entities.spawn(c.y * w + c.x, genome, entities.roll_sex(rng))
				if slot >= 0:
					# Staggered starting energy, so hunger is not synchronised across founders.
					entities.energy[slot] = roundi(entities.max_energy[slot] * rng.randf_range(cfg["energy_min"], 1.0))
					placed += 1
					done = true
					break
			if not done:
				spread *= SPREAD_GROWTH
				if spread > maxi(w, h):
					break
		result["groups"].append({"centre": centre, "size": size, "placed": placed})
		result["spawned"] += placed
	return result
