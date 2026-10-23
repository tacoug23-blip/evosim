# Phase 3: Entity Basics

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Entities that sense, decide, move, eat, die, and leave corpses that return nutrients to soil. Fixed (non-evolving) stats for now, but stored as a genome-shaped array so Phase 4 can mutate them.

## Scope
1. **Entity SoA store**: id, x, y, alive, sex (assigned but unused), age, energy, hp, carrying, action, target, memory slots. ID recycling with generation counter.
2. **Genome-shaped stats**: a float vector per entity with gene definitions in `config/genes.json` (name, min, max, default, cost notes). All founders get defaults with optional per-founder jitter. No mutation yet.
3. **Needs and energy**: base burn per tick, movement cost (terrain cost x move_energy_cost), eating gain (nutrition x digest_efficiency), food_needed_to_sate, death at energy <= 0.
4. **Perception**: sense_radius scan for food, corpses, other entities, water. Energy cost scales with radius. Spatial structure (hash or direct grid scan) chosen by profiling.
5. **Memory**: fixed-size ring of remembered locations by kind (food, danger placeholder).
6. **Utility decision loop**: actions = eat/forage, rest, wander, seek remembered food. Scores from need levels and gene weights. Decisions staggered by ID offset; interval in registry.
7. **Movement**: cost-weighted local gradient/flow following; accumulator for speed; strict one-per-cell with seeded deterministic conflict resolution; no swaps; sidestep when blocked.
8. **Foraging**: calls Phase 2 `harvest`. Items eaten directly in this phase.
9. **Corpses**: on death create a corpse record (mass, nutrients, decay timer). Entities can pick up, carry (speed penalty, occupies no cell), drop, and eat a corpse if `corpse_edible` is true. Decay returns nutrients to the fertility layer and removes the corpse.
10. **Inspector**: click an entity to see state, genome values, memory, current action, and action utility scores. Entity layer rendered (point per entity, color by energy or sex).
11. **Founder spawner**: parameterized groups (count, size range, spacing) used for tests.

## Out of scope
Reproduction, mutation, life stages, tribes, building, combat.

## Acceptance criteria
- 5,000 founders with abundant flora survive and cycle food; with scarce flora they starve and leave corpses; fertility rises near corpses.
- No cell ever holds two entities (assertion test over 10k ticks).
- Determinism hash test passes with entities enabled.
- Inspector shows utility scores that match the chosen action.
- Perf: record ms/tick at 10k, 50k, 100k entities in `docs/PERF.md`. Flag any regression against the Phase 1 spike.
