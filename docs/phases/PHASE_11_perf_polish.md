# Phase 11: Performance and Polish

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Hit the final tick-rate target at peak population, and make the sim pleasant to run and share.

## Scope
1. **Profile at 100k entities** with all systems on; produce a flame/breakdown per subsystem in `docs/PERF.md`.
2. **Optimization levers** (apply as the profile dictates): multithreading of independent subsystems and entity partitions (deterministically), spatial-hash tuning, decision-interval scaling by distance from the camera or by idleness (LOD), chunked/sparse updates for empty regions, reduced-frequency tribe and signal updates, GPU compute for fields, data-layout tightening, Rust GDExtension port of hot loops if not already done and approved.
3. **Determinism preserved**: any threading or LOD change must keep the same-seed hash test passing, or be explicitly flagged as nondeterministic mode with a toggle.
4. **Autosave and snapshots**: periodic autosave, named snapshots, load performance check (4096x4096 world plus 100k entities).
5. **Preset library**: ship named presets (e.g. `lush`, `harsh_winters`, `sparse_survival`, `high_mutation`, `warlike`, `diplomatic`) with descriptions.
6. **UX polish**: minimap, camera bookmarks, follow-entity camera, tribe-follow, keyboard shortcuts, performance HUD (tps, entity count, tick ms), settings persistence.
7. **Docs**: README with quick start, parameter guide (generated from the registry), architecture overview, how to run batch sweeps.
8. **Long-run soak test**: 200 simulated years headless at default seeds; report extinction rate, memory growth (must be flat), and performance drift.

## Acceptance criteria
- Meets the agreed tick-rate target (default: 10 ticks/s at 100k entities; user may revise after seeing Phase 1 and later results) on the user's machine, or documents precisely what blocks it and the next lever.
- Soak test: no memory growth beyond 5% over the run; no crashes.
- Determinism test passes in default mode.
- All presets load and run for 20 simulated years without errors.
