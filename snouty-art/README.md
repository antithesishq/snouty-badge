# snouty-art

Code-driven pixel art pipeline for the Snouty badge carts. The approved Snouty
design (Run Study 05) is decomposed into a parts rig; animations are Python
files that place parts and draw limbs; the exporter writes strips, sheets,
indexed PNGs, metadata and preview GIFs on the fixed 15-colour palette.

    python3 tools/build.py all        # renders out/run and out/jump
    python3 tools/build.py run        # one cycle

Requires Python 3 with Pillow and numpy. See PLAN.md.

Layout: `ref/` canonical references, `rig/` parts + pivots, `snoutyart/` the
library, `snoutyart/anim/` the animation sources, `out/` generated packs.
