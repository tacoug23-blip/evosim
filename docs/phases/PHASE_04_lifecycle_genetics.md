# Phase 4: Life Cycle and Genetics

Read `docs/MASTER_SPEC.md`, `docs/DECISIONS.md` and `docs/PERF.md`. Implement only this phase. Follow the working agreement in section 16 of the spec. Work on a new branch `phase-04` from `main` (tag `phase-03-done`).

## Goal
Two-sex sexual reproduction with crossover and mutation, life stages and aging, and a real cost on every beneficial gene, so evolution has trade-offs. Before that, fix the two Phase 3 utility gaps that selection would otherwise tune genes around.

## Part A: pre-flight (commit separately before Part B)
1. **Food value in memory.** Add one u8 SoA array per memory slot holding the remembered item id (0 = none). This is a layout change; bump the save format. Seek utility uses the remembered item's value: look up nutrition from `items.json` at decide time and apply the same quality function q as forage, with distance to the remembered cell. Do not store a nutrition snapshot. Nutrition must still be read only from `items.json`.
2. **Value-gated food in sight.** A plant counts as food (a forage candidate, remembered, and "food in sight" for the S1/S3 rules) only if its q ≥ `entity.min_food_quality` (new, `tuned: false`). Choose a default that excludes the slot-4174 case (forage 0.03) without excluding hay in the low-flora scenario. Report the value and the reasoning.
3. **Determinism scenario at a sustainable density.** Scale the 512² scenario's founder count to map area (or set it so the population survives the full 7,680 ticks). Keep the old high-density scenario as a separate stress test. The new scenario must end with a living population; report the alive count at the end.
4. Regression tests (each must fail on `phase-03-done`):
   - An entity remembering a worthless plant and a valuable one at equal distance seeks the valuable one.
   - With only below-threshold plants in sight, a hungry entity searches (S3 rest cut-off applies) instead of resting.
5. Rerun the abundant and low-flora scenarios and the 100k default row. Report deaths, meals by item, and any decide regression. Stop and report if abundant deaths rise above 11 or low-flora survival falls below 96.0%.

## Part B: life cycle and genetics

### Scope
1. **New genes** in `config/genes.json` (group `lifecycle`). Placeholder defaults, all `tuned: false`; give units in days or years in the file and convert to ticks when derived:
   - `lifespan`: default 8 years, range 2–20.
   - `maturity_age`: default 1 year, range 0.25–4.
   - `fertility`: conception probability per mating, default 0.5, range 0.05–1.0.
   - `gestation_length`: default 20 days, range 5–60.
   - `mating_propensity`: behavioural weight, default 0.5, range 0–3.
   - `mate_choice_in_tribe`: stored and inherited but **inert until Phase 8**. No proxy logic. Document this in the gene's desc.
2. **Gene costs.** Every gene that has a benefit carries a cost. Implement as derived terms (spec §4.1.1), computed when the genome is fixed, never per tick:
   - `lifespan` → base_burn term `entity.burn_k_lifespan` × lifespan in years.
   - `fertility` → base_burn term `entity.burn_k_fertility` × fertility.
   - `maturity_age` → a fixed total growth energy `repro.growth_energy`, paid as extra juvenile burn spread over the juvenile period (growth_energy / maturity ticks). Maturing early costs more per tick.
   - `gestation_length` → the mother pays `repro.gestation_cost_per_tick` for the whole gestation. The newborn's starting energy = total paid × `repro.endowment_efficiency`. A shorter gestation gives more births but a smaller newborn reserve.
   - `mating_propensity` → the mate action costs `repro.mate_energy_cost` and its ticks.
   - Update the `cost` text of every gene. Flag any gene where you see a benefit with no working cost.
3. **Life stages.** A `life_stage` SoA array: juvenile, adult, elder. Boundaries: maturity_age, and elder at `repro.elder_fraction` × lifespan. Per-stage multipliers in the registry (speed, burn, fertility; combat placeholder). Juveniles have fertility 0. Juveniles forage for themselves (parental feeding stays off; spec §17 open item); `repro.juvenile_food_factor` optional. Death by old age: draw each entity's death age at birth (lifespan × variance from `Rng.hash3`) and store it in an SoA array.
4. **Mating.** New utility actions `seek_mate` and `mate`, scored from `mating_propensity`, fertility state, and need (hunger suppresses mating; choose the shape and report it). A fertile, non-pregnant adult female and a fertile adult male mate when adjacent and both have chosen to. Compatibility = genome distance ≤ `repro.mate_compat_cutoff`.
   - **Genome distance:** the mean absolute difference over all genes, each normalised by (max − min). Put it in one function; Phase 8 tribes will reuse it.
   - Limit the compatibility checks per decision to the nearest `repro.mate_candidates_max` entities of the other sex in sight (perf).
   - Refractory period after mating for both sexes (`repro.refractory_days`).
   - Conception succeeds with probability = the female's fertility × stage multiplier.
