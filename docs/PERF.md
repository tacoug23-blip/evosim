# Performance

## Phase 1 spike (GDScript)

### Setup

- **Machine:** Intel i7-9700K (8 cores / 8 threads), RTX 2060, Windows 11, 1920×1080 @ 119 Hz.
  Firefox and Steam were open (about 14% background CPU). No game running.
- **Engine:** Godot 4.6.1-stable, the official editor binary run headless. Its GDScript VM is a
  debug build; release export templates are typically somewhat faster. Not measured.
- **Workload:** the full 4096×4096 map, entities on random passable cells. Per tick:
  - decide: one tenth of the entities (interval 10, staggered by id) scan a 17×17 window (radius 8)
    of the fertility layer.
  - propose: all entities accumulate movement and apply terrain move cost.
  - resolve: one-per-cell sequential resolution with sidesteps.
- **Steady state:** tick cost grows as entities cluster on fertile ground (more conflicts), so the
  tables are measured after a 500-tick warmup, over 200 ticks
  (raw results: `docs/perf/phase-01/perf_clean_threads_0.json` for auto threads,
  `perf_clean_threads_1.json` for single-threaded).

An earlier round was measured while a 3D game (Enshrouded) used about 2.6 cores and the GPU. It gave
11.2 tps at 100k and made render timing unmeasurable. Those numbers are superseded by the ones
below.

### ms per tick

`sim.worker_threads = 0` (auto, all 8 threads, as in headless runs):

| entities | mean ms | p50 ms | p95 ms | max ms | tps (mean) | decide ms | propose ms | resolve ms | moves/tick | blocked/tick |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 1.73 | 1.73 | 1.96 | 2.31 | 576.6 | 1.31 | 0.27 | 0.14 | 299 | 0 |
| 10,000 | 4.51 | 4.46 | 5.31 | 5.92 | 221.6 | 2.18 | 0.53 | 1.80 | 3,128 | 171 |
| 50,000 | 26.14 | 25.82 | 28.94 | 34.14 | 38.3 | 10.16 | 2.51 | 13.46 | 15,098 | 5,219 |
| **100,000** | **57.10** | 57.03 | **60.73** | 64.37 | **17.5** | 19.19 | 5.07 | 32.83 | 26,889 | 19,904 |

`sim.worker_threads = 1` (single-threaded):

| entities | mean ms | p50 ms | p95 ms | max ms | tps (mean) | decide ms | propose ms | resolve ms |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 1.73 | 1.73 | 1.94 | 2.15 | 577.5 | 1.31 | 0.28 | 0.14 |
| 10,000 | 17.94 | 17.95 | 18.76 | 20.09 | 55.7 | 13.11 | 2.99 | 1.84 |
| 50,000 | 94.64 | 94.64 | 96.47 | 98.55 | 10.6 | 65.62 | 15.95 | 13.06 |
| **100,000** | **196.28** | 195.26 | 200.95 | 231.08 | **5.1** | 131.08 | 33.02 | 32.16 |

How the 100k number got here (the early steps were measured during the busy round, so treat them as
relative):

| step | ms/tick @ 100k | tps |
|---|---:|---:|
| straightforward single-threaded GDScript, early ticks | 256 | 3.9 |
| + decide/propose on WorkerThreadPool (default low priority: capped at 2 threads) | 115 | 8.7 |
| + high-priority group tasks (all 8 threads) | 57 | 17.6 |
| + resolve without div/mod or wraparound checks, early ticks | 53 | 18.8 |
| clean machine, steady state (after 500 ticks of clustering) | 57 | 17.5 |

1000-tick acceptance run (two runs, one-per-cell checked every tick): 54.4 and 55.4 ms/tick
mean, rising from about 46 ms over the first 100 ticks to about 59 ms over the last 100.

### Top three bottlenecks (100k, 8 threads, steady state)

1. **resolve, 33 ms (57%). Sequential, so this is the Amdahl ceiling.** It walks all 100k
   proposals one by one, and the cost grows with crowding: about 20k blocked entities per tick at
   steady state versus about 500 early on, each trying two sidesteps. Even if everything else cost
   zero, GDScript would top out at about 30 tps here.
