#!/usr/bin/env bash
# Collect the badge UF2s from a `zig build` into a release directory and write
# its release notes. Used by .github/workflows/carts.yml for the rolling
# `carts-latest` release; runs the same way locally:
#
#   zig build && tools/release_carts.sh zig-out/firmware out/release
#
# Left out: XIP builds (the SYCL firmware runs RAM carts only), the
# badge-calibrate bench cart and the personal siwoo name badge.
set -euo pipefail

src=${1:?usage: release_carts.sh <firmware dir> <out dir>}
out=${2:?usage: release_carts.sh <firmware dir> <out dir>}
commit=${GITHUB_SHA:-$(git rev-parse HEAD)}
repo=${GITHUB_REPOSITORY:-antithesishq/snouty-badge}

rm -rf "$out"
mkdir -p "$out/carts"

for f in "$src"/*.uf2; do
    name=$(basename "$f")
    case "$name" in
        *-xip.uf2 | badge-calibrate.uf2 | siwoo.uf2) continue ;;
    esac
    cp "$f" "$out/carts/$name"
done

count=$(find "$out/carts" -name '*.uf2' | wc -l)
if [ "$count" -eq 0 ]; then
    echo "release_carts.sh: no UF2s in $src" >&2
    exit 1
fi

{
    echo "Every badge cart, built from \`main\` at [\`${commit:0:8}\`](https://github.com/$repo/commit/$commit) on $(date -u '+%Y-%m-%d %H:%M UTC')."
    echo "This release is rebuilt on every push to \`main\`."
    echo
    echo "**To install:** download a \`.uf2\`, plug the badge in, and copy the file onto the **SYCLBADGE** drive."
    echo "The badge menu lists it within a second."
    echo "The drive holds about 1.25 MB, so only two to four carts fit at a time; delete one to make room."
    echo "On an iPhone: tap a file below, then in the Files app move it from Downloads onto SYCLBADGE."
    echo "The full guide is [docs/INSTALL.md](https://github.com/$repo/blob/main/docs/INSTALL.md)."
    echo
    echo "| File | Size |"
    echo "|---|---|"
    for f in "$out"/carts/*.uf2; do
        name=$(basename "$f")
        kb=$(( ($(stat -c %s "$f") + 1023) / 1024 ))
        echo "| [\`$name\`](https://github.com/$repo/releases/download/carts-latest/$name) | $kb KB |"
    done
} > "$out/NOTES.md"

echo "release_carts.sh: $count carts in $out/carts"
