# Phase 5: Observability and Tuning Harness

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Make the sim understandable and tunable: live charts, event log, lineage tools, and a headless batch runner that sweeps parameters.

## Scope
1. **Metrics collector** (sim side, cheap): per-N-ticks samples of population, births, deaths by cause (starvation, age, injury placeholder), sex ratio, age distribution, mean/variance of every gene, flora coverage, mean energy, entity count per occupancy density.
2. **In-app charts panel**: population over time, births/deaths, gene mean/variance (selectable), age histogram, flora coverage. Time window selectable.
3. **Gene histograms**: per-gene distribution, global (per-tribe added in Phase 8).
4. **Event log**: ring buffer of typed events (birth, death, mating, starvation) with filter by type and entity; click an event to jump to its location.
5. **Lineage viewer**: select an entity to see parents, grandparents, children, generation, and gene differences vs parents.
6. **Heatmap overlays**: any gene or energy as a per-region average heatmap (computed at reduced resolution, refreshed on an interval).
7. **Live tuning UI**: parameter browser grouped by registry group, with search, slider/field, reset to default, and a "tuned" flag display. Structural params flagged as requiring restart.
8. **Presets**: save/load named parameter sets.
9. **Headless batch runner** (`tools/batch`): takes a sweep spec (parameter ranges, seeds, ticks), runs N sims (parallel processes), writes metrics to CSV/JSON, and a script that plots comparison charts (population, gene means, extinction rate).
10. **Founder sweep**: use the harness to sweep number of groups (5-50), group size (100-500), and spacing; report which defaults give survival of at least 80% of seeds over 30 years with non-trivial evolution. Write the chosen defaults into the registry with `tuned: true` and document in `docs/DECISIONS.md`.

## Out of scope
Signals, tribes, buildings, combat.

## Acceptance criteria
- Charts update live at 20x speed without dropping render frame rate below 30 fps at 50k entities.
- Batch runner executes a 3x3x5-seed sweep headless and produces a plot without manual steps.
- Re-running a batch with identical spec produces identical CSV output.
- The founder sweep report exists with a table and the chosen default.
