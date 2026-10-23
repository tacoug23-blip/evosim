# Phase 1: World, Renderer, Infrastructure, Performance Spike

Read `docs/MASTER_SPEC.md` fully before starting. Implement only this phase.

## Goal
A 4096x4096 layered world that renders with pan/zoom, plus the infrastructure that is painful to retrofit (parameter registry, deterministic RNG, save/load, speed controls), plus a pass/fail performance spike that decides GDScript vs Rust.

## Scope
1. **Godot project** scaffold per the repo layout. Sim code lives in `sim/` and must run under `godot --headless` without UI.
2. **Parameter registry**: JSON loader, typed access, groups, defaults/min/max, `tuned` flag, presets, runtime override API. No hardcoded sim constants anywhere.
3. **World layers** (SoA, packed arrays): substrate, fertility, moisture, flora_type, flora_biomass, structure_type/material/hp, item_type/qty, corpse_id, occupancy. Allocate all; only substrate, fertility, moisture need to be populated now.
4. **Substrates** from `config/substrates.json`: soil, rock, sand, water, mud with move_cost, fertility_base, allows_flora, allows_building.
5. **Procedural terrain generator**: seeded noise (elevation, moisture) producing continents, lakes, rock outcrops, sand near water. Seed and generator params in the registry.
6. **Renderer**: terrain drawn from one texture (one pixel per cell) via shader. Smooth pan and zoom (mouse drag, wheel). Overlay toggle system (terrain, fertility, moisture) built so later overlays plug in.
7. **Deterministic RNG**: one seeded stream per subsystem. Utility to hash world state (for determinism tests).
8. **Save/load**: binary format with version header; stores seed, parameter snapshot, all layers, tick count.
9. **Speed controls**: pause, 1x, 2x, 5x, 20x, max, single-step. Sim tick loop decoupled from render frame rate.
10. **Performance spike** (`sim/spike/`): 100k dummy entities on the real map. Packed arrays only. Behavior: random walk plus gradient-seek toward the nearest value of a dummy field, terrain move cost applied, strict one-entity-per-cell with seeded deterministic conflict resolution (no swaps), perception scan radius 8, decisions staggered every 10 ticks by ID offset.
11. **Profile harness**: headless script reporting ms/tick (mean, p95) at 1k, 10k, 50k, 100k entities.

## Out of scope
Flora growth, real entity logic, signals, tribes, anything beyond the dummy spike.

## Acceptance criteria
- World renders at 4096x4096 with smooth pan/zoom at 60 fps render rate while the sim is paused.
- Same seed yields an identical world hash across runs; save then load yields an identical hash.
- Spike: after 1000 ticks, same seed yields an identical entity-state hash. No cell ever holds two entities.
- `docs/PERF.md` contains the measured ms/tick table and a recommendation per the decision rule: >= 10 tps stay GDScript; 5-10 optimize and report; < 5 recommend Rust GDExtension.
- Unit tests for registry, RNG, save/load, conflict resolution.

## Report back
The perf table, the recommendation, and the top three bottlenecks from profiling. Do not begin the Rust port without approval.