2. **decide (perception scan), 19 ms (34%); 131 ms single-threaded.** 10k decisions × 289 cells per
   tick, about 45 ns per cell visited. It scales 6.8× on 8 threads.
3. **propose, 5 ms (9%); 33 ms single-threaded.** Per-entity movement bookkeeping for all 100k
   entities every tick.

Underlying all three: GDScript costs roughly 20 to 50 ns per VM operation, and these loops are
almost pure VM operations.

### Decision rule (spec section 13)

| | result | rule outcome |
|---|---|---|
| 100k, 8 threads, steady state | **17.5 tps mean** (16.5 at p95) | **≥ 10 → stay GDScript, re-test each phase** |
| 100k, single-threaded | 5.1 tps | 5-10 band |

**Recommendation: stay on GDScript for Phase 2, as the rule says, and re-measure at the end of
Phase 2.** The margin is 1.75× over the 10 tps target, on a dummy workload. Risks to watch:

- **Sequential resolve is already 33 ms** and grows with crowding. GDScript cannot parallelize it
  without atomics.
- **Phase 2 flora** updates by random sampling over 16.7M cells. That is per-cell GDScript work, the
  kind GDScript handles worst. It is the first real test of the margin.
- **Phase 3 entity logic** (utility scoring, memory, entity perception) will be several times
  heavier per decision than this spike. It parallelizes like decide does, but adds up.

Port trigger: if any phase's headless profile at 100k drops below 10 tps steady state, port the sim
core to a Rust GDExtension before continuing. The core is written for a mechanical port:
- SoA arrays map to `Vec`s.
- Quantities are fixed-point integers.
- Randomness is either PCG streams or the portable `hash3`.
- Resolve order is deterministic.

So a Rust core can be checked against these state hashes bit for bit. No Rust toolchain is installed
here, so the Rust speedup is an expectation, not a measurement.

### Other timings (4096², 100k spike entities)

| operation | time |
|---|---:|
| terrain generation (2 noise images + classification) | 5.3 to 5.5 s |
| world hash (SHA-256 over all layers, about 310 MB) | about 1.3 s |
| save (hash + zstd, 8 MB file) | 1.5 s |
| load + verify | 1.5 s |

### Rendering

Autotest: 10 s sweeping from fit-to-map (0.22 px/cell) to 24 px/cell while orbiting the map;
4096² world; 1600×900 window.

| scenario | avg fps | p50 ms | p95 ms | p99 ms | max ms | frames > 18 ms |
|---|---:|---:|---:|---:|---:|---:|
| sim paused, vsync on | **120.7** | 8.34 | 9.22 | 9.78 | 16.29 | **0** / 1175 |
| sim paused, vsync off | 2057 | 0.47 | 0.60 | 0.74 | 6.35 | 0 / 20101 |
| sim paused, pan-only sweep, vsync on | 120.9 | 8.35 | 9.15 | 9.66 | 10.81 | 0 / 1175 |
| 100k running at max, sim using 8 threads | 104.3 | 8.33 | 21.69 | 23.93 | 24.94 | 105 / 1012 |
| 100k running at max, sim using 7 threads | 119.4 | 8.34 | 9.93 | 15.05 | 25.26 | 5 / 1157 |
| 100k running at max, **sim using 6 threads (app default)** | **120.7** | 8.34 | 8.58 | 9.45 | 26.94 | 1 / 1174 |

**Acceptance (60 fps while paused): met.** Vsync-locked at the 119 Hz refresh, with 0 frames over
18 ms. Engine-measured GPU render time is 0.06 to 0.7 ms per frame, and CPU render time is about
0.1 ms.

When the sim thread uses every core for decide/propose, it starves the main thread and frames
hitch. The windowed app therefore leaves `ui.render_reserved_threads` (default 2) cores free when
`sim.worker_threads` is auto. That costs about 9% sim throughput (177 vs 197 ticks in 10 s at max
speed). Headless runs still use every core.

### Reproduce

The profile harness writes to `batch_output/` (gitignored). Copy runs worth keeping into
`docs/perf/<phase>/`. `tools/profile_spike.gd` and the spike were removed in Phase 3; check out
tag `phase-02-done` to rerun the Phase 1 and 2 commands below.