5. **Inheritance at conception.** Build the child genome at conception and store it in one genome-sized SoA block `fetal_genome` (this replaces the spec's `pregnancy_father_genes`).
   - Uniform per-gene crossover, then mutation per gene with `mutation_rate` and `mutation_scale` from `genes.json` × the global `repro.mutation_scale_multiplier`. Gaussian by default (distribution configurable); clamp to bounds.
   - Randomness is counter-based only: `Rng.hash3` keyed by (stream, tick, mother uid, gene index). Never a sequential stream.
   - Report the genome's storage type and confirm the mutation arithmetic is reproducible bit for bit (the same operations in the same order, for a later Rust port).
6. **Gestation and birth.** A `gestation_timer` SoA array; an optional mobility penalty (`repro.gestation_speed_factor`). At term, the child goes into the nearest free passable cell within `repro.birth_radius`. If no cell is free, retry each tick up to `repro.birth_delay_max` ticks, then the pregnancy is lost (counted). Births run in a sequential step in slot order, so occupancy stays one per cell and results do not depend on thread count. Sex at birth comes from `entity.birth_sex_ratio`.
7. **Lineage.** Add a never-reused `uid` SoA array (slots are recycled, so slot ids cannot serve as lineage keys). Each entity stores mother uid, father uid and generation number. An append-only lineage table indexed by uid holds dead ancestors. Provide an ancestry query function (parents, grandparents, children). It is saved and loaded. Report its size after the 50-year run.
8. **Derived values at birth.** A newborn's derived costs are computed from its genome at birth, as founders' are at spawn.
9. **Population control:** none enforced. Add `repro.auto_reseed` (default off).
10. **Gene report tool.** `tools/gene_report.gd`, headless: gene mean and variance per N ticks (N in registry), births, deaths by cause (starvation, old age, lost pregnancy), population, sex ratio, and stage counts. Write CSV plus an SVG chart. Phase 5 builds the full harness; keep this minimal.
11. **Inspector:** show stage, age and death age, pregnancy and time to term, uid, parents, generation, and the new utility scores.
12. **Save format:** bump the version for all new arrays and blocks. Earlier saves still load: entities from them become generation-0 adults with fresh uids and no pregnancy. Add a load test for the previous version's file layout.

### Out of scope
Tribe-aware logic (including `mate_choice_in_tribe` behaviour), signals, combat, building, parental feeding, the full observability UI (Phase 5), and search sweep direction (Phase 3 open item, still deferred).

### Acceptance criteria
- **Cost tests:** for each derived cost term, a genome at the gene's max gives a strictly higher cost than at default (with the other genes at default), and the same holds after a mutated birth.
- **Mutation off:** with `repro.mutation_scale_multiplier` = 0, every child gene equals one parent's value exactly (test over at least 1,000 births). With it high (state the value), gene variance after 5 years is visibly higher than at the default (numbers from the gene report).
- **Selection:** run a scarce-food scenario and an abundant one from the same seed for at least 20 years (any map size; state which). At least one gene's mean differs between the two beyond its across-seed noise (3 seeds each). Report which genes moved and in which direction, and whether a cost visibly stopped the drift. A gene pinned at a bound is a finding to report, not a pass.
- **Long run:** default parameters, 50 simulated years on a 1024² map with founders scaled to area. Report population over time, births and deaths by cause, and generations reached. Pass = no extinction, plus visible growth and oscillation. Otherwise, explain what happened and suggest parameter changes; do not tune past placeholders without asking.
- **Full scale:** 5 years at 4096² with default founders. Report the same metrics.
- **One per cell:** the 10k-tick assertion and the per-tick invariants hold with births on.
- **Determinism:** identical hashes at 1, 3 and 8 threads on the Part A sustainable-density scenario (512², ≥ 7,680 ticks, births > 0). Identical full-scale hashes, and save → load → continue matches, including mid-pregnancy.
- **Perf gate:** ms/tick at 10k, 50k and 100k (summer, headless, 8 threads, 2,000-tick warmup, as in Phase 3) with reproduction on. Also a 100k row with every entity at `sense_radius` max, and a 100k row in a mating-heavy state (most adults fertile and seeking mates). Give the per-phase breakdown, including any new phase (mate search, births). Apply the §13 rule to every 100k row. Do not start a Rust port. Flag any regression above 10% against the Phase 3 rows.

### Report back
- Part A results and its commit message, before starting Part B.
- Each acceptance criterion with its evidence (test names, numbers, hashes, chart paths).
- The perf table, the §13 rule outcome, and the top three bottlenecks at 100k.
- Every interpretation or deviation, and every new parameter and gene (all `tuned: false`).
- Changes to `MASTER_SPEC.md` (§4 state arrays, §4.1 gene list, §4.1.1 new terms, §4.2 genome distance and conception-time genome, §5 memory ring item id, §14 save version) and to `DECISIONS.md`, in the same commit as the code.
- Proposed commit message. Do not commit Part B, merge or push until approved.
