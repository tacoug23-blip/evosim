# Phase 6: Signals

Read `docs/MASTER_SPEC.md`. Implement only this phase.

## Goal
Player-placed signals that diffuse across the world and influence entities through evolvable per-channel response genes, followed by entity-emitted signals.

## Scope
1. **Signal fields**: N channels (default 8) at reduced resolution (512x512 default, 1024x1024 option; block size from registry). Per-channel diffusion rate and decay rate. Update on a lower frequency than the main tick (param). GPU compute shader if feasible; otherwise a profiled CPU implementation with chunk skipping for empty regions.
2. **Player tools**: place a source (channel, intensity, radius/shape, duration, position), remove a source, pulse vs sustained. Source list UI. Sources are recorded as events for deterministic replay.
3. **Entity response genes**: per channel, signed weights for attraction, repulsion, aggression_boost, build_affinity. Added to `config/genes.json` with costs/trade-offs (e.g. high sensitivity increases burn). Mutation and inheritance use the Phase 4 pipeline.
4. **Integration with utility scoring**: gradient of the field at the entity's cell feeds move-toward/away scores; aggression_boost modifies aggression baseline (used by Phase 9); build_affinity modifies build site scoring (used by Phase 7). Wire the hooks now with stubs where later phases are needed.
5. **Signal overlay**: per-channel heatmap, toggle channels, intensity scale.
6. **Entity-emitted signals**: new gene-controlled emit behavior with energy cost. Reserved channels for emergent communication. Emission triggers (found food, under attack, found mate) are gene-weighted utility actions. Entities respond with the same response genes, so meaning can evolve.
7. **Experiments**: scripted scenario in `tools/` that places an attraction signal in a world and measures migration toward it, and a repulsion test.

## Out of scope
Terrain editing or spawning by the player (signals only).

## Acceptance criteria
- With founders given positive attraction on channel 0, a source on channel 0 measurably draws them (movement-toward metric reported).
- Over multiple generations with a signal that co-locates with food, attraction weight on that channel rises (reported via gene means). A counter-test with a signal that co-locates with danger shows repulsion rising once Phase 9 exists; document as pending.
- Replay: same seed + recorded signal events gives the same state hash.
- Added cost of fields stays under 15% of the tick budget at 100k entities; numbers in `docs/PERF.md`.
