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
