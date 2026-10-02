#!/usr/bin/env bash
# Host test of cart/src/variant.zig (tests/variant_unit.zig, review G3): the
# frozen path tracer's slice is shorter than the frame period in every
# variant. The same test is part of the root `zig build test`; this runs it
# standalone with `zig test` and a build_options stub whose Variant enum is
# the one in build.zig, so the test sees every variant.
#
#   carts/snouty-reflections/tools/check_variants.sh     # from anywhere; ZIG=/path/to/zig overrides
set -euo pipefail
cd "$(dirname "$0")/.."
zig=${ZIG:-zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
enum=$(grep -E '^const Variant = enum \{' build.zig) || { echo "check_variants: no 'const Variant = enum {' line in build.zig" >&2; exit 1; }
{
    echo "pub const ${enum#const }"
    echo "pub const reflections_variant: Variant = .cut20;"
    echo "pub const debug_overlay: bool = false;"
} > "$tmp/build_options.zig"
"$zig" test --cache-dir "$tmp/cache" -j1 \
    --dep variant -Mroot=tests/variant_unit.zig \
    --dep build_options -Mvariant=cart/src/variant.zig \
    -Mbuild_options="$tmp/build_options.zig"
