# Decisions

Non-obvious choices and why. Newest phase at the bottom. If a decision here conflicts with
`MASTER_SPEC.md`, the spec wins until the spec is updated.

## Phase 1

### Data layout

- **u16 and u32 layers.** Godot has no packed u16/u32 arrays. `structure_hp` (u16) is a
  `PackedByteArray` with 2 bytes per cell, accessed through `World.get_structure_hp()` /
  `set_structure_hp()` (little-endian `decode_u16`/`encode_u16`). `corpse_id` and
  `occupancy` (u32) are `PackedInt32Array`; ids stay below 2^31. In Rust these become `Vec<u16>`
  and `Vec<u32>` with identical bytes.
- **Layer order is the save and hash order** (`World.LAYERS`). Append new layers at the end and
  bump `SaveLoad.FORMAT_VERSION`.
- **`resize()` is always followed by `fill(0)`.** Godot does not promise zeroed memory on resize,
  and garbage would break determinism.
- **`tribe_territory` is not allocated yet.** The spec marks it optional and derived, and Phase 1
  does not list it. Add it when tribes exist (Phase 8).
- **Packed arrays alias by reference in GDScript** (verified on 4.6.1): `var a := world.substrate`
  then `a[i] = v` writes through to the world, with no copy. Hot loops copy array references into
  typed locals for speed.

### Parameters

- **Every tunable is in `config/parameters.json`**, including UI values (group `ui`), so there is
  one place to look. Unit conventions (`Units.MILLI`), direction tables, and file-format constants
  are definitions, not tunables, and stay in code.
- **`structural` flag.** Map size, seed, and terrain-shape params need a world rebuild. The
  registry locks them once a world exists; `set_value` refuses them while locked, and
  `restore_snapshot` (loading a save) bypasses the lock.
- **Out-of-range overrides are clamped and reported, not rejected**, so a preset written for an
  older range still loads. Wrong types and unknown ids are rejected.
- **Terrain frequency is `features_per_map`**, not raw noise frequency, so a preset that changes map
  size keeps the same look at a different scale.

### Terrain

- **FastNoiseLite (native) generates elevation and moisture images**, normalized to 0..255 over
  the map, so thresholds behave like quantiles and are independent of octave count.
- **Classification is a 64K lookup table** indexed by (elevation byte, moisture byte), giving
  substrate, moisture, and fertility. The per-cell GDScript work is three table reads, about 2 s at
  4096². Generation takes 5.5 to 7.5 s total, dominated by noise.
- **Lakes come from moisture**: very wet low and mid land floods. **Sand near water** is a beach
  band just above sea level in elevation, not a true distance-to-water. That is cheaper, and good
  enough until flora needs real shorelines. **Rock** is high elevation. Defaults give roughly
  water 32%, soil 44%, rock 16%, sand 5%, mud 2% (all `tuned: false`).
- **Substrate `allows_water_crossing` is read as "entities may enter this cell"** (false for water).
  `allows_flora` uses 255 as a placeholder bitmask until Phase 2 defines flora types.

### Determinism and RNG

- **Pinned engine version: Godot 4.6.1-stable.** Golden hashes are pinned on this version:
  `test_rng` (seed derivation) and `test_world::test_world_hash_is_pinned` (`test_tiny` preset,
  seed 1337). Terrain comes from the engine's FastNoiseLite, so an engine upgrade may change
  world hashes. Upgrade deliberately: re-run the tests, and if only the golden world hash changes,
  re-pin it and note the new version here.

- **One stream per subsystem, seeded by SHA-256 of `(master seed, stream name)`.** That is stable
  across runs, platforms, and engine versions, unlike `String.hash()`. Creating a new stream never
  shifts another's sequence (tested). Seed derivation is pinned by golden-value tests.
- **Counter-based randomness for parallel phases.** `Rng.hash3(seed32, a, b)` gives 32 bits that
  depend only on the inputs, so results do not depend on thread scheduling. All intermediates stay
  below 2^63, so it is bit-identical in GDScript and Rust.
- **Fixed-point integers (thousandths) for quantities that accumulate every tick** (movement
  progress, energy). No float drift, and portable to Rust.
- **RNG stream states are saved** (as decimal strings, since JSON cannot hold 64-bit ints exactly).
  The spec lists seed + params + layers + tick, but without stream states a loaded game would
  diverge from the uninterrupted run. A test checks that save → load → continue matches.

### Performance spike

- **Dummy field = the fertility layer.** It is real data with a realistic spatial structure, and
  it needs no extra 16 MB layer.
