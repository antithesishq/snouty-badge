# snouty-art

Code-driven pixel art pipeline for the Snouty badge carts (`../carts/`).
The approved Snouty design (Run Study 05) is decomposed into a parts rig;
animations are Python files that place parts and draw limbs; the exporter
writes strips, sheets, indexed PNGs, metadata and preview GIFs on the fixed
15-colour palette. Commands below run from this directory.

    python3 tools/build.py                 # every style, out/<style>/<cycle>
    python3 tools/build.py --style study05 run
    python3 tools/compare_styles.py run    # all styles side by side

Requires Python 3 with Pillow and numpy. See PLAN.md.

Layout: `ref/` canonical references, `styles/<name>/` one visual style (rig,
palette, parts, anim overrides), `snoutyart/` the library and shared
animations, `out/<style>/` generated packs.

## Reviewing on your laptop

    git clone --recursive git@github.com:antithesishq/snouty-badge.git && cd snouty-badge
    open snouty-art/out/study05/run/snouty_run_preview.gif    # 4x, scrolling ground
    open snouty-art/out/study05/run/snouty_run_contact_sheet.png
    open snouty-art/out/study05/jump/snouty_jump_preview.gif

Every pack has `*_isolated.gif` (plain background), `*_slow.gif` (3x slower),
`*_contact_sheet.png` (all frames, labelled, with origin guides), and the
build inputs (`*_strip.png`, `*_indexed.png`, `*_key.png`, `*.json`).
