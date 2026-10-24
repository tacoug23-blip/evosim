# Phase 3: Entity Basics

Read `docs/MASTER_SPEC.md`, `docs/DECISIONS.md`, and `docs/PERF.md`. Implement only this phase. Follow the working agreement in section 16 of the spec.

## Goal
Entities that sense, decide, move, eat, die, and leave corpses that return nutrients to soil. Stats are fixed (they do not evolve yet), but they are stored as a genome-shaped array so that Phase 4 can mutate them.

## Scope
1. **Entity SoA store**: id, x, y, alive, sex (assigned but unused), age, energy, hp, carrying, action, target, memory slots. Recycle IDs with a generation counter.
2. **Genome-shaped stats**: a float vector per entity, with gene definitions in `config/genes.json` (name, min, max, default, cost notes). All founders get the defaults, with optional jitter per founder. No mutation yet.
3. **Item properties own nutrition**: move `nutrition` from `config/flora.json` to `config/items.json`. Every item is edible; there is no edible flag. Food value differs only through `nutrition`. Flora points to its item only through `harvest_item`. Placeholder defaults, all `tuned: false`, ranked high to low: berries, mushrooms, reeds, hay (low), twigs (very low), wood (very low). Nutrition must be > 0 for every item. Keep a separate nutrition value for corpses in the corpse config. This changes config only; no world layer or SoA array changes. Update `MASTER_SPEC.md` §3 (flora properties and items) and `docs/DECISIONS.md` in the same commit. Item 0 stays "none". The existing item ids 1–6 must not change.
4. **Needs and energy**: a base energy burn per tick; movement cost (terrain cost × move_energy_cost); eating gain (item nutrition × digest_efficiency); food_needed_to_sate; death at energy <= 0.
5. **Perception**: scan within sense_radius for food, corpses, other entities, and water. The energy cost scales with the radius. Choose the spatial structure (hash or direct grid scan) by profiling.
6. **Memory**: a fixed-size ring of remembered locations, by kind (food; danger as a placeholder).
7. **Utility decision loop**: the actions are eat/forage, rest, wander, and seek remembered food. Scores come from need levels and gene weights. Stagger decisions by ID offset; the interval is in the registry.
8. **Movement**: cost-weighted local gradient/flow following, with an accumulator for speed. Strictly one entity per cell, with seeded deterministic conflict resolution. No swaps. Sidestep when blocked.
9. **Foraging**: calls the Phase 2 `harvest` API. Entities eat items directly in this phase. Any item can be eaten. Utility scoring must weigh expected nutrition against the time and energy cost of harvesting, so low-value items are eaten only when better food is scarce.
10. **Corpses**: on death, create a corpse record (mass, nutrients, decay timer). Entities can pick up, carry (with a speed penalty; a carried corpse occupies no cell), drop, and eat a corpse if `corpse_edible` is true. Decay returns nutrients to the fertility layer and removes the corpse.
11. **Inspector**: click an entity to see its state, genome values, memory, current action, and action utility scores. Render the entity layer as one point per entity, colored by energy or sex.
12. **Founder spawner**: parameterized groups (count, size range, spacing), used for tests.
13. **Mark `env.bands` structural**: it changes results for a given seed, so lock it once a world exists, as with map size and seed. Add a test that `set_value` refuses it while locked.

## Out of scope
Reproduction, mutation, life stages, tribes, building, combat, cooking, and item carrying other than corpses.

## Acceptance criteria
- With abundant flora, 5,000 founders survive and keep cycling through food. With scarce flora, they starve and leave corpses, and fertility rises near the corpses.
- No cell ever holds two entities (assertion test over 10k ticks).
- The determinism hash test passes with entities and flora both enabled, including the thread-count invariance check (1, 3, and 8 threads) over at least 7,680 ticks on a 512² map.
- The inspector's utility scores match the chosen action.
- Nutrition is read only from `items.json`: no code path reads nutrition from flora. A test eats each item and checks the energy gain against `nutrition × digest_efficiency`. A test shows that with high- and low-nutrition food at equal distance, an entity chooses the high-nutrition food.
- **Perf gate:** record ms/tick at 10k, 50k, and 100k entities, with flora enabled, at steady state (after warmup), headless, in `docs/PERF.md`, using the same method as Phase 1. Apply the spec §13 decision rule to the 100k result:
  - ≥ 10 ticks/s: stay on GDScript.
  - 5 to 10: optimize, then report the options.
  - < 5: stop and recommend the Rust port.

  Do not start a Rust port without approval. Give the per-phase breakdown (environment, decide, propose, resolve, and any new phase), and flag any regression against the Phase 2 numbers.

## Report back
- Acceptance criteria, each with its evidence (test names, numbers, hashes).
- The perf table, the §13 rule outcome, and the top three bottlenecks at 100k.
- The spatial-structure choice for perception, with the profiling numbers that decided it.
- Every interpretation or deviation from the spec, and every new parameter (all marked `tuned: false`).
- Changes made to `MASTER_SPEC.md` and `DECISIONS.md`.
- Proposed commit message. Do not commit or push until approved.
