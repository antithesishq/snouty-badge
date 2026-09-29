#!/usr/bin/env bash
# Builds every perf variant (PLAN.md "M2.1 Perf variants") and copies each to
# dist/variants/<name>.{uf2,elf,wasm}, runs the float check per variant and
# prints .text + .data (budget 120 KB) and .bss.
#
#   tools/build_variants.sh [name ...]     # from carts/snouty-reflections/; default all four
#
# Each variant is a separate build at the repository root, so the root
# zig-out/ is left holding the last one built. Takes a few minutes.
set -euo pipefail

cd "$(dirname "$0")/.."
cart_dir=$PWD
root=$(cd ../.. && pwd)
zig=${ZIG:-$HOME/.local/bin/zig}
out=$cart_dir/dist/variants
limit=$((120 * 1024))

variants=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(full20 cut20 full15 half30)

mkdir -p "$out"
summary=()
fail=0
for v in "${variants[@]}"; do
    echo "== $v"
    (cd "$root" && "$zig" build -Dcart=snouty-reflections -Dreflections_variant="$v")
    cp "$root/zig-out/firmware/snouty-reflections.uf2" "$out/$v.uf2"
    cp "$root/zig-out/firmware/snouty-reflections.elf" "$out/$v.elf"
    cp "$root/zig-out/bin/snouty-reflections.wasm" "$out/$v.wasm"
    if (cd "$root" && "$zig" build check-float -Dcart=snouty-reflections -Dreflections_variant="$v"); then
        float=pass
    else
        float=FAIL
        fail=1
    fi
    read -r text data bss < <(size -A "$out/$v.elf" |
        awk '$1 == ".text" { t = $2 } $1 == ".data" { d = $2 } $1 == ".bss" { b = $2 } END { print t + 0, d + 0, b + 0 }')
    code=$((text + data))
    verdict=ok
    if [ "$code" -ge "$limit" ]; then
        verdict=OVER
        fail=1
    fi
    summary+=("$(printf '%-8s %8d %8d %9d %8d  %-5s %s' "$v" "$text" "$data" "$code" "$bss" "$float" "$verdict")")
done

echo
printf '%-8s %8s %8s %9s %8s  %-5s %s\n' variant .text .data text+data .bss float "size (< $limit)"
printf '%s\n' "${summary[@]}"
echo "images in $out"
exit $fail