```bash
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --counts=1000,10000,50000,100000 --warmup=500 --ticks=200
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --warmup=500 --ticks=200 --set=sim.worker_threads=1
tools/godot.sh --headless --path . --script res://tools/determinism_check.gd -- --ticks=1000
tools/godot.sh --path . -- --autotest-render=10
tools/godot.sh --path . -- --autotest-render=10 --spike=100000 --speed=max
```

## Phase 2: flora and environment

Same machine and engine as Phase 1. Firefox and Steam were open; no game running. The full
4096² map; steady state after a 500-tick warmup, 200 ticks measured. Raw results are in
`docs/perf/phase-02/perf_p2_*.json`. The Phase 1 tables above predate the environment pass
(their code had none).

### Environment pass cost

The sampled environment pass (moisture, fertility, flora) at the default `env.sample_fraction`
0.002 updates 33,536 cells per tick, so each cell is updated about every 5.2 days.

Cost depends on how much of the map has plants, since sampled cells with a plant take the
growth path.

| flora state | threads | mean ms | p95 ms | per sampled cell |
|---|---|---:|---:|---:|
| **mature** (after 5 years: 5.49M plants, about 64% of plantable land) | 8 (headless default) | **10.15** | 10.93 | — |
| young (500 ticks in: about 10% coverage) | 8 (headless default) | 6.78 | 7.52 | — |
| young | 6 (app default, 2 cores left for rendering) | 7.61 | 7.96 | — |
| young | 1 | 29.28 | 30.20 | 0.87 µs |

It scales 4.3× on 8 threads. Each tick has two dispatches (even bands, then odd bands) plus
a sequential seed step. Sources: `perf_p2_mature.json` (`--env-warmup=38400`) and
`perf_p2_env_on_*.json`.

### Tick cost with flora enabled (100k spike entities)

| | mean ms | p95 ms | ticks/s | env ms | decide | propose | resolve | blocked/tick |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| environment off | 57.22 | 61.13 | 17.5 | — | 19.07 | 5.17 | 32.98 | 19,917 |
| environment on, **mature flora**, 8 threads | **68.69** | 72.72 | **14.6** | **10.32** | 16.83 | 5.59 | 35.93 | 18,526 |
| environment on, young flora, 8 threads | 69.61 | 83.55 | 14.4 | 6.96 | 20.74 | 5.83 | 36.07 | 21,119 |
| environment on, young flora, 6 threads | 70.88 | 74.02 | 14.1 | 7.89 | 23.42 | 5.98 | 33.57 | 21,119 |

**Budget check (spec: added cost under 15% of the tick budget).** The budget is 100 ms per tick
at the 10 ticks/s target. Worst case is mature flora:

| measure | ms | share of budget |
|---|---:|---:|
| the environment pass itself (mature flora, with 100k entities) | 10.32 | **10.3%** |
| whole-tick increase with 100k entities, mature flora | 11.47 | 11.5% |
| whole-tick increase with 100k entities, young flora | 12.39 | 12.4% |

All are under 15%. The whole-tick increase is not just the pass itself: the spike's phases also
change cost, because their dummy field (fertility) now evolves. With young flora,
crowding rose (21.1k blocked entities per tick vs 19.9k) and the pass evicts cache lines the
entity phases had warm. With mature flora the spike moves more and blocks less, so decide is
cheaper. The young 8-thread p95 (83.6 ms) was noisier than the other runs; the means are
consistent.

**GDScript decision, re-tested per the Phase 1 rule.** 100k entities with mature flora run at
14.6 ticks/s, which is ≥ 10, so the rule says stay on GDScript. The margin over the target has
shrunk from 1.75× to about 1.45×. Re-test after Phase 3 brings real entity logic.

### Rendering with live flora

Autotest at 4096²: a 10 s sweep from fit-to-map to 24 px/cell, 1600×900 window, vsync on,
monitor at 119 Hz. The flora overlay is visible, and its two 16 MB layers are re-copied and
uploaded at `ui.layer_refresh_hz` (1 Hz), one texture per frame.

