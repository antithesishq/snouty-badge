# Snoutenstein 3D

A Wolfenstein-style first-person shooter for the SYCL Badge V2, starring
Snouty, with keyed doors, three weapons, a Doom-style portrait HUD and a
time rewind built on deterministic replay. See `SPEC.md` for the design,
`PLAN.md` for progress and `docs/RUNNING.md` to build and run it.

**Deathmatch (M7).** Two badges on a cable between their UART headers
fight each other: DEATHMATCH on both title screens, the host sets the
arena, frag limit and bugs, both ready with A, the host's Start goes,
then frag each other (hold B and Left/Right to strafe). The two-badge
hardware check is in `docs/RUNNING.md` section 7; the rules are SPEC.md
section 19.
