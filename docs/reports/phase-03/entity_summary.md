# Phase 3 entity scenarios

## Abundant flora

- Flora grown 2.0 years first (3939000 plants); 5000 founders (20 groups of 250) spawned at Year 3, Spring day 1, 00:00; ran 60 days.
- **Survival 99.8%** (4989 of 5000; 11 starved). Pass threshold 95%.
- **100.0% of survivors ate 3+ meals** (pass threshold 90%); mean 9.1 meals per entity; 178711 bites in total.
- Mean energy stayed 73-80% of max after day 10.
- Meals per survivor: 0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 1, 7: 538, 8: 1658, 9: 1362, 10+: 1430
- Meals by item (share of all meals; share of energy eaten): hay 30.2% / 24.6%, twigs 0.5% / 0.1%, berries 21.8% / 24.9%, wood 0.0% / 0.0%, reeds 14.9% / 14.3%, mushrooms 32.6% / 36.1%.
- Deaths by cause: starvation 11.
- Deaths by substrate under the corpse: { "rock": 10, "sand": 1 }; plants within 10 cells of a new corpse 0.0 on average, vs 246.4 around survivors.
- **Result: PASS**

## Low flora (10% of abundant)

- Flora grown 2.0 years (3939000 plants), then thinned at random to 392655 (10.0%); 5000 founders spawned; ran 60 days.
- **Survival 96.0%** (4801 of 5000). Deaths by cause: starvation 199.
- Deaths by substrate under the corpse: { "rock": 133, "soil": 54, "sand": 9 }; plants within 10 cells of a new corpse 1.8 on average.
- Meals by item (share of all meals; share of energy eaten): hay 60.0% / 53.2%, twigs 3.7% / 0.9%, berries 4.1% / 6.0%, wood 0.5% / 0.0%, reeds 15.0% / 16.8%, mushrooms 16.6% / 23.0%; mean 13.2 meals per survivor.
- **Fertility around corpse sites** (176 sites whose corpse appeared by day 49, so fully decayed): +9.3 from appearance to day 60; control land (19851 cells at least 12 from any site) over the same days: -0.6; **attributable to corpses +9.9** fertility units.

## Scarce flora (none at all)

- 5000 founders, no flora. All starved by day 16; first corpse on day 6; 4974 corpse sites (corpses merge when an entity dies on an existing corpse's cell).
- Corpses decay over 10 days, releasing nutrients into land within 2 cells.
- **Fertility around corpse sites: 91.5 when the corpse appeared, 101.5 after decay (+9.9)**; peak 101.7.
- Control land (17888 random land cells at least 12 cells from any corpse), same period: 101.6 -> 101.7 (+0.1).
- Rise attributable to corpses (site change minus control change): **+9.9** fertility units.
- **Result: PASS**