| scenario | avg fps | p95 ms | p99 ms | max ms | frames > 18 ms |
|---|---:|---:|---:|---:|---:|
| sim paused, refresh 1 Hz | 120.3 | 9.35 | 12.46 | 18.07 | 0 / 1165 |
| 100k spike entities + flora, max speed (15.7 ticks/s), refresh 1 Hz | 121.2 | 8.78 | 10.96 | 13.12 | 0 / 1175 |
| flora only, max speed (122 ticks/s), refresh 4 Hz | 121.2 | 9.43 | 11.66 | 13.80 | 0 / 1169 |

Each layer refresh copies two 16 MB layers on the sim thread with `slice(0)`, about 15 ms once
a second. That is roughly 1% of sim time at 14 ticks/s.

### Reproduce (Phase 2)

At tag `phase-02-done` (the spike profiler is gone after it):

```bash
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --env-warmup=38400 --counts=0,100000 --warmup=500 --ticks=200
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --counts=0,100000 --warmup=500 --ticks=200 --set=env.enabled=false
tools/godot.sh --headless --path . --script res://tools/flora_report.gd -- --years=10
tools/godot.sh --headless --path . --script res://tools/harvest_experiment.gd
```

Acceptance artifacts from the 10-year run, the harvest experiment, and the full-scale
determinism check are in `docs/reports/phase-02/`.

## Phase 3: entities

Same machine and engine as Phases 1 and 2. Real entities replace the spike. Raw results are in
`docs/perf/phase-03/`.

### Method

The Phase 1 method: `tools/profile.gd`, headless, 8 worker threads, the full 4096² map with
flora on, 200 measured ticks at steady state. Differences:

- **Mature flora:** a 38,400-tick (5-year) environment warmup first, like Phase 2's mature row.
- **Entities come from the founder spawner**, in groups of 250, not uniform random.
- **Entity warmup is 2,000 ticks, not 500.** Founders start with staggered energy, and the
  population needs about a day of hunger cycling (96 ticks per day) before decisions, movement
  and eating settle.
- **Every final row is measured in summer** (`--season=summer`: before each count, entity-free
  ticks run until its 200 measured ticks start on summer day 3). The pre-fix rows ran the counts
  back to back, so 10k was measured in early summer, 50k in autumn and 100k in winter.

About 1 to 2% of each population starved during warmup (founders placed on poor land). The
tables show the count alive while measuring.

### Final: ms per tick (after the follow-up fixes, summer)

Behaviour fixes A and B, the death check after every cost, and derived energy costs. Sources:
`perf_p3_fixed.json`, `perf_p3_hungry.json`, `perf_p3_lowflora.json`.

| population | entities | mean ms | p50 | p95 | max | ticks/s | env | decide | propose | resolve | deaths | interact | corpses | decisions/tick | moves/tick | blocked/tick | deaths in 200 ticks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| default | 9,895 | 14.97 | 14.86 | 15.56 | 16.44 | 66.8 | 9.55 | 4.04 | 0.61 | 0.57 | 0.00 | 0.14 | 0.01 | 1,003 | 75 | 1 | 1 |
| default | 49,205 | 33.53 | 32.95 | 36.74 | 41.31 | 29.8 | 9.46 | 18.38 | 2.62 | 2.28 | 0.01 | 0.66 | 0.07 | 4,988 | 378 | 6 | 13 |
| default | 98,341 | **57.23** | 56.08 | 62.47 | 66.05 | **17.5** | 9.29 | 36.65 | 5.16 | 4.63 | 0.01 | 1.30 | 0.14 | 9,968 | 870 | 11 | 40 |
| hungry: `entity.burn_floor` 0.76 (base burn 1.2 per tick, 2×) | 97,925 | 62.26 | 62.89 | 67.11 | 73.86 | 16.1 | 9.86 | 38.90 | 6.07 | 4.83 | 0.01 | 2.47 | 0.07 | 10,010 | 1,108 | 11 | 24 |
| hungry and mobile: flora thinned to 10% at spawn | 94,728 | **61.56** | 60.21 | 67.69 | 77.17 | **16.2** | 6.86 | 38.65 | 6.15 | 6.42 | 0.03 | 2.84 | 0.56 | 9,664 | 4,089 | 26 | 786 |

- **The raised-burn row is hungry but not mobile.** Food is close, so its entities eat more
  often (interact 2.47 ms) but move little (1,108 moves per tick). The low-flora row is the
  mobile one: they search, with 4,089 moves per tick (4.7× the default), resolve 6.42 ms, and 786
  deaths in the 200 measured ticks.
