# Phase 4: Life Cycle and Genetics

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Two-sex sexual reproduction with crossover and mutation, life stages and aging, and a cost on every beneficial gene, so evolution has real trade-offs.

## Scope
1. **Sexes**: assigned at birth by `birth_sex_ratio`.
2. **Life stages**: juvenile, adult, elder. Stage boundaries from genes (maturity_age, lifespan). Stage multipliers (speed, burn, fertility, combat) in registry. Juveniles optionally need more food (param). Death by old age with lifespan variance.
3. **Mate seeking and mating**: fertile adult seeks a compatible adult of the opposite sex within sense radius. Compatibility = genome distance <= `mate_compat_cutoff` and the `mate_choice_in_tribe` gene satisfied (tribe-aware part is a stub until Phase 8; use proximity/genome similarity as the proxy). `mating_propensity` gene feeds utility scoring.
4. **Gestation**: female pays energy per tick, gestation_length gene, optional mobility penalty. Birth places the child in a nearby free cell (if none free, delay). Father's genes stored at conception.
5. **Genome inheritance**: per-gene crossover (uniform), then mutation. Each gene has `mutation_rate` and `mutation_scale`. Global `mutation_scale_multiplier` scales all. Clamp to bounds. Mutation distribution configurable (gaussian default).
6. **Gene costs**: implement a cost function for every gene in `config/genes.json` (e.g. sense_radius -> burn, move_speed -> move_energy_cost, fertility -> gestation cost, lifespan -> higher base burn, attack/defense -> burn). Document each in the file.
7. **Lineage**: store parent IDs and generation number; ancestry query function.
8. **Energy economics**: offspring energy endowment from parents (param).
9. **Population control**: none enforced, but expose optional auto-reseed toggle (default off).

## Out of scope
Tribe-aware logic, signals, combat, building.

## Acceptance criteria
- A seeded run with defaults shows population growth, oscillation, and no immediate collapse over 50 simulated years (or a documented explanation plus param suggestions).
- Gene means drift measurably under selection: e.g. with scarce food, sense_radius or efficiency genes shift upward until their costs bite. Include a script that reports gene mean/variance per 100 ticks.
- Setting `mutation_scale_multiplier` to 0 yields no gene change except crossover recombination; setting it high yields visibly more variance.
- Determinism hash test passes.
- Perf recorded in `docs/PERF.md` at 100k entities.
