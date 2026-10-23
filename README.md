# EvoSim prompt pack

1. Create an empty repo, copy this `docs/` folder into it.
2. Start Claude Code in the repo root.
3. For each phase, in order, paste:

   > Read docs/MASTER_SPEC.md and docs/phases/PHASE_NN_<name>.md. Implement only that phase. Follow the working agreement in section 16 of the spec. Stop when the acceptance criteria are met and report.

4. Review the report, run the sim yourself, adjust parameters or the spec, then move to the next phase.

Do not skip Phase 1: its spike decides GDScript vs Rust.
Update `MASTER_SPEC.md` when you change a decision, so later phases inherit it.
