# snouty-art

Code-driven pixel art pipeline for the Snouty badge carts. The approved Snouty
design (Run Study 05) is decomposed into a parts rig; animations are Python
files that place parts and draw limbs; the exporter writes strips, sheets,
indexed PNGs, metadata and preview GIFs on the fixed 15-colour palette.

    python3 tools/build.py                 # every style, out/<style>/<cycle>
    python3 tools/build.py --style study05 run
    python3 tools/compare_styles.py run    # all styles side by side

Requires Python 3 with Pillow and numpy. See PLAN.md.

Layout: `ref/` canonical references, `styles/<name>/` one visual style (rig,
palette, parts, anim overrides), `snoutyart/` the library and shared
animations, `out/<style>/` generated packs.

## Reviewing on your laptop

    scp -r animated-badge.exe.xyz:snouty-art/out ~/snouty-art-out
    open ~/snouty-art-out/study05/run/snouty_run_preview.gif    # 4x, scrolling ground
    open ~/snouty-art-out/study05/run/snouty_run_contact_sheet.png
    open ~/snouty-art-out/study05/jump/snouty_jump_preview.gif

Or clone the whole repo: `git clone exedev@animated-badge.exe.xyz:snouty-art`.
Every pack has `*_isolated.gif` (plain background), `*_slow.gif` (3x slower),
`*_contact_sheet.png` (all frames, labelled, with origin guides), and the
build inputs (`*_strip.png`, `*_indexed.png`, `*_key.png`, `*.json`).