- **Even the low-flora row is far from the Phase 1 spike's mobility** (about 100k moves per
  tick, resolve 33 ms). Searching entities still rest until hunger passes about 0.5.

### Pre-fix rows (kept for comparison)

After the decide optimisation, before the follow-up fixes (13 genes, old utility, death check
before movement cost). The counts ran back to back, so the measurement seasons differ. Source:
`perf_p3_prefix.json`.

| entities | season | mean ms | p50 | p95 | max | ticks/s | env | decide | propose | deaths | resolve | interact | corpses | decisions/tick | moves/tick | blocked/tick |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 9,910 | early summer | 14.69 | 14.58 | 15.25 | 16.23 | 68.1 | 9.29 | 4.00 | 0.64 | 0.00 | 0.56 | 0.15 | 0.01 | 1,005 | 73 | 1 |
| 49,092 | autumn | 31.30 | 30.93 | 34.08 | 36.39 | 31.9 | 9.50 | 15.97 | 2.84 | 0.00 | 2.24 | 0.62 | 0.08 | 4,981 | 294 | 5 |
| 97,997 | winter | 57.80 | 56.78 | 62.72 | 68.27 | 17.3 | 7.21 | 34.86 | 6.16 | 0.01 | 5.06 | 4.26 | 0.20 | 9,979 | 1,804 | 11 |

### Changes against the pre-fix Phase 3 numbers (100k)

| phase | pre-fix (winter) | final (summer) | change |
|---|---:|---:|---|
| whole tick | 57.80 | 57.23 | −0.6 |
| env | 7.21 | 9.29 | +2.1: season (summer growth), not code |
| decide | 34.86 | 36.65 | **+1.8 (+5%)**: more hungry wanderers re-deciding; the decide code path is the same |
| propose | 6.16 | 5.16 | −1.0 |
| resolve | 5.06 | 4.63 | −0.4 |
| interact | 4.26 | 1.30 | −3.0: winter's low yields meant more bites per meal |
| corpses | 0.20 | 0.14 | −0.06 |

- **Most differences are the season** the pre-fix 100k row happened to be measured in.
- **The same-state comparison is closer:** `decide_bench` on its saved summer state gave a
  58.5 ms tick and 37.3 ms decide before the follow-up; the final summer row is 57.2 and 36.7.
- **No regression is flagged beyond decide's +5%,** which is within the spread of season and
  population effects.
- **The derived costs cost nothing per tick:** they are read from arrays filled at spawn.

### Decision rule (spec section 13), applied to the 100k rows

| 100k row | ticks/s | rule |
|---|---:|---|
| default population, summer | 17.5 | ≥ 10: stay on GDScript |
| hungry (2× base burn) | 16.1 | ≥ 10: stay |
| hungry and mobile (10% flora) | 16.2 | ≥ 10: stay |

**Every 100k row is at 10 ticks/s or more, so the rule says stay on GDScript.** The worst row
leaves a 1.6× margin.

Before the decide optimisation, the first measurement was 100.57 ms per tick, 9.9 ticks/s
(`perf_p3_before_opt.json`), with decide at 78.39 ms. That is in the 5 to 10 band, so decide was
optimised, without changing any decision:

| step | decide µs per decision, 1 thread | decide ms per tick, 100k, 8 threads | whole tick ms |
|---|---:|---:|---:|
| first version | 32.0 | 73.1 | 93.9 |
| entities in sight counted natively per row; food scan outward with a distance cutoff | 21.4 | | |
| plus a per-row bound on each plant type's best possible bite | **18.0** | **37.3** | **58.5** |

Measured with `tools/decide_bench.gd` on one saved 100k steady state (summer). Each step
printed the same hash of everything decide writes. The gate rerun also reproduced the
pre-optimisation run's alive counts, moves, blocked moves and deaths exactly.

The phase doc asks for the options when the result lands at 5 to 10. It landed there before the
optimisation, so here they are:

1. **Stay on GDScript (recommended).** 16.1 to 17.5 ticks/s at 100k.
2. **More GDScript levers if later phases use the margin up:**
   - `entity.decision_interval` (10 → 20 roughly halves decide).
   - A cheap re-decision for sated, resting entities.
   - Per-block food summaries so the food scan skips poor blocks.
   - All change behaviour, so each needs re-validation.
