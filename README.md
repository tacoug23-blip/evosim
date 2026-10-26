# EvoSim prompt pack

1. Create an empty repo, copy this `docs/` folder into it.
2. Start Claude Code in the repo root.
3. For each phase, in order, paste:

   > Read docs/MASTER_SPEC.md and docs/phases/PHASE_NN_<name>.md. Implement only that phase. Follow the working agreement in section 16 of the spec. Stop when the acceptance criteria are met and report.

4. Review the report, run the sim yourself, adjust parameters or the spec, then move to the next phase.

Do not skip Phase 1: its spike decides GDScript vs Rust.
Update `MASTER_SPEC.md` when you change a decision, so later phases inherit it.

## Running

Godot 4.6. `tools/godot.sh` finds the binary via `$GODOT`, then a one-line path in the untracked
file `tools/.godot_bin`, then `godot` on PATH. Use the `_console.exe` build on Windows so output
reaches the terminal.

```bash
tools/godot.sh --path .                                   # the app (4096x4096, sim paused)
tools/godot.sh --path . -- --founders --speed=1          # with the default founder groups running
tools/godot.sh --path . -- --preset=small_world --founders
tools/godot.sh --headless --path . --script res://tests/run_tests.gd
tools/godot.sh --headless --path . --script res://tools/profile.gd -- --counts=10000,50000,100000
tools/godot.sh --headless --path . --script res://tools/determinism_check.gd
tools/godot.sh --headless --path . --script res://tools/flora_report.gd -- --years=10
tools/godot.sh --headless --path . --script res://tools/harvest_experiment.gd
tools/godot.sh --headless --path . --script res://tools/entity_report.gd
tools/godot.sh --headless --path . --script res://tools/perception_bench.gd
tools/godot.sh --headless --path . --script res://tools/decide_bench.gd -- --ticks=200
tools/godot.sh --headless --path . --script res://tools/thread_hash_check.gd -- --founders
tools/godot.sh --path . -- --preset=small_world --founders --autotest-inspect
```

App controls: drag to pan, wheel to zoom, WASD/arrows, Home to fit. Space pauses,
1-4 = 1x/2x/5x/20x, 5 = max, N = single step, F5/F9 = quicksave/quickload. The HUD has
overlay toggles (terrain, flora, fertility, moisture, entities), season tint and day/night
shading, the in-game clock, and a debug brush (harvest, or plant a flora type; left-drag paints
while it is on, and the camera then pans with middle/right drag). Founders: Spawn / Clear;
entity colour by energy or sex. Click an entity to open the inspector (state, genome, memory,
and the utility scores of its last decision).
Command-line options for the app are listed at the top of `ui/main.gd`.

Layout: `config/` parameters, substrates, flora, items, genes, presets · `sim/` headless core · `ui/` renderer and
HUD · `tools/` profiling and checks · `tests/` · `docs/` spec, `DECISIONS.md`, `PERF.md`.
