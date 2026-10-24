# Flora report: 10 years, 4096x4096, seed 1337

- Run: 76799 ticks in 719 s; environment pass 9.35 ms/tick mean (33536 samples/tick, 5.21 days between updates of a cell)
- Plantable land: 8583977 cells
- **Stable band: YES.** Last 5 years, same-season total coverage spread 4.1 points (limit 10); range 65.9%-75.2% of plantable land (saturated at 95%); extinct types: none.
- **Winter stalls match config: YES.**

## Coverage (% of plantable land) at the end of each season, final 2 years

| year | season | total | grass | shrub | berry_bush | tree | reeds | fungus | moisture | fertility |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 9 | spring | 71.6 | 23.1 | 12.8 | 3.9 | 1.5 | 16.6 | 13.7 | 0.59 | 0.39 |
| 9 | summer | 73.6 | 24.1 | 13.0 | 4.1 | 1.5 | 17.4 | 13.4 | 0.55 | 0.38 |
| 9 | autumn | 74.7 | 24.3 | 13.3 | 4.3 | 1.6 | 17.8 | 13.4 | 0.56 | 0.38 |
| 9 | winter | 68.8 | 20.5 | 13.5 | 4.0 | 1.6 | 15.7 | 13.4 | 0.59 | 0.38 |
| 10 | spring | 72.2 | 22.1 | 13.8 | 4.3 | 1.6 | 16.8 | 13.6 | 0.61 | 0.39 |
| 10 | summer | 74.1 | 23.1 | 14.1 | 4.5 | 1.7 | 17.5 | 13.3 | 0.58 | 0.39 |
| 10 | autumn | 75.2 | 23.3 | 14.3 | 4.7 | 1.7 | 18.0 | 13.2 | 0.57 | 0.38 |
| 10 | winter | 69.3 | 19.7 | 14.5 | 4.4 | 1.7 | 15.8 | 13.2 | 0.57 | 0.39 |

## Per-type trend (winter coverage, points of plantable land per year, last 3 years)

Total coverage is what the stability check judges. Individual types can still drift
slowly (succession toward long-lived woody plants); this table shows how fast.

| type | winter coverage, final year | change per year |
|---|---:|---:|
| grass | 19.7% | -0.97 |
| shrub | 14.5% | +1.07 |
| berry_bush | 4.4% | +0.36 |
| tree | 1.7% | +0.14 |
| reeds | 15.8% | +0.23 |
| fungus | 13.2% | -0.12 |

## Harvestable yield by season, final year (biomass x seasonal_yield)

| type | spring | summer | autumn | winter |
|---|---:|---:|---:|---:|
| grass | 147637937 | 261421671 | 201863762 | 21292419 |
| shrub | 67918837 | 111510767 | 148211962 | 51786460 |
| berry_bush | 5158932 | 57167998 | 40582331 | 0 |
| tree | 4172873 | 6606258 | 13346905 | 4357335 |
| reeds | 106092533 | 229608718 | 182203151 | 40161506 |
| fungus | 53627032 | 24566337 | 94772955 | 25227074 |

## Winter stalls (all winters)

| type | seasonal_growth[winter] | expected | winter growth | winter births | check |
|---|---:|---|---:|---:|---|
| grass | 0.00 | stall | 0 | 0 | ok |
| shrub | 0.10 | slow growth | 14797209 | 945749 | ok |
| berry_bush | 0.00 | stall | 0 | 0 | ok |
| tree | 0.05 | slow growth | 442149 | 54343 | ok |
| reeds | 0.00 | stall | 0 | 0 | ok |
| fungus | 0.20 | slow growth | 70478929 | 2333473 | ok |
