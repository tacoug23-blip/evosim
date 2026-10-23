# Phase 9: Combat

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Entities and tribes fight. Hostility is remembered and reciprocated. Combat has real costs so it only evolves where it pays.

## Scope
1. **Combat stats**: attack, defense, damage_resistance genes (with energy/trade-off costs), hp, juvenile/elder multipliers, material and recipe bonuses (e.g. stronger gear recipes from Phase 8).
2. **Fight action**: melee, adjacency required. Damage = f(attack, target defense, resistance, randomness from the combat RNG stream). Attack cooldown. Injuries slow recovery and may reduce speed. Death creates a corpse (Phase 3 mechanics).
3. **Aggression model**: aggression gene baseline plus modifiers: resource scarcity nearby, genome distance to target (xenophobia gene), signal aggression_boost (Phase 6), target's prior hostility to me/my tribe, being attacked recently, group presence (group_preference). Utility chooses fight/flee/ignore.
4. **Flee and fear**: low hp or outnumbered triggers flee; fear memory slot per entity.
5. **Hostility memory**: per-entity short ring of hostile entity IDs/tribes; per-tribe ledger of hostility to other tribes (decays over time, rises on attacks/kills). More likely to be hostile toward those who were hostile (retaliation_bias gene).
6. **Group combat**: allies nearby (same tribe, per group_preference) join fights; numbers matter through proximity, not a separate battle system.
7. **Territory/resource conflict**: optional hostility from contested food and shelter occupancy.
8. **Structure damage**: attackers may damage walls and hearths (hp interface from Phase 7).
9. **Tribe effects**: kills and attacks update tribe-pair hostility ledgers; extinct tribes are logged with cause.
10. **UI**: combat events in the log, overlay of recent fights, hostility matrix panel (tribe x tribe), inspector shows hostility memory and fight stats.

## Out of scope
Diplomacy and merges (Phase 10).

## Acceptance criteria
- Scenario tests: two adjacent tribes under scarcity show higher fight rates than under abundance. A pair with prior hostility fights more than a fresh pair.
- Aggression gene mean evolves differently in high- vs low-scarcity runs; costs prevent runaway aggression in abundance (report from batch harness).
- No cell double occupancy; deterministic hash test passes with combat.
- Repulsion-from-danger test from Phase 6 is now exercised: a signal co-located with hostile territory shows rising repulsion weights (report).
- Perf recorded; combat resolution does not scale worse than linear in entity count.
