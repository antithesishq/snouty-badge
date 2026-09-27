#!/usr/bin/env bash
# Regenerates cart/src/levels/gen.zig from cart/src/levels/*.txt.
# Run after editing a level; commit the .txt and gen.zig together.
set -euo pipefail
cd "$(dirname "$0")/.."
zig run cart/src/gen_levels.zig -- cart/src/levels/gen.zig
zig fmt cart/src/levels/gen.zig >/dev/null