- **decide:** with probability `seek_probability` (default 0.6), scan the (2r+1)² window
  and target the highest field value (ties: nearest, then scan order). Otherwise pick a random
  heading. The scan reads only the field, as in the spec. Entity-to-entity perception (spatial hash
  vs grid scan) is a Phase 3 measurement.
- **Speed is capped at 1 cell per tick** in the spike, so each entity resolves at most one step
  per tick. Multi-step movement needs per-step resolution and belongs in Phase 3.
- **Conflict resolution:** proposals are applied sequentially in entity order, rotated by a seeded
  random start each tick. A move succeeds only into an empty cell, so one-per-cell holds and swaps
  are impossible by construction (A cannot enter B's cell while B is in it). Following into a cell
  vacated earlier in the same pass is allowed. A blocked entity tries heading+1 / heading-1 (order
  flipped by parity), otherwise waits with its progress capped at one step.
- **decide and propose run on the WorkerThreadPool.** They only write each entity's own slots. Group
  tasks **must be submitted high-priority**: low-priority tasks are capped to about 30% of the pool
  (2 of 8 threads here), which silently halved the speedup. Results are identical for 1, 2, 3, and
  8 threads (tested).
- **Never copy, duplicate, or resize sim arrays during a parallel phase; copy-on-write would break
  determinism silently.** Worker chunks write into shared packed arrays in place. A copy made
  mid-phase sends some writes to a private buffer that is then discarded, and nothing errors.
- **resolve stays sequential.** A parallel version needs claim arbitration (atomics) that GDScript
  lacks. It is now over half the tick at 100k (see PERF.md).

### Runtime and rendering

- **The sim runs on its own thread** (`SimRunner`), paced by `sim.base_tps` × speed, so render frame
  rate does not depend on tick cost. The renderer gets entity positions as snapshots the sim thread
  copies between ticks. `hold()` parks the sim thread for save/load/respawn.
- **The windowed app leaves cores free for rendering.** With `sim.worker_threads` = 0 (auto), the app
  uses cores minus `ui.render_reserved_threads` (default 2). Using all 8 cores for decide/propose
  starved the main thread: 105 of about 1000 frames went over 18 ms, versus 1 with 6 workers, at
  about 9% sim throughput cost. Headless runs use every core. The override lives in `ui/main.gd`, so
  `sim/` has no notion of a renderer.
- **Entities render as GPU points.** One draw call; the vertex shader reads x/y from two RGBA8
  textures holding the raw int32 arrays (`VERTEX_ID` → texel). Updating positions is two native
  uploads per snapshot, with no per-entity GDScript on the main thread.
- **Layer overlays are one R8 texture each** through one shader (palette mode for ids, ramp mode
  for 0..255 values). Zoomed out, the shader averages up to 4×4 samples per pixel
  (`ui.layer_supersample_max`) so panning does not shimmer. New overlays subclass `ui/overlays/overlay.gd` and
  call `WorldView.register_overlay()`; the HUD picks them up automatically.

### Save format

- `"EVOS"` magic, u32 format version, JSON header (seed, tick, size, param snapshot, RNG states,
  substrates.json hash, world hash), then named blocks (raw size, stored size, zstd when smaller).
  Writes go to a `.tmp` file then rename. Load re-hashes the world and rejects a mismatch, and
  warns if `substrates.json` changed since the save. A 4096² save with 100k spike entities is
  8 MB, 1.8 s to save, and 2.0 s to load and verify.

### Tooling

- **No `class_name`.** Scripts reference each other with `preload()`, so headless runs work on a
  fresh clone without an editor import step building the global class cache.
- **Minimal custom test runner** (`tests/run_tests.gd`), not GUT, so there is no addon dependency.
- **Godot binary path:** `tools/godot.sh` uses `$GODOT`, then the untracked one-line file
  `tools/.godot_bin`, then `godot` on PATH.

## Phase 2

### Time

- **Time is a pure function of the tick.** Tick 0 is midnight at the start of spring, year 0, so
  time needs no saved state. Defaults: 4 ticks/hour, 24 hours/day, 20 days/season, which gives
  96 ticks/day and 7,680 ticks/year (12.8 minutes per year at 1x). A year is always four seasons,
  because `seasonal_yield[4]` is fixed by the spec.
- **Daylight share per season** (`time.daylight.*`) sets day length. `daylight(tick)` (night_light
  to 1, with linear twilight ramps) is the day/night factor exposed to rendering and to later
  systems (visibility, energy loss).

### Sampled environment pass

- **One pass updates moisture, fertility, and flora** for each sampled cell
  (`sim/env/env_system.gd`): one random access per cell instead of three. `env.sample_fraction`
  0.002 gives 33.5k cells per tick at 4096², so each cell is updated about every 500 ticks
  (5.2 days). Every per-day rate is scaled by that expected interval, so the sample fraction
  changes noise and cost, not dynamics.
- **Day/night enters growth through the season's daylight share**, integrated over the update
  interval: growth uses `day_growth * share + night_growth * (1 - share)`. A cell updated at
  midnight still gets its five days of light. Long summer days grow more; fungus (night_growth 1.0)
  favours long nights.
- **Deterministic under threads, by bands.** The map is split into `env.bands` (64) horizontal
  bands. Even bands run in parallel, then odd bands. A band writes only its own cells. Its only
  outside reads are moisture neighbours on its edge rows, which lie in bands idle that pass.
  - Each band draws from its own xorshift32 sequence, seeded by `Rng.hash3(seed, tick, band)`.
  - Seeds are collected per band and applied sequentially afterwards, in band order.
  - The band count is a parameter, not derived from the thread count, so results are
    identical for any thread count (tested at 1, 3, and 8 threads).
- **Copy-on-write guard.** Before dispatch, `Parallel.ensure_unique()` writes once to each layer
  the bands will write. If anything shares the buffer, the copy happens on the sim thread, not
  racing inside workers.
  - Measured on 4.6.1: `duplicate()` is lazy (the next write pays a 16 MB copy, 3.3 ms).
    `Image.create_from_data` shares the buffer while the image lives. `slice(0)` is a real copy
    (7.6 ms per 16 MB).
  - Group tasks go through `sim/core/parallel.gd`, which always submits high-priority (see
    Phase 1).

### Moisture

- **The moisture layer is dynamic.** Each sampled land cell relaxes toward a target and diffuses
  toward its 4 neighbours. Water cells are never updated and stay at 255, so they act as sources
  and the shore is wetter.
  - Target = climate grid + season offset + rain.
  - The climate grid is the terrain's own moisture noise, sampled every `env.climate_block` (16)
    cells and mapped to [0.12, 0.8]. It is regenerated from the seed after a load and never
    saved (`TerrainGen.noise_seeds()` reproduces the terrain's noise seeds statelessly).
- **Weather is map-wide rainy days.** A day is rainy if `hash(seed, day) < rain_chance` (0.3).
  The rain boost is `rain_moisture` times the share of rainy days in the last 7, so wet and dry
  spells show up without per-cell weather state. Turn it off with `env.rain_enabled`.

### Fertility

- **Fertility relaxes toward a natural level**: substrate `fertility_base` × moisture, the same
  formula terrain generation uses. The rate is 1% of the gap per day. Growth consumes fertility
  (`fertility_consumption` per biomass grown), and harvest drains it
  (`flora.harvest_fertility_drain`, 0.5 per biomass removed). The regeneration stands in for
  nutrient cycling until decomposition exists (Phase 3), and is what lets fertility recover.

### Flora rules

- **Growth per update:**
  rate × dt × light × seasonal_growth × moisture response × fertility response × stall.
  - Moisture response is linear up to `moisture_need`.
  - Fertility response is linear up to `flora.fertility_saturation`.
  - Stall is the growth-stall hook: a lookup by `structure_material`, 1.0 everywhere until
    Phase 7 fills it from `materials.json`.
  - Below `moisture_need × wilt_fraction` a plant wilts; below `flora.starve_fertility` it
    starves. Either way it loses biomass instead of growing.
- **Seeding happens only when mature and only while the season's growth is above 0.** A winter
  stall stops seeding too. Seeds land on a random cell within `seed_spread_radius`, and take
  only on an empty, allowed cell that is wet enough not to wilt.
- **Janzen-Connell crowding** (`flora.crowding_penalty`, 0.2): each same-type neighbour adds 20% to
  a seed's failure chance. Without it, one cell per plant makes this a lottery: whichever type has
  the best seeding-to-mortality ratio takes all shared habitat. Fungus took 50%, or grass took 63%,
  depending on rates.
- **Fixed point:** growth factors are in 1/1024 units, and biomass increments use stochastic
  rounding from the band's xorshift sequence.
- **Fields beyond the spec's list in `config/flora.json`:** color, max_biomass, maturity,
  seed_chance, mortality, seasonal_growth[4], day_growth, night_growth, initial_cover.
  - `substrate_mask` is a list of substrate names.
  - A type may grow on a substrate only if both its `substrate_mask` and the substrate's
    `allows_flora` bit (id − 1) allow it.
- **Known dynamic: slow succession.** Total coverage settles within a few years. Long-lived woody
  types (shrub, berry bush, tree) keep gaining share slowly at grass's expense, which is classic
  succession without disturbance. Grazing and harvest by entities (Phase 3) are the natural
  counterweight. Until then the flora report prints per-type drift. All values are
  `tuned: false`.

### Items and harvest

- **`config/items.json`** defines item ids for the `item_type` layer. Phase 2 has only harvest
  products.
- **`harvest(cell, amount)`** returns `{item, name, qty, nutrition, removed, type}`:
  - `qty` = removed biomass × `seasonal_yield[current season]`
  - `nutrition` = qty × the type's nutrition
  - A plant harvested to zero dies.
- **`harvest`, `plant`, and `apply_brush` are not thread-safe.** Call them between ticks or from a
  sequential phase. The UI's debug brush goes through `SimRunner.submit()`, which runs commands
  on the sim thread between ticks.
- **Flora totals (coverage, biomass per type) are kept incrementally** and saved in the save header.
  A load without them recounts. Tests check that the incremental totals match a full recount.

### Save format version 2

- **`SaveLoad.FORMAT_VERSION` is now 2** (Phase 1 wrote 1). Flora, fertility, and moisture are live
  sim state, and the header adds the flora totals, a hash of `flora.json`, and a readable time.
  The loader still reads version 1 (tested); it recounts flora totals for those files.
- **What is and is not saved.** Every stateful RNG stream (terrain, flora.init, spike.*) is saved in
  the header's `rng` map. In-game time, weather, the climate grid, and the env.sample /
  env.weather hash seeds are pure functions of the seed and tick, so they are rebuilt on load,
  not saved. A test checks that each rebuilds identically.

### Golden hashes

- **The terrain-only golden hash is unchanged from Phase 1** (`8ad937c4…`, Godot 4.6.1-stable).
  World generation now also plants initial flora, so the full initial world got its own golden
  hash (`test_initial_world_hash_is_pinned`, `9c8798ab…`).

### Renderer and UI

- **The UI never reads live world layers.** Parallel phases now write them.
  - Overlays get `slice(0)` copies in snapshots taken on the sim thread, for visible dynamic
    layers only, at `ui.layer_refresh_hz` (1 Hz).
  - WorldView uploads at most one 16 MB texture per frame.
  - The HUD's cell readout is a probe the sim thread answers between ticks
    (`SimRunner.request_probe`).
- **Flora overlay:** color by type, opacity by biomass relative to the type's max (premultiplied, so
  zoomed-out averaging blends correctly), optional season tint.
- **Day/night shading** is a CanvasModulate tinted by `daylight(tick)`. It affects the world but not
  the HUD.
- **Debug brush:** harvest everything, or plant mature flora of a type, in a disc. While a brush is
  active, left-drag paints and the camera pans with middle or right drag.

### Tooling

- **The test runner now fails on a test file that does not compile**; before, it skipped it
  silently.
- **New tools:** `tools/flora_report.gd` (multi-year coverage, yield, and winter-stall report, CSV
  and SVG), `tools/harvest_experiment.gd` (fertility under harvest versus a control region),
  `tools/svg_chart.gd` (no plotting libraries on the dev machine), and `tools/thread_hash_check.gd`
  (runs the same seed at several thread counts and prints the hashes).

## Phase 3

### Entities replace the spike

- **The Phase 1 performance spike is gone.** Its doc said Phase 3 would replace it. Real entities
  reuse its one-per-cell resolve (rotating seeded start, no swaps, sidesteps), and its conflict tests
  are ported to `tests/test_movement.gd`.
- **Save format version 3** adds entity and corpse blocks. Versions 1 and 2 still load (no
  entities). Their spike blocks are skipped, and their occupancy layer, which may hold spike ids, is
  cleared.

### Entity store

- **SoA with slot recycling.** Entity id = slot + 1 (what `world.occupancy` stores). A dead slot goes
  on a free list and is reused lowest-first with `generation + 1`, so `(slot, generation)` names one
  entity over time; the inspector selects by it.
- **resize() does not zero memory**, so every per-slot array gets defined values when capacity
  grows. An uninitialised `proposal` in an empty slot was being "applied" at (-1, -1), writing to
  occupancy through a negative (wrapping) index; this is caught by the 10,000-tick invariant test.
- **Genome-shaped stats.** One float per gene from `config/genes.json` (name, group, min, max,
  default, desc, cost), 11 genes, stored entity-major in one flat array. Integer stats are derived
  from the genome at spawn, in thousandths: max/sate energy, the energy costs (base burn, rest burn,
  sense burn, move cost; spec §4.1.1, see "Derived energy costs" below), speed, sense radius,
  memory capacity. The genome is the source of truth: Phase 4 sets a genome and re-derives.
- **Founders get the defaults** plus optional uniform jitter (`founders.gene_jitter`, default 0).
  **Their starting energy is staggered**, uniform in [`founders.energy_min`, 1] × max, so the whole
  population does not get hungry on the same tick.

### Items own nutrition

- **`nutrition` moved from `flora.json` to `items.json`.** No code path reads nutrition from flora:
  `FloraTable` has no such field, and a test checks it.
- **Every item is edible; food value is `nutrition`.** Placeholders, ranked: berries 40,
  mushrooms 25, reeds 10, hay 6, twigs 2, wood 1.
- **Eating:** a bite harvests `entity.bite_biomass` through `env.harvest_removed()`, then
  `env.yield_qty()` turns the biomass removed into items (seasonal yield). The gain is exactly
  items × nutrition × the `digest_efficiency` gene (the float gene value, not a fixed-point copy;
  tested per item).
- **Corpse nutrition is a registry value** (`corpse.nutrition_per_mass`).
- **`harvest_removed()`/`yield_qty()` are a Dictionary-free fast path** for entities.
  `harvest()` (Phase 2 API) is built on them.

### Perception

- **Spatial structure, chosen by profiling** (`tools/perception_bench.gd`, single-threaded, 4096²
  map, radius 5):

  | per decision at 100k entities | µs |
  |---|---:|
  | entities via the grid, occupancy read per cell | 5.1 |
  | entities via the grid, native row counts (`slice` + `count`) | 2.5 |
  | entities via a 16×16-bucket spatial hash (rebuilt per tick + query) | 6.9 |
  | corpse + water reads per cell | about 8 |

  **Entities: grid, by native row counts.** It is cheaper even before threading, and it
  parallelises, while the hash rebuild (25 ms per tick at 100k) is sequential.
- **Corpses and water: 8×8 perception blocks** (`entity.perception_block`). The corpse table keeps
  lying-corpse counts per block (updated on create, pick-up, drop, and removal; checked by its
  invariants). Water is a static block mask built at setup with native `find()`. Perception reads
  corpse_id and substrate only inside blocks that have any. That cuts about a third of the scan
  cost (23.9 to 15.9 µs per decision in the bench).
- **The scan finds** the best food (by expected rate), the entities in sight (count + centroid), the
  nearest lying corpse, and the nearest water. Water is perceived and recorded (`water_dist`, shown
  in the inspector) but nothing acts on it yet: there is no drink action in Phase 3's list.
- **Decide caches references to the world layers** it reads (`_ft`, `_occ`, …). Going through
  `world.<layer>` costs a dynamic lookup per access. Layers are only replaced on load, which rebuilds
  the entity system.
- **Optimised after the first perf gate (9.9 ticks/s at 100k)**, with the decisions unchanged
  (`tools/decide_bench.gd` hashes everything decide writes, before and after). Decide went from
  32.0 to 18.0 µs per decision, and 100k from 9.9 to 17.3 ticks/s:
  - Entities in sight are counted per row with native `slice()` + `count(0)`. The x half of the
    crowd centroid is summed only when a crowded wander is chosen.
  - The food scan goes outward from the entity's own row. Once no plant at a row's distance could
    reach the best rate so far (even the season's richest type at a full bite), it stops; columns
    are clipped the same way.
  - Within a row, a plant type whose full bite cannot reach the best rate at the row's nearest
    distance is skipped before its biomass is read.
  - Ties go to the lowest cell index, which is what the row-major scan picked, so the chosen
    plant is identical. The bounds only skip plants that cannot tie or win.

### Decisions (utility)

- **Hunger** h = (sate − energy) / sate, clamped to 0..1, where sate = `food_needed_to_sate` × max.
- **Food choice weighs nutrition against time and energy.** The rate of a plant is
  `min(biomass, bite) × seasonal_yield × nutrition / (distance × ticks_per_step + 1)`: energy per tick
  of travelling and taking one bite. Utility uses quality q = rate / (rate + burn ×
  `entity.food_rate_scale`), so low-value food scores low next to better food, and is still taken
  when nothing better is in sight (tested both ways).
- **Utilities** (genes in italics):
  - forage = *forage* × h × q
  - eat corpse = same shape, with corpse nutrition, only if `corpse.edible`
  - seek remembered food = *forage* × h × `memory_trust` × freshness, only with no food in sight
  - wander = *explore* × (`wander_base` + `wander_hunger` × h when no food is in sight) +
    `crowd_weight` × crowding (a remembered food cell does not remove the hunger term: Flaw A below)
  - rest = *rest* × (1 − h)
  - pick up corpse = *carry_corpse* × (1 − h)
  - drop = `drop_weight` × carried time + h

  The argmax wins, ties going to the lower action index, and scores are stored per entity for the
  inspector.
- **Stagger:** an entity decides when `(tick + slot) % entity.decision_interval == 0`, or on the next
  tick after its action ended (action NONE).

### Crowds (found while testing survival)

- **The first runs starved entities that had food 2-4 cells away.** Founder groups start dense, and
  sated entities rest where they ate, so crowds block the food and every re-decision picks the same
  blocked plant. Three fixes, each placeholder-tuned:
  - Plants with another entity standing on them are not food candidates.
  - After `entity.stuck_ticks` (6) blocked ticks the entity gives the target up (`avoid`) and heads
    away from it.
  - Crowding (entities in sight / `entity.crowd_ref`) adds to wander utility, and a crowded wanderer
    heads away from the crowd's centroid.
- **Effect** on a 256² test map with grown flora: deaths over 60 days went from 63 to 1 (of 271).
- **At full size, 27% of 5,000 founders still starved in 20 days.** Every death was on rock or
  sand patches (about 8 plants within 10 cells, versus about 230 around survivors). Founder groups
  could be centred anywhere passable, and 16% of the map is rock. Two more fixes:
  - **Group centres must be on habitable land**: fertility ≥ `founders.centre_min_fertility`. The
    spec's "randomly placed with minimum spacing" still holds over that land.
  - **A hungry entity with no food in sight or memory keeps its wander heading**
    (`entity.search_hunger`), searching in a straight line instead of circling.
  - Result: 99.3% survive 30 days, and every survivor has eaten 3+ meals.
- **Two flaws remained (found by tracing the 39 deaths of a 60-day run), fixed before commit:**
  - **Flaw A: a stale memory made hungry entities rest while starving.** Any remembered food
    cell removed wander's hunger term, while seek (h × trust × freshness) lost to rest at most
    hunger levels. An entity rested for days, with food just beyond sight, until its memory
    expired after `entity.memory_days`; one went from 565 to 322 energy that way with 37 plants
    within 10 cells. **Fix A:** wander always keeps its hunger term when no food is in sight; a
    memory only adds the seek option. Seek beats wander while freshness > explore × (wander_base +
    wander_hunger × h) / (forage × h × trust): 0.575 at hunger 0.67, 0.5 at hunger 1 (tested).
  - **Flaw B: crowd avoidance overrode the hungry search.** A crowded wanderer turned away from
    the crowd's centroid at every decision, so a hungry founder group stranded on bare rock
    random-walked in place (a 225-entity cluster at founder density: slowest member 4 cells of
    net displacement in 240 ticks, median 53). **Fix B:** a searching entity (hungry, no food in
    sight, and wandering won, so any memory was too stale to seek) keeps its heading crowd or
    not, and only non-searchers turn away from crowds. No new per-entity field: the heading is
    already stored, and "searching" is recomputed at each decision. After the fix the slowest
    member moves 115 cells (test: all ≥ 100 in 240 ticks).
- **Open after the fixes: deaths rose from 39 to 58 of 5,000** in the 60-day abundant run (98.8%
  survive; the bar is 95%). All 58 died on rock with no plant within 10 cells; 47 never ate.
  Traced causes, all in the placeholder utility, not code faults:
  - **The search is a straight line in a random direction that never turns back.** With sense
    radius 5, food 6 cells behind the searcher is lost; searchers walked 130-145 cells across rock
    and died. Fix B sends more entities on this search (crowded ones used to random-walk locally,
    which sometimes found nearby food).
  - **Memory freshness is wall-clock time** (`entity.memory_days`). Rest beats seek at low hunger
    even with a fresh memory (0.34 vs 0.21 at hunger 0.32), so an entity rests until the memory
    is past the seek/wander crossover (about 0.6 freshness, 2.4 days), then searches at random
    instead of going back.
  - **Crowding inflates wander even with food in sight** (wander 0.6-0.7 with 14 neighbours
    against forage 0.39).
  - Options, not applied (they change behaviour): a correlated random walk or a return toward
    the last remembered food after some ticks of fruitless search; seek scored without the rest
    trade-off once a memory exists, or a higher `entity.memory_trust`; crowd weight scaled by
    (1 − hunger).

### Movement

- **Cost-weighted local step:** of the direct heading to the target and its two neighbours, take the
  passable cell minimising remaining Chebyshev distance plus `entity.path_cost_weight` × terrain move
  cost. No per-entity A*.
- **Speed accumulator** as in the spike, capped at one step's cost, so blocked entities do not bank
  moves. Carrying a corpse multiplies speed by `entity.carry_speed_factor`. Each cell moved costs
  the derived `move_cost` × terrain cost, × `entity.carry_move_cost_factor` (1.5) while carrying.
  The carry factor on energy is new in the follow-up: before it, carrying only slowed movement.
- **The death check runs after every per-tick energy cost.** Propose charges burn (base, or rest
  while resting) and sense burn; resolve charges each move; then the deaths phase kills every
  entity at or below zero, in slot order, before interact. Before, the check ran between propose
  and resolve, so a move could leave a living entity at negative energy for a tick, and it could
  even eat its way back in interact. Tick order is now decide, propose, resolve, deaths, interact.
  The invariant check rejects a living entity with energy ≤ 0.

### Corpses

- **Corpse table:** SoA plus the `corpse_id` layer, one corpse per cell; a new or dropped corpse on an
  occupied cell merges into it. `owner_tribe` is stored and stays 0 until tribes.
- **Decay:** every `corpse.update_interval` ticks a lying corpse releases a share of its soil
  nutrients (mass × `corpse.soil_nutrients_per_mass`), evenly over the land cells within
  `corpse.spread_radius`, until `corpse.decay_days` pass, when it is removed.
  - Fertility near corpses rises; Phase 2's regeneration then slowly pulls it back toward the
    natural level.
  - Carried corpses do not decay.
- **Eating corpses** is off by default (`corpse.edible`, a spec open item).
- **A death on a cell that already holds a corpse merges into it:** the new body's mass and soil
  nutrients are added to that corpse and its decay timer restarts, so nothing is lost. Corpses do
  not block movement, so a starving wanderer can step onto one and die there: 18 of 5,000 deaths in
  the no-flora scenario, hence 4,982 corpse sites.
- **No entity carries a corpse at the default genes.** Pick-up scores *carry_corpse* × (1 − h)
  against rest's *rest* × (1 − h), and 0.15 < 0.5, so rest always wins (0 pickups in the
  scenarios). Carrying works (tested) and becomes reachable once Phase 4 varies the weights.

### Derived energy costs (spec §4.1.1)

- **Genome 13 → 11 genes.** `base_energy_burn` and `move_energy_cost` were genes, so under
  mutation lower values would have been free upgrades (spec principle 4). They are now derived
  from the other genes when the genome is fixed (at spawn; at birth from Phase 4), stored in SoA
  arrays `base_burn` and `move_cost` (plus `rest_burn` = base × `entity.rest_burn_factor` and
  `sense_burn`), and never recomputed per tick:
  - base_burn = burn_floor + k_capacity × max_energy / 1000 + k_speed × move_speed² + k_digest ×
    digest_efficiency + k_memory × memory slots + k_hp × max_hp / 100
  - sense_burn = sense_cost_per_cell × (2 × sense_radius + 1)²
  - move_cost = move_cost_floor + move_cost_k_speed × move_speed²
- **Calibrated to the old defaults**, so a default genome behaves exactly as before:
  base_burn 0.600, move_cost 0.400, sense_burn 0.100 per tick (tested; the 512² checkpoint run's
  world and behaviour hashes are unchanged). Coefficients (all `tuned: false`, every k > 0):

  | parameter | value | at the default genome |
  |---|---:|---:|
  | `entity.burn_floor` | 0.16 | 0.16 |
  | `entity.burn_k_capacity` | 0.1 per 1000 max_energy | 0.10 |
  | `entity.burn_k_speed` | 0.25 per speed² | 0.09 |
  | `entity.burn_k_digest` | 0.15 per unit | 0.12 |
  | `entity.burn_k_memory` | 0.02 per slot | 0.08 |
  | `entity.burn_k_hp` | 0.05 per 100 hp | 0.05 |
  | `entity.sense_cost_per_cell` | 0.1 / 121 = 0.000826… | 0.100 at r = 5 |
  | `entity.move_cost_floor` | 0.22 | 0.22 |
  | `entity.move_cost_k_speed` | 0.5 per speed² | 0.18 |

  The split is a placeholder: the floor is the cost of being alive at all, speed costs both at
  rest and per cell, and the gene terms are sized so a gene at its maximum costs noticeably more
  (speed 1.0: base burn +0.16 and move cost +0.32 per cell; max_energy 5000: +0.4).
- **Sense cost is per scanned cell, (2r + 1)², not linear in the radius,** because the benefit
  (cells seen) scales with area. At r = 5 it equals the old linear cost (0.02 × 5); r = 8 costs
  0.24 instead of 0.16.
- **Memory and sense costs use what the entity actually gets**: the rounded, clamped memory
  capacity and sense radius, not the raw gene floats.
- **Each cost is summed in floating point from the gene values and rounded once to milli**, at
  spawn. Same inputs give the same integer on every run; nothing per tick touches floats.
- **The inspector shows the derived costs** (base, resting, sense, move) under the genome.
- **move_speed default stays 0.6** (cells per tick on cost-1 terrain), the value the costs are
  calibrated at. The spec's registry example (§12) said 1.0 (min 0.1, max 10); it and §5.1 now say
  0.6 (min 0.05, max 1.0), matching `genes.json`.
- **Save format version 3 is redefined** (it was never committed): the entity blocks include
  `entity.base_burn` (was `entity.burn`), `rest_burn`, `sense_burn` and `move_cost`, and the
  genome blocks have 11 genes. No migration. Versions 1 and 2 still load.
- **Version 1 loads were leaving spike ids in the occupancy layer** (found by a new test that writes
  real pre-v3 layouts). The clear was `(world.occupancy as PackedInt32Array).fill(0)`, and in Godot
  4.6 `(x as PackedInt32Array).fill()` fills a temporary copy. It now goes through a typed local
  variable, which writes through. That was the only mutating call on an `as` cast in the code.

### Other

- **Perf gate: stay on GDScript.** 100k entities with mature flora run at 17.5 ticks/s (summer,
  after the decide optimisation and the follow-up fixes; 9.9 before the optimisation), and 16.1
  to 16.2 with a hungry population (2× base burn, or flora thinned to 10%); details in `PERF.md`.
  The gate uses founder-spawned populations, a 2,000-tick entity warmup (500 was too short for the
  hunger cycle to settle), and `tools/profile.gd --season` so every row is measured in the same
  season.
- **`env.bands` is structural** (Phase 3 scope 13): it changes results for a seed, so it locks with
  the world (tested).
- **The HUD and inspector never read live sim arrays.** The inspector asks the runner for an entity
  probe (one-shot, answered between ticks), and spawning/clearing founders goes through
  `SimRunner.submit()`.
- **The inspector marks the decided action** (the argmax of the stored scores, same tie rule as
  decide), and shows the current action beside it. They differ once an action ends between
  decisions (sated, plant gone) or is given up (stuck): marking the current action would then
  point at a score that did not win.
- **New parameters (all `tuned: false`):**
  - `entity.*`: decision_interval, memory_slots, perception_block, memory_days, memory_trust,
    bite_biomass, rest_burn_factor, food_rate_scale, wander_base, wander_hunger,
    path_cost_weight, stuck_ticks, crowd_ref, crowd_weight, search_hunger, carry_speed_factor,
    carry_move_cost_factor, carry_days, drop_weight, birth_sex_ratio
  - `entity.*` derived-cost coefficients: burn_floor, burn_k_capacity, burn_k_speed, burn_k_digest,
    burn_k_memory, burn_k_hp, sense_cost_per_cell, move_cost_floor, move_cost_k_speed (an earlier
    draft's linear `entity.sense_cost` is replaced by sense_cost_per_cell)
  - `corpse.*`: edible, mass, nutrition_per_mass, bite_mass, decay_days, soil_nutrients_per_mass,
    spread_radius, update_interval
  - `founders.*`: groups, size_min, size_max, spacing, spread, centre_min_fertility, energy_min,
    gene_jitter
  - `ui.entity_color_by_sex`
  - Removed: `spike.*`.

### Renderer and UI

- **Entities are GPU points**: one mesh with a vertex per slot. Position, energy and max energy
  are read from RGBA8 textures holding the raw int32 snapshot arrays, and sex from an R8
  texture; dead slots (x = -1) are hidden. Colour by energy (red to yellow to green) or by sex,
  from the HUD or `ui.entity_color_by_sex`.
- **Clicking a cell** (press and release within 5 px, brush off) probes it. If an entity is
  there, the inspector follows it by (slot, generation) and refreshes at `ui.hud_refresh_hz`.

### Tooling

- `tools/profile.gd` replaces `tools/profile_spike.gd`: real entities from founder groups, an
  optional environment warmup, and a per-phase breakdown.
- `tools/decide_bench.gd`: single-thread µs per decision on a saved steady state, plus a hash of
  decide's output so optimisations can be checked for identical decisions.
- `tools/perception_bench.gd`: the hash-versus-grid measurement.
- `tools/entity_report.gd`: the abundant and scarce acceptance scenarios (CSV, SVG, summary).
- `tools/determinism_check.gd` and `tools/thread_hash_check.gd` take founders.
- App autotest `--autotest-inspect`: selects an entity through the click signal, checks the
  inspector's decided action against its scores, screenshots both colour modes, follows the
  entity, then clears and respawns founders through the HUD actions.
