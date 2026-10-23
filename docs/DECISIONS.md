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
