# Phase 7: Build and Cook

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Entities construct walls, shelters, storage, and hearths from harvested materials, and cook food at hearths. Each material has its own effect profile.

## Scope
1. **Materials table** `config/materials.json`: wood, stone, mud, hide to start. Per-material multipliers: energy_loss_reduction, production_speed, flora_stall, durability, build_cost, fire_cooking_factor. Placeholder values marked `tuned: false`.
2. **Resource harvesting**: gather wood (trees), stone (rock tiles/outcrops), mud, hide (from corpses/animals or a stand-in). Items stored in the item layer or carried.
3. **Structures**: wall, floor, hearth, storage. Placement validity from substrate `allows_building`. Structure layers per Master Spec. Walls block movement (and occupancy). HP and decay over time; repair action.
4. **Build behavior**: utility action driven by `build` propensity, need for shelter, and signal build_affinity. Entities choose a site, fetch materials, build in increments. Building time reduced by production_speed.
5. **Shelter detection**: incremental flood-fill of enclosed regions bounded by structures; recalculated only on structure change. Shelter capacity = interior tile count (strict one-per-cell). Occupants get energy_loss_reduction and production_speed from the shelter's material mix.
6. **Flora stall**: fill in the Phase 2 stub; cells under or inside shelters apply the material's flora_stall.
7. **Cooking**: requires a hearth. Entity brings raw food and fuel, cooks over time (reduced by production_speed and fire_cooking_factor), producing cooked food with `cook_energy_multiplier` times the energy. `cook` propensity gene drives it.
8. **Storage**: deposit/withdraw, capacity per storage structure, entities use stored food when hungry.
9. **Production speed**: apply shelter bonus to crafting, cooking, building, and gestation/reproduction timers as separate multipliers in the registry.
10. **Renderer**: structures overlay colored by type/material; inspector shows structure HP, material, occupants.

## Out of scope
Tribe-owned buildings and recipes (Phase 8), combat damage to structures (Phase 9, stub the HP interface).

## Acceptance criteria
- In a harsh-winter preset, shelter occupants show measurably lower energy loss than outsiders; reported in a test script.
- Cooked food yields more energy per unit than raw; a hearth is required (cooking attempts without one fail).
- Building propensity gene shows selection pressure: in a cold/harsh scenario its mean rises over generations; in a mild scenario it stays flat or falls because of its cost.
- Enclosure detection correct on test layouts (open ring, closed ring, diagonal gaps).
- Perf recorded; shelter recompute is incremental.
