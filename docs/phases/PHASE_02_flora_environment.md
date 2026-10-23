# Phase 2: Flora and Environment

Read `docs/MASTER_SPEC.md`. Implement only this phase. Language per the Phase 1 decision.

## Goal
A living plant layer driven by substrate, fertility, moisture, season, and time of day.

## Scope
1. **Time system**: tick -> hour -> day -> season -> year, all lengths in the registry. Day/night factor and season index exposed to other systems.
2. **Flora definitions** in `config/flora.json`: substrate_mask, growth_rate, seed_spread_radius, seasonal_yield[4], harvest_item, nutrition, fertility_consumption, moisture_need. Start with 4-6 types (grass, shrub, berry bush, tree, reeds, fungus).
3. **Growth**: sampled-cell update (fraction of map per tick is a parameter, not all 16.7M). Growth depends on substrate, fertility, moisture, season, day/night. Plants cannot grow on disallowed substrates (rock, water).
4. **Spreading**: mature plants seed onto nearby valid tiles within seed_spread_radius.
5. **Seasonal yield**: harvestable biomass scales with season. Growth slows or stalls in winter per type.
6. **Harvest API**: `harvest(cell, amount) -> items`, reduces biomass, drains fertility. (Entities will call it in Phase 3.)
7. **Stall hook**: a per-cell `growth_stall` multiplier read from structure material (stub returns 1.0 for now; Phase 7 fills it in).
8. **Moisture dynamics**: simple moisture diffusion from water tiles plus optional weather/rain parameter.
9. **Renderer**: flora overlay colored by type and biomass, season tint option, day/night shading toggle.
10. **Dev tool**: debug brush to harvest or plant for testing.

## Out of scope
Entities, corpses, decomposition (Phase 3).

## Acceptance criteria
- Starting from a seeded world, flora coverage reaches a stable band (not extinct, not saturated) over 10 simulated years with default params; a chart/log of coverage per type per season is produced.
- Seasonal yield visibly varies; winter stalls match the config.
- Fertility drops under heavy harvest and recovers when left alone.
- Determinism hash test still passes with flora enabled.
- Tick cost with flora enabled is recorded in `docs/PERF.md`; sampled update keeps added cost under 15% of the tick budget.