3. **Port decide alone to a Rust GDExtension.** It is a pure function of read-only state per
   entity and runs in parallel, so it is the easiest piece to port. `decide_bench`'s output hash
   checks a port bit for bit.
4. **Port the whole sim core**, as Phase 1 planned. Not needed now. No Rust port was started.

### Top three bottlenecks (100k, final default row)

1. **Decide: 36.7 ms (64%).** Per decision, single-threaded:

   | part | µs |
   |---|---:|
   | food scan | about 8.5 |
   | setup and entities in sight | 3.2 |
   | utilities | 1.8 |
   | memory | 1.6 |
   | corpse and water blocks | 1.5 |
   | choose and set the target | 1.4 |

   It scales about 5× on 8 threads.
2. **Environment: 9.3 ms (16%).** Unchanged from Phase 2; season-dependent.
3. **Propose: 5.2 ms (9%).** Per-entity burn, ageing, target stepping and the cost-weighted step.

Next are **resolve (4.6 ms; 6.4 in the mobile row)** and **interact (1.3 ms; 2.8 in the mobile
row)**. Both are sequential, so threads cannot help them.

### Against Phase 2 (100k spike entities, mature flora: 68.69 ms, 14.6 ticks/s)

| phase | Phase 2 ms | Phase 3 final ms | change |
|---|---:|---:|---|
| whole tick | 68.69 | 57.23 | −11.5 |
| env | 10.32 | 9.29 | −1.0 |
| decide | 16.83 | 36.65 | **+19.8, regression**: real perception, memory and utility scoring instead of the spike's gradient seek |
| propose | 5.59 | 5.16 | −0.4 |
| resolve | 35.93 | 4.63 | −31.3 |
| interact | — | 1.30 | new (sequential) |
| corpses | — | 0.14 | new |

**Resolve's drop is the workload, not an optimisation.** The spike moved every entity every
tick (18,526 blocked per tick). Fed entities mostly rest (870 moves and 11 blocked per tick
here; 4,089 and 26 in the mobile row). A population as mobile as the spike would push resolve
back toward 33 ms, sequential. Read the whole-tick gain with that in mind.

### Perception structure (scope 5: hash or grid, by profiling)

`tools/perception_bench.gd`: single thread, the real map, founder-placed entities, radius 5
(121 cells), 10,000 sampled decisions. Values are µs per decision.

| entities | grid: flora only | grid: flora + occupancy | entities via grid, per cell | entities via grid, native row counts | hash build ms per tick | hash query | entities via hash (build share + query) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 10.97 | 16.73 | 5.77 | **2.63** | 4.89 | 4.61 | 9.50 |
| 50,000 | 10.77 | 15.84 | 5.07 | **2.61** | 13.70 | 4.39 | 7.13 |
| 100,000 | 10.81 | 15.87 | 5.06 | **2.49** | 25.05 | 4.40 | 6.90 |

**Entities are perceived through the grid**, by native row counts since the optimisation.
- A spatial hash costs more per decision.
- Its rebuild (25 ms per tick at 100k) is sequential, while grid reads run in the parallel
  decide.
- Food has to be read from the grid either way.

Reading corpse and substrate per cell added about 8 µs per decision (grid_all 23.9 against
grid flora + occupancy 15.9). Corpses and water are therefore read only inside 8×8 perception
blocks that have any.

### Reproduce (Phase 3)

```bash
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --env-warmup=38400 --counts=10000,50000,100000 --warmup=2000 --ticks=200 --season=summer --out=res://batch_output/perf_p3_fixed.json
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --env-warmup=38400 --counts=100000 --warmup=2000 --ticks=200 --season=summer --set=entity.burn_floor=0.76 --out=res://batch_output/perf_p3_hungry.json
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --env-warmup=38400 --counts=100000 --warmup=2000 --ticks=200 --season=summer --thin-flora=0.1 --out=res://batch_output/perf_p3_lowflora.json
tools/godot.sh --headless --path . --script res://tools/decide_bench.gd -- --rebuild --ticks=200
tools/godot.sh --headless --path . --script res://tools/perception_bench.gd
```
