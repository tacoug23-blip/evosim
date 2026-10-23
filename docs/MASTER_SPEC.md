# EvoSim Master Spec

A large-scale evolving world simulation (RimWorld / Dwarf Fortress style) built in Godot. Entities live on a layered grid, evolve, form tribes, build, fight, trade goodwill, and merge. A player influences the world only through signals.

This document is the source of truth. Every phase prompt in `docs/phases/` assumes it has been read. If a phase prompt and this spec conflict, stop and ask.

---

## 1. Locked decisions

| Topic | Decision |
|---|---|
| Engine | Godot 4.x |
| Sim core language | GDScript spike first (Phase 1). If it misses the tick target, rewrite the core as a Rust GDExtension (godot-rust/gdext). GDScript stays for UI and glue either way. |
| Grid | Square cells, one colored pixel per cell |
| Map size | 4096 x 4096 (16.7M cells), tunable |
| Population | Trough about 1,000, peak about 100,000. No enforced floor; optional auto-reseed toggle, default off. |
| Occupancy | Strictly one entity per cell. Carried corpses and items do not occupy. Walls block. |
| Reproduction | Sexual only. Two sexes. Gestation cost on the female. Tunable birth sex ratio. |
| Mate choice | Compatibility genome-distance cutoff (tunable) plus an evolvable in-tribe vs out-tribe mate preference gene |
| Player role | Signals only (v1) |
| Cooking | Requires a hearth structure |
| Shelter | Reduces energy loss, speeds production (crafting, cooking, building, reproduction), stalls flora growth underneath. Per-material multipliers. |
| Tribes | Emergent, based on genome similarity AND spatial proximity. Persistent IDs. |
| Tech | Per-tribe discovered recipes, unlocked by tribe proficiency. Can be lost or kept on split. Unioned on merge. |
| Founders | Tunable. Default guess: about 20 groups, 100-500 each, randomly placed with minimum spacing. Phase 5 sweeps to choose the default. |
| Tick-rate target | Provisional: 10 sim ticks/s at 100k entities on the user's machine. Final number set after the user sees it running. |
| Determinism | Seeded and deterministic. Same seed + same parameters + same signal inputs = same result. |

---

## 2. Principles

1. **Sim core is separate from rendering.** The core runs headless (`godot --headless`) with no UI dependency. Rendering reads from core state; it never writes.
2. **Everything numeric is a registered parameter.** No magic numbers in sim code. Every tunable lives in the parameter registry (section 12) with a default, min, max, group, and description.
3. **Struct-of-arrays.** No per-entity or per-cell objects. Use `Packed*Array` (GDScript) or typed Vecs (Rust). One array per field.
4. **Every beneficial gene has a cost.** Speed, sensing, aggression, fertility, lifespan, and so on each draw energy or trade off against another gene. No free upgrades.
5. **Staggered updates.** Entities decide every N ticks, offset by ID so the load is spread. Flora updates by random sampling. Signal fields update at lower resolution and frequency.
6. **Observability before complexity.** Features that cannot be inspected or charted are not considered done.
7. **Deterministic RNG.** One seeded RNG stream per subsystem so adding a feature does not reshuffle unrelated randomness.

---

## 3. World

Struct-of-arrays layers over the 4096 x 4096 grid:

| Layer | Type | Notes |
|---|---|---|
| substrate | u8 | soil, rock, sand, water, mud, and so on. Defined in `config/substrates.json`. |
| fertility | u8 | Soil nutrient level. Rises from decomposition, falls from plant growth. |
| moisture | u8 | Drives flora growth. |
| flora_type | u8 | 0 = none |
| flora_biomass | u8 | Harvestable amount |
| structure_type | u8 | 0 = none. Wall, floor, hearth, storage, and so on. |
| structure_material | u8 | Index into the materials table |
| structure_hp | u16 | |
| item_type / item_qty | u8 / u8 | Dropped or stored resources |
| corpse_id | u32 | Index into the corpse table, 0 = none |
| occupancy | u32 | Entity ID or 0. Used for one-per-cell. |
| tribe_territory | u16 | Optional overlay, derived, not authoritative |

Separate lower-resolution grids:
- **Signal fields**: N channels at 512x512 or 1024x1024 (tunable). Each signal cell covers a block of map cells. Diffuse and decay. GPU compute shader if possible.

