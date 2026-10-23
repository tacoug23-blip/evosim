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
`docs/perf/<phase>/`.

```bash
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --counts=1000,10000,50000,100000 --warmup=500 --ticks=200
tools/godot.sh --headless --path . --script res://tools/profile_spike.gd -- --warmup=500 --ticks=200 --set=sim.worker_threads=1
tools/godot.sh --headless --path . --script res://tools/determinism_check.gd -- --ticks=1000
tools/godot.sh --path . -- --autotest-render=10
tools/godot.sh --path . -- --autotest-render=10 --spike=100000 --speed=max
```
