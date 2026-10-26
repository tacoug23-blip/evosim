# Phase 3 entity scenarios

## Abundant flora

- Flora grown 2.0 years first (3939000 plants); 5000 founders (20 groups of 250) spawned at Year 3, Spring day 1, 00:00; ran 60 days.
- **Survival 98.8%** (4942 of 5000; 58 starved). Pass threshold 95%.
- **100.0% of survivors ate 3+ meals** (pass threshold 90%); mean 9.0 meals per entity; 175706 bites in total.
- Mean energy stayed 72-80% of max after day 10.
- Meals per survivor: 0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 2, 7: 537, 8: 1712, 9: 1422, 10+: 1269
- Meals by item (share of all meals; share of energy eaten): hay 29.4% / 23.6%, twigs 0.5% / 0.1%, berries 22.6% / 25.9%, wood 0.0% / 0.0%, reeds 14.4% / 13.8%, mushrooms 33.2% / 36.6%.
- Deaths by cause: starvation 58.
- Deaths by substrate under the corpse: { "rock": 58 }; plants within 10 cells of a new corpse 0.0 on average, vs 254.1 around survivors.
- **Result: PASS**

## Low flora (10% of abundant)

- Flora grown 2.0 years (3939000 plants), then thinned at random to 392655 (10.0%); 5000 founders spawned; ran 60 days.
- **Survival 89.8%** (4489 of 5000). Deaths by cause: starvation 511.
- Deaths by substrate under the corpse: { "rock": 240, "soil": 235, "sand": 33 }; plants within 10 cells of a new corpse 1.6 on average.
- Meals by item (share of all meals; share of energy eaten): hay 60.2% / 53.2%, twigs 3.8% / 0.9%, berries 4.3% / 6.5%, wood 0.4% / 0.0%, reeds 14.7% / 16.4%, mushrooms 16.5% / 22.9%; mean 12.6 meals per survivor.
- **Fertility around corpse sites** (483 sites whose corpse appeared by day 49, so fully decayed): +9.5 from appearance to day 60; control land (19592 cells at least 12 from any site) over the same days: -0.6; **attributable to corpses +10.1** fertility units.

## Scarce flora (none at all)

- 5000 founders, no flora. All starved by day 18; first corpse on day 6; 4980 corpse sites (corpses merge when an entity dies on an existing corpse's cell).
- Corpses decay over 10 days, releasing nutrients into land within 2 cells.
- **Fertility around corpse sites: 92.6 when the corpse appeared, 101.7 after decay (+9.1)**; peak 101.9.
- Control land (16774 random land cells at least 12 cells from any corpse), same period: 101.0 -> 101.1 (+0.0).
- Rise attributable to corpses (site change minus control change): **+9.1** fertility units.
- **Result: PASS**

