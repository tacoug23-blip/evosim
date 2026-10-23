# Phase 8: Tribes and Knowledge

Read `docs/MASTER_SPEC.md`. Implement only this phase. Merging is Phase 10; stub it here.

## Goal
Emergent tribes based on genetic similarity and proximity, with persistent identity, per-tribe proficiency, recipe unlocks, and knowledge that can be kept or lost on splits.

## Scope
1. **Tribe computation**: every `tribe_update_interval` ticks, build a neighbor graph with a spatial hash: edge iff genome distance <= `tribe_genome_threshold` AND spatial distance <= `tribe_link_radius`. Connected components = tribes. Minimum tribe size param (smaller groups are "unaffiliated", tribe_id 0). Incremental or chunked if full recompute is too slow.
2. **Identity persistence**: map new components to previous tribe IDs by majority-membership overlap. Largest fragment of a split keeps the ID; others get new IDs. Handle merges by detection only (log event `tribe_proximity_merge_candidate`); actual merge logic is Phase 10.
3. **Tribe record**: id, founding tick, parent tribe, member count, centroid genome, centroid position, proficiency[domain], unlocked recipes, goodwill/hostility ledgers (empty for now).
4. **Proficiency**: per domain (building, cooking, crafting, foraging, combat, etc.) computed from member activity output over a rolling window. Rate and decay in registry.
5. **Recipes**: `config/recipes.json` with domain, threshold, prerequisites, effect modifiers. Examples: stronger wall material, improved shelter, faster cooking, higher-yield food, better hearth. When proficiency passes threshold, a probabilistic discovery roll runs per interval.
6. **Applying knowledge**: unlocked recipes alter what members can build/cook/craft (new materials, building types, multipliers). Members outside the tribe cannot use them unless they learn by joining/merging.
7. **Split behavior**: new fragments inherit a copy of the knowledge set, each recipe lost with `knowledge_loss_on_split`; proficiency scaled by fragment size ratio.
8. **Tribe-aware mate choice**: wire the `mate_choice_in_tribe` gene to real tribe IDs, replacing the Phase 4 proxy.
9. **UI**: tribe overlay (color per tribe, unaffiliated gray), tribe list panel (size, age, proficiency, recipes), click a tribe to highlight members, per-tribe gene histograms, tribe lineage (parent tribe).
10. **Events**: tribe_founded, tribe_split, tribe_extinct, recipe_unlocked, recipe_lost.

## Out of scope
Combat, diplomacy, merges.

## Acceptance criteria
- Tribes on opposite sides of the map never share an ID, even if genetically identical (test with cloned founders placed far apart).
- A migrating tribe stretched thin splits; IDs persist for the largest fragment across recomputes (test scenario).
- Different tribes in the same run end up with different recipe sets (demonstrated in a 50-year seeded run, reported in a table).
- Tribe computation cost at 100k entities recorded; budget under 10% of tick time amortized.
- Determinism hash test passes.
