# Phase 10: Diplomacy and Tribe Merges

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Tribes build goodwill through sharing and mutual defense, and can merge when goodwill, proximity, and genetics all line up.

## Scope
1. **Goodwill ledger**: per tribe-pair value in [-1, 1], symmetric or asymmetric (param; default asymmetric, with a mutual value taken as the min). Rises with gifts, shared defense, cross-tribe mating, and time without conflict. Falls with attacks, kills, theft, encroachment. Decay toward neutral over time.
2. **Sharing behavior**: entities with `generosity` and `share` propensity may give food/items to outsiders they are not hostile to. Utility depends on surplus, recipient need, goodwill, signal response. Gifts update goodwill proportional to value.
3. **Defending allies**: when a member of a friendly tribe (goodwill above `defend_goodwill_threshold`) is attacked within sense range, entities may join the defense (gene + utility). Defense raises goodwill; attacking the defender lowers it.
4. **Hostility vs goodwill interaction**: hostility ledger (Phase 9) and goodwill are separate values; combat can reverse goodwill over time.
5. **Reputation**: tribes keep memory of who helped/hurt them; a limited "third-party" effect (e.g. a tribe that attacks your ally loses goodwill with you), strength in registry.
6. **Merge rule** (all must hold for `merge_sustain_ticks`): mutual goodwill >= `merge_goodwill_threshold`; a chain of members across the border within `tribe_link_radius`; centroid genome distance <= `merge_genome_threshold`. Also respects the Phase 8 graph (the components must be adjacent).
7. **Merge execution**: larger tribe keeps ID; recipe sets unioned; proficiency per recipe by max or weighted average (param); hostility/goodwill ledgers toward third parties combined (weighted by size); smaller tribe's history retained as `merged_from`. Event logged.
8. **Cross-tribe mating** from Phase 4/8 now feeds goodwill; confirm gene flow over borders is measurable.
9. **UI**: goodwill/hostility matrix, diplomacy events in log, tribe detail panel shows allies, enemies, merge candidates and progress toward merge conditions.

## Out of scope
Player diplomacy tools.

## Acceptance criteria
- Test scenario: two tribes, adjacent, high gift rate, similar genomes merge; with high hostility they do not; with distance beyond link radius they never merge.
- Merged tribe has the union of recipes; ledgers combine correctly (unit tests).
- Batch run over 20 seeds reports the rate of merges, splits, and wars, and checks that no single tribe swallows the whole map under defaults (document if it does, with param suggestions).
- Determinism hash test passes.
- Perf recorded.