Substrate properties (config-driven): `move_cost`, `fertility_base`, `allows_flora` (bitmask of flora types), `allows_building`, `allows_water_crossing`.

Flora properties: `substrate_mask`, `growth_rate`, `seed_spread_radius`, `seasonal_yield[4]`, `harvest_item`, `nutrition`. New plants spawn on nearby valid tiles. Yield varies by season. Growth requires fertility and moisture; harvest and growth drain fertility.

Time: tick -> hour -> day -> season -> year. Day/night modifies visibility, energy loss, and flora growth. Seasons modify flora yield and growth, and optionally energy loss.

---

## 4. Entities

State arrays (SoA): id, x, y, alive, sex, age, life_stage, energy, hp, tribe_id, parent_ids, genome (see below), carrying (item or corpse), current_action, action_target, memory slots, gestation_timer, pregnancy_father_genes.

### 4.1 Genome

A float vector with per-gene bounds. Each gene is registered with: name, min, max, default, mutation_rate, mutation_scale, and cost function. Global `mutation_scale_multiplier` scales all mutations (the "how different are children" knob).

Gene groups (initial list, extend as needed):
- **Metabolism**: base_energy_burn, food_needed_to_sate, digest_efficiency, max_energy
- **Locomotion**: move_speed, move_energy_cost
- **Perception**: sense_radius (costs energy), memory_capacity
- **Life cycle**: lifespan, maturity_age, fertility, gestation_length, mate_choice_in_tribe, mating_propensity
- **Social**: group_preference (positive = joins others' activities, negative = avoids), tribe_loyalty, generosity, aggression, retaliation_bias
- **Activity propensities**: forage, build, cook, craft, carry_corpse, fight, share, explore
- **Signal responses**: per channel: attraction, repulsion, aggression_boost, build_affinity (signed weights)
- **Combat**: attack, defense, damage_resistance

Genes that are physical stats (speed, attack, and so on) must carry a cost. Document each gene's cost in `config/genes.json`.

### 4.2 Sexes and reproduction

- Two sexes, assigned at birth with probability `birth_sex_ratio`.
- Mating: a fertile adult seeks a compatible adult of the other sex within perception. Compatible = genome distance <= `mate_compat_cutoff` and mate preference gene satisfied (in-tribe vs out-tribe).
- Offspring genome: per-gene crossover from both parents, then mutation (per-gene rate and scale, times the global multiplier).
- Female carries gestation: energy cost per tick, reduced mobility optional, `gestation_length` gene.
- Optional parental investment (tunable): juveniles consume food; parents or tribe members can feed them.

### 4.3 Life stages and aging

Stages: juvenile, adult, elder. Parameters per stage scale stats (speed, energy burn, fertility, combat). Death by energy depletion, hp depletion, or old age (lifespan gene with variance). Corpses are created on death.

### 4.4 Corpses

Corpse table: position, mass, nutrient content, decay timer, owner tribe. Can be carried by entities (carry_corpse propensity), eaten (if species diet allows, tunable), or left to decompose. Decomposition returns nutrients to the fertility layer. Carrying is a speed penalty. Moving corpses lets entities bury, relocate, or hoard them.

---

## 5. Decision-making

Utility scoring. Each candidate action has a score computed from: current needs, perceived environment, memory, genome weights, tribe context, signal fields.

Candidate actions: eat, forage/harvest, drink, rest, seek shelter, seek mate, mate, flee, fight, carry corpse, build, cook, craft, share, defend ally, explore, follow signal, avoid signal.

Rules:
- Re-evaluate every N ticks (N param, entity ID offset).
- Perception limited to `sense_radius`. Query via spatial hash or direct grid scan, whichever profiles faster.
- Memory: a small fixed-size ring of remembered locations (food, shelter, danger, hostile entities).
- Movement uses cost-weighted pathing from a local flow or gradient approach, not per-entity A*. Entities that cannot move wait or sidestep.

### 5.1 Movement and one-per-cell

- Entities propose moves; conflicts are resolved in a seeded deterministic order (rotating priority).
- No swaps. Blocked entities wait, sidestep, or re-plan.
- Move cost = terrain cost x entity move_energy_cost. Move speed determines how many cells per tick (via accumulator).
- Melee requires adjacency.

---

## 6. Tribes

A tribe is a connected component in a graph where an edge exists between two entities if BOTH:
- genome distance <= `tribe_genome_threshold`
- spatial distance <= `tribe_link_radius`

Computed periodically (every `tribe_update_interval` ticks), using a spatial hash.

Rules:
- Tribes on opposite sides of the map cannot merge naturally (no chain of nearby members).
- **Persistence:** tribe IDs persist across recomputation by majority-membership matching to the previous assignment.
- **Split:** when a component divides, the largest fragment keeps the ID; others get new IDs and inherit a copy of the knowledge set, each recipe lost with probability `knowledge_loss_on_split`. Hostility and goodwill ledgers are copied.
- **Merge:** two tribes merge when ALL hold: mutual goodwill >= `merge_goodwill_threshold`; members of both within `tribe_link_radius` across a border chain; centroid genome distance <= `merge_genome_threshold`. Larger tribe keeps ID. Knowledge = union, proficiency per recipe by max or weighted average (param). Hostility memory toward third parties combined.
- Cross-tribe mating is allowed and is the path by which merges become genetically possible.

---

## 7. Knowledge and tech

- Each tribe has a proficiency score per activity (building, cooking, crafting, farming/foraging, combat, and so on), built from members' activity output over time.
- When proficiency in an activity passes a recipe's threshold, the tribe may unlock a new recipe in that domain (probabilistic discovery, tunable). Examples: stronger wall material, better shelter, faster cooking, higher-yield food, improved weapon.
- Recipes are data in `config/recipes.json` with: domain, threshold, prerequisites, effect modifiers.
- Knowledge is per tribe. It can be lost on split, kept, or unioned on merge. Optionally decays if the domain is unused.
- Entities carry out recipes; the tribe's unlocked set determines what is available.

---

## 8. Buildings, materials, cooking

Structures: wall, floor/shelter tile, door (optional), storage, hearth.

Materials start: wood, stone, mud, hide. More unlocked via knowledge.

Material table (`config/materials.json`), per-material multipliers:
- energy_loss_reduction (shelter)
- production_speed (crafting, cooking, building, reproduction)
- flora_stall (growth stall underneath)
- durability (hp)
- build_cost (material + labor)
- fire_cooking_factor (hearth)

Shelter: an enclosed region of floor tiles bounded by walls/structures. Occupants gain the shelter's effects. Capacity = interior tile count (one entity per cell). Enclosure detection is incremental (flood fill on structure change).

Cooking: at a hearth, an entity converts raw food to cooked food. Cooked food gives more energy per unit (`cook_energy_multiplier`, modified by recipe and material). Requires fuel (tunable).

Storage: holds items; entities deposit and withdraw.

---

## 9. Combat and diplomacy

### Combat
- Stats: attack, defense, hp, damage_resistance. Melee adjacency.
- Aggression triggers: gene baseline, resource scarcity, genome distance to target (xenophobia), prior hostility, signals.
- Hostility memory: per-entity short memory and per-tribe ledger. Entities are more likely to be hostile toward those who were hostile to them or their tribe.
- Outcomes: injury, death (corpse created), flee.

### Diplomacy
- Per tribe-pair goodwill ledger in [-1, 1].
- Goodwill rises with: resource gifts, shared defense, cross-tribe mating, time without conflict.
- Goodwill falls with: attacks, killings, territory encroachment, resource theft.
- Entities with `generosity` gene may share food/items with outsiders; this raises goodwill.
- Entities may defend a friendly tribe's members under attack (gene + goodwill threshold).
- Goodwill above `merge_goodwill_threshold` plus proximity and genetics enables a merge (section 6).

---

## 10. Signals (player interface)

- N channels (default 8), param.
- Player places sources: channel, intensity, radius or shape, duration, position.
- Field diffuses and decays per channel, at reduced resolution.
- Each entity samples the field at its cell (via block lookup) and applies its per-channel gene weights: attraction, repulsion, aggression boost, build affinity.
- These weights are genes, so they evolve.
- Phase 6 adds entity-emitted signals (warning, food-found, and so on): entities emit into channels reserved for emergent communication. Emission is a gene-controlled behavior with an energy cost.

---

## 11. Observability

Required before Phase 6:
- Population over time; births, deaths by cause; sex ratio; age distribution.
- Gene distribution histograms (per gene, global and per tribe).
- Tribe count, size, and lifetime chart.
- Click-to-inspect entity panel (all state, genome, memory, current action and utility scores).
- Lineage tracking (parents, children, generation number).
- Event log (births, deaths, fights, splits, merges, unlocks, with filtering).
- Overlays: terrain, flora, structures, entities, tribes, signal channels, stat heatmaps (energy, aggression, any gene).
- Headless batch runner: runs N sims with parameter sets and seeds, writes CSV/JSON metrics, produces comparison plots.

---

## 12. Parameter registry

One registry, one source of truth.

```
{ "id": "entity.move_speed.default",
  "group": "entity.locomotion",
  "type": "float", "default": 1.0, "min": 0.1, "max": 10.0,
  "desc": "Cells per tick at gene value 1.0" }
```

Requirements:
- Loaded from JSON in `config/`. No parameter hardcoded in sim code.
- Runtime-changeable through a debug UI (live tuning) for non-structural params.
- Saved with every save file and every batch run (so runs are reproducible).
- Presets: named parameter sets (e.g. `sparse_world`, `harsh_winters`, `high_mutation`).
- Parameter groups to keep hundreds of params navigable.

---

## 13. Performance plan

Target: provisional 10 ticks/s at 100k entities on 4096x4096. Hard minimum to proceed: 5 ticks/s. Rendering at a separate frame rate, decoupled.

Phase 1 spike (language decision):
1. Implement in GDScript with packed arrays: 100k dummy entities, random-walk plus simple gradient seek, one-per-cell conflict resolution, perception queries with radius ~8, decisions staggered every 10 ticks.
2. Measure ms per tick with a profile harness (headless).
3. If >= 10 tps: stay GDScript, re-test at each phase. If 5-10: optimize and decide. If < 5: build the Rust GDExtension core and port, keeping the same data layout and API.
4. Report numbers to the user. The user will evaluate on their machine.

Levers if over budget: multithreading, spatial hash tuning, decision interval, perception radius, LOD for far/idle entities, chunking, reduced field resolution.

---

## 14. Save / load, seeds, speed

- Seed in every run. Seeds and registry saved with each save file.
- Save/load full world state to a binary format with a version header.
- Speed controls: pause, 1x, 2x, 5x, 20x, max (limited by hardware), single-step.
- Replay: a deterministic run can be replayed from seed + parameters + recorded signal events.

---

## 15. Repo layout

```
evosim/
  project.godot
  config/            parameters.json, substrates.json, flora.json, materials.json,
                     genes.json, recipes.json, presets/
  sim/               core: world, entities, genome, decisions, tribes, ...  (headless-capable)
  ui/                renderer, overlays, inspector, charts, signal tools
  tools/             batch runner, plot scripts
  tests/             unit + determinism + performance tests
  docs/              MASTER_SPEC.md, phases/, DECISIONS.md, PERF.md
```

If the core moves to Rust: `sim/` becomes a Rust crate, with the same module layout and a thin GDExtension binding in `ext/`.

---

## 16. Working agreement for Claude Code

- Read this spec and the current phase prompt before writing code.
- Do one phase at a time. Do not start the next phase.
- Keep `docs/DECISIONS.md` updated with every non-obvious choice and why.
- Write tests for determinism (same seed gives same hash of world state after N ticks) from Phase 1 onward.
- At the end of each phase: run the tests, run the headless perf check, update `docs/PERF.md`, and write a short summary with what works, what doesn't, and proposed parameter defaults.
- Placeholder parameter values are fine, but mark them `"tuned": false` in the registry.
- If a requirement is ambiguous, stop and ask rather than guessing on anything that changes the data layout.

---

## 17. Open items (to be resolved by observation)

- Final tick-rate target (set after the user sees the spike run).
- Founder defaults (Phase 5 sweep).
- Whether juveniles need parental feeding (tunable, default off at first).
- Whether corpses are edible by default (tunable).
- Weapon and armor items (deferred; combat stats come from genes and materials at first).
- Terrain editing, spawning, and live gene editing by the player (deferred; signals only for v1).
