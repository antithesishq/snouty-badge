#!/usr/bin/env bash
# Build the bare-metal bench ELF: the cart's tracer modules plus a stub
# cart-api (src/cart.zig) and a render_frame entry (src/entry.zig), same
# target, CPU features and optimize mode as the badge cart (build.zig).
#
# Every *.zig (and @embedFile'd *.bin) under cart/src is copied into build/src/ except the files in
# EXCLUDE below, which need the OS (main.zig is replaced by src/entry.zig).
# New modules Track D or anyone else adds are picked up automatically.
#
# usage: tools/emu/build.sh        (writes tools/emu/build/bench.elf)
#        EMU_CART_SRC=/path/to/cart/src tools/emu/build.sh   (build another tree)
#        EMU_VARIANT=half30 tools/emu/build.sh   (M2.1 variant; default cut20, the shipped one)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CART_SRC="${EMU_CART_SRC:-$REPO/cart/src}"  # override to A/B another tree
BUILD="$HERE/build"
EXCLUDE="main.zig input.zig overlay.zig"
VARIANT="${EMU_VARIANT:-cut20}"

command -v zig >/dev/null 2>&1 || {
    echo "emu: zig not found on PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")" >&2
    exit 1
}

rm -rf "$BUILD/src"
mkdir -p "$BUILD/src"
copied=""
while IFS= read -r rel; do
    rel="${rel#./}"
    skip=0
    for x in $EXCLUDE; do [ "$rel" = "$x" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    mkdir -p "$BUILD/src/$(dirname "$rel")"
    cp "$CART_SRC/$rel" "$BUILD/src/$rel"
    copied="$copied $rel"
done < <(cd "$CART_SRC" && find . \( -name '*.zig' -o -name '*.bin' \) -type f | LC_ALL=C sort)
if [ -e "$BUILD/src/entry.zig" ]; then
    echo "emu: cart/src/entry.zig clashes with tools/emu/src/entry.zig; rename one" >&2
    exit 1
fi
cp "$HERE/src/entry.zig" "$BUILD/src/entry.zig"
echo "emu: copied from $CART_SRC:$copied"
# Stand-in for the build_options module build.zig generates (variant.zig
# takes the enum type from the value, so the tag names are all that must match).
cat > "$BUILD/build_options.zig" <<EOF
pub const debug_overlay: bool = false;
pub const reflections_variant: enum { full20, cut20, full15, half30 } = .$VARIANT;
EOF

echo "emu: zig $(zig version): building build/bench.elf (variant $VARIANT)"
zig build-exe -OReleaseFast \
    -target thumb-freestanding-eabihf -mcpu cortex_m33+dsp+fp_armv8d16sp \
    -fno-entry --export=render_frame -T "$HERE/link.ld" \
    --cache-dir "$BUILD/.zig-cache" \
    --name bench -femit-bin="$BUILD/bench.elf" \
    --dep cart-api --dep build_options -Mroot="$BUILD/src/entry.zig" \
    -Mcart-api="$HERE/src/cart.zig" -Mbuild_options="$BUILD/build_options.zig"
