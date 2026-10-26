# EvoSim: notes for Claude Code

Godot 4.6.1 GDScript sim, built one phase at a time from `docs/phases/PHASE_NN_*.md`.

## Source of truth

`docs/MASTER_SPEC.md` (design; section 16 is the working agreement), `docs/DECISIONS.md` (every
non-obvious choice and why) and `docs/PERF.md` (measured performance) are the source of truth.
Read them before changing anything. When a decision changes, update MASTER_SPEC and DECISIONS in
the same commit. New parameters go in `config/parameters.json` with `"tuned": false`. Do one phase
at a time, and do not commit or push until the user approves.

## Godot binary

`tools/godot.sh` runs Godot. It finds the binary via `$GODOT`, then a one-line path in the
untracked file `tools/.godot_bin`, then `godot` on PATH. On Windows use the `_console.exe` build
so output reaches the terminal. All commands below run from the repo root.

## Tests and checks

```bash
tools/godot.sh --headless --path . --script res://tests/run_tests.gd                      # all tests
tools/godot.sh --headless --path . --script res://tests/run_tests.gd -- --filter=memory   # name substring
tools/godot.sh --headless --path . --script res://tools/thread_hash_check.gd -- --size=512 --ticks=7680 --threads=1,3,8 --founders
tools/godot.sh --headless --path . --script res://tools/determinism_check.gd -- --ticks=1000 --entities=100000
```

- Thread-hash check: hashes must be identical at every thread count.
- Determinism check: full map, two runs from one seed, one-per-cell invariants every tick, then
  save/load; it ends with `RESULT: PASS`.
- `batch_output/` is gitignored. Copy runs worth keeping to `docs/perf/<phase>/` or
  `docs/reports/<phase>/`.

## Profiler and reports

```bash
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --env-warmup=38400 --counts=10000,50000,100000 --warmup=2000 --ticks=200 --season=summer --out=res://batch_output/perf.json
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --env-warmup=38400 --counts=100000 --warmup=2000 --ticks=200 --season=summer --thin-flora=0.1
tools/godot.sh --headless --path . --script res://tools/entity_report.gd -- --scenario=all   # abundant | low | scarce | both
```

- `--env-warmup=38400` grows mature flora first.
- `--season=` runs entity-free ticks before each count so every row is measured in the same
  season. Without it, counts run back to back into later seasons.
- `--thin-flora=SHARE` keeps that share of plants just before spawning: a hungry, mobile
  population.
- `--set=param.id=value` overrides a parameter.
- Run timing jobs alone.
- `tools/decide_bench.gd -- --ticks=200` times decide on a saved state and hashes its output, so
  an optimisation can be shown to change no decision.

## App autotests

```bash
tools/godot.sh --path . -- --autotest-render=10                                   # pan/zoom sweep, frame times, screenshots
tools/godot.sh --path . -- --autotest-brush                                       # plant/harvest brush, probes
tools/godot.sh --path . -- --preset=small_world --founders --autotest-inspect     # inspector, colour modes, founders
```

All app command-line options are listed at the top of `ui/main.gd`.

## Godot pitfalls (4.6.1)

- **A packed array cast copies.** `(x as PackedInt32Array).fill(0)` fills a temporary copy, and
  the write is lost; this was the v1 save-load bug. Go through a typed local:
  `var a: PackedInt32Array = x; a.fill(0)`. Properties, `get()`, Dictionary/Array elements and
  typed locals all write through. `tests/test_packed_arrays.gd` scans for the bad pattern.
- **Copy-on-write in parallel phases.** Never copy, duplicate or resize sim arrays during a
  parallel phase. Call `Parallel.ensure_unique()` on every array the items write before
  dispatching. `duplicate()` is lazy (the next write pays the copy); `slice(0)` is a real copy.
- **WorkerThreadPool group tasks must be high-priority.** Low-priority ones are capped to a
  fraction of the pool (2 of 8 threads here), silently halving the speedup. Use
  `sim/core/parallel.gd`, which always submits high-priority.
- **No `class_name`.** Scripts reference each other with `preload()`, so headless runs work on a
  fresh clone without the editor's global class cache.
- **Type inference needs typed values.** Calls through an untyped `RefCounted` return Variants,
  so write `var c: int = ...`, not `:=`, or the script fails to parse.
- **Avoid names of native classes** for scripts and classes (`Environment` clashed; it is
  `EnvSystem`).
