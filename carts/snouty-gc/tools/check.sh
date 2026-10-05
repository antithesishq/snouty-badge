#!/usr/bin/env bash
# Snouty GC gate: everything a milestone must pass before it is tagged
# (PLAN.md "M0 gate"). Run from anywhere; paths are relative to this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh test preview    # only the named steps
#
# Steps:
#   build    zig build -Dcart=snouty-gc (RAM ELF, UF2, wasm) at the repository root
#   test     zig build test (every cart's host tests and lib/'s); when that
#            fails, zig build test-gc (this cart's alone) decides, and the
#            step says which (other carts' runners are not this cart's gate)
#   float    zig build check-float -Dcart=snouty-gc (no soft-float or libm)
#   tracks   tools/build_tracks.py into a temp dir: byte-identical to the
#            committed cart/src/gen/tracks/*.bin (generator deterministic,
#            data current); M7: tools/test_pack/make.py rebuilds TEST.GCP
#            and the drive images, build_pack.py every assets/packs/*/ to
#            its committed .GCP (and the copy in cart/src/gen/packs),
#            tools/test_build_pack.py and tools/packs/test_packs.py pass
#   preview  headless preview.mjs runs on the wasm:
#            - tools/scripts/m0_race.json replayed equals the autopilot's own
#              drive (debug_world_sum): input scripts reproduce a race;
#            - a Quick Race driven by the autopilot reaches the results
#              screen with SNOUTY's 3 laps done, combat on (from M1 a car
#              may be wrecked when the results come up; from M2 pickups make
#              it about 7,300 ticks, so it gets 9,000 frames), and the World
#              under the cap of sim_test (tuning.world_cap: 2,624 B since M6);
#            - the attract demo starts after 10 s idle on the title;
#            - the racer select (M1, M3 flow): Start, Start, A (QUICK RACE)
#              opens it, Right x3 shows SYSADMIN, B goes back to the main
#              menu, A, Left picks BOTNET and A races it;
#            - the main menu (M3; rows QUICK RACE, GARBAGE COLLECTION,
#              M6 BATTLE, CIRCUIT, PICKUPS, LINK, SOUND): Down x5, A on LINK
#              stays on the menu, Up x4, A opens GARBAGE COLLECTION's
#              select, A races a GC race;
#            - the PICKUPS page: Down x4, A on PICKUPS opens it, the arrows
#              walk all 15 cells (wrapping), B goes back to the menu;
#            - a GARBAGE COLLECTION race with the autopilot reaches the
#              results with one car left;
#            - the render stress scene (debug_stress) fills the depth list
#              past its cap: 64 objects drawn of more gathered (at frame
#              200: in its first 150 frames SNOUTY's CAPTCHA card covers
#              the floor and nothing under it is drawn);
#            - the M2 gags (docs/preview_m2.gif's run): a CAPTCHA forced on
#              SNOUTY is solved by A presses on its lit cells, a KERNEL PANIC
#              shows the blue screen (frozen > 60), a FORK BOMB ahead forks;
#            - LINK (M4): the simulator's link is offline (A on LINK stays on
#              the menu), the made-up LINK screens (debug_link_view) open the
#              lobby and the link select, and a Quick Race after them is a
#              single-player race (debug_linked 0).
#            - M5: the M0-M4 input scripts (m0_race, m2_race, m3_gc_race,
#              m3_outflow_race; 3,000 updates each) replay to the World
#              checksums recorded at M4 (debug_world_sum): the garage, the
#              chips and the career changed nothing outside the CIRCUIT;
#            - M5: A on the title opens the Quick Race select, A races (two
#              presses, SPEC 8.1);
#            - M5 CIRCUIT: Start, Start, Down x3, A (CIRCUIT), A (SNOUTY) is
#              the garage; 2,000 CYCLES given, FRONT L2 and PLATING L1
#              bought (1,100 left); Start races the Dumps' first track with
#              the autopilot to the results, A A the standings (race 1
#              booked, CYCLES earned), A the garage; then made-up results
#              (debug_prix_skip) close the Dumps (the league card, the
#              Runoff unlock card), the Runoff, and reach the end card.
#            - M6 (Track A): a BATTLE round on The Sandbox (debug_start_battle,
#              the autopilot driving SNOUTY) runs to its end by lives or by
#              time with eliminations scored; Track B's previews follow in
#              their own block:
#            - M6 (Track B): the menu's 7 rows (the cursor walks to SOUND
#              and round), A on BATTLE opens the racer select, A the setup
#              (screen 12, the cursor on FIGHT!), B back to the select and A
#              again, LIVES to INF and TIME to 2, A fights: a BATTLE round
#              with INF lives and 2:00 on the clock;
#            - M6 LINK BATTLE in the made-up lobby (debug_link_view,
#              debug_link_mode): the host's mode row cycles to LINK BATTLE,
#              its LIVES and TIME rows change, the link select shows it,
#              WRONG VERSION is drawn;
#            - M6: a round on 1 life where SNOUTY is wrecked by LEGACY
#              (debug_battle_kill): out, the claw, the kill leader's camera,
#              then pause and resume, and the round to its results card
#              and standings;
#            - M6: the arena stress scene with the battle HUD's stress
#              (debug_battle_stress) runs 300 frames;
#            - M7: a wasm with the content packs on its simulator drive
#              (-Dgc-pack): the picker's 14 track rows (REENTRY FIELD picked
#              and raced), ANCHOR STORE to the results with the autopilot, a
#              BATTLE round in Hangar 18.
#   bench    badge-bench (calibrated) on badge-bench/carts/snouty-gc.toml,
#            once plain and once with --lcd, and the render stress scene
#            (--poke gc_stress=1, tools/scripts/m1_render_stress.json) plain
#            and --lcd, tools/scripts/m2_race.json (3,000 frames of an
#            autopilot race with pickups in play), m3_outflow_race.json
#            (1,500 frames on Outflow Canyon, the busiest track) and
#            m3_gc_race.json (3,600 frames of a GARBAGE COLLECTION race on
#            Monitor Dunes: marks, claws, the Sweeper), M5's
#            m5_circuit_race.json (3,000 frames: the menus, the garage, a
#            CIRCUIT race with chips and the AIs' loadouts) and m5_cards.json
#            (--poke gc_cards=1: garage purchases, the standings, the league,
#            unlock and end cards), M6's BATTLE round (--poke gc_battle=1,
#            3,600 frames: SNOUTY on the autopilot among five hunters on The
#            Sandbox) and the arena stress scene (--poke gc_battle=2), each
#            plain and --lcd: worst `busy ms` <= BENCH_MAX_MS (default 8, SPEC
#            13.1), no crash, no neopixel warning. M4: the stress scene and
#            m3_gc_race.json once more with `--poke gc_pump_probe=1` (every
#            link pump point runs, the link searching: a link race's draw
#            cost) under the same limit, and the worst gap between two pumps
#            by site from their traces (informational, PLAN M4 status).
#            M7: from the content packs' drive image (--romfs
#            drive_packs.img), ANCHOR STORE (its props) and REENTRY FIELD
#            (the busiest pack map) raced by the autopilot and the stress
#            scene on ANCHOR STORE, plain, --lcd and with every drive read
#            costing 20 cycles (--flash-read-cycles 20), under the same limit.
#            Every run maps a drive (the toml's drive_empty.img by default).
#
# Output under out/check (gitignored). Exit 0 when every step passes, else 1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

wasm="$root/zig-out/bin/snouty-gc.wasm"
elf="$root/zig-out/firmware/snouty-gc.elf"
preview="$root/tools/preview.mjs"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-8}"

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(build test float tracks preview bench)
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case "$s" in build|test|float|tracks|preview|bench) ;;
        *) echo "check: unknown step '$s' (build test float tracks preview bench)" >&2; exit 2 ;;
    esac
done
rm -rf "$out"
mkdir -p "$out"

if want build; then
    step "build: zig build -Dcart=snouty-gc"
    (cd "$root" && zig build -Dcart=snouty-gc); result build $?
fi

if want test; then
    step "test: zig build test"
    if (cd "$root" && zig build test > "$out/test-all.txt" 2>&1); then
        echo "every cart's host tests pass"
        result test 0
    else
        grep -E "error:|failed" "$out/test-all.txt" | head -5
        echo "zig build test failed (see $out/test-all.txt); running this cart's tests alone"
        (cd "$root" && zig build test-gc -Dcart=snouty-gc --summary all 2>&1 | tail -3; exit "${PIPESTATUS[0]}")
        st=$?
        [ "$st" = 0 ] && echo "test-gc passes: the failure is in another cart's runner"
        result test "$st"
    fi
fi

if want float; then
    step "float: zig build check-float -Dcart=snouty-gc"
    (cd "$root" && zig build check-float -Dcart=snouty-gc); result float $?
fi

if want tracks; then
    step "tracks: tools/build_tracks.py is deterministic and the committed data current"
    tmp="$out/tracks"
    mkdir -p "$tmp"
    st=0
    python3 "$here/build_tracks.py" --out "$tmp" --docs "$tmp/docs" > "$out/tracks.txt" 2>&1 || st=1
    for f in "$tmp"/*.bin; do
        cmp -s "$f" "$cart/cart/src/gen/tracks/$(basename "$f")" || { echo "differs: $(basename "$f")"; st=1; }
    done
    [ "$st" = 0 ] && echo "$(ls "$tmp"/*.bin | wc -l) files byte-identical"
    # M7 track packs: the test pack and its drive images rebuild byte for
    # byte (the content packs' copies beside them feed drive_packs.img);
    # every pack directory under assets/packs/ rebuilds its committed .GCP
    # and its copy in cart/src/gen/packs; build_pack.py's own tests; Track
    # B's pack checks (tools/packs/test_packs.py: its generator current).
    gp="$cart/cart/src/gen/packs"
    mkdir -p "$tmp/packs"
    cp "$gp"/DEADMALL.GCP "$gp"/BONEYARD.GCP "$tmp/packs/" 2>/dev/null
    python3 "$here/test_pack/make.py" --out "$tmp/packs/TEST.GCP" > "$out/packs.txt" 2>&1 || st=1
    for f in TEST.GCP drive_test.img drive_frag.img drive_empty.img drive_packs.img; do
        cmp -s "$tmp/packs/$f" "$gp/$f" || { echo "differs: gen/packs/$f"; st=1; }
    done
    for d in "$cart"/assets/packs/*/; do
        [ -f "$d/pack.toml" ] || continue
        python3 "$here/build_pack.py" "$d" --out "$tmp/packs/built.GCP" --quiet || { st=1; continue; }
        g=$(ls "$d"*.GCP 2>/dev/null | head -1)
        cmp -s "$tmp/packs/built.GCP" "$g" || { echo "differs: $g"; st=1; }
        cmp -s "$tmp/packs/built.GCP" "$gp/$(basename "$g")" || { echo "differs: gen/packs/$(basename "$g")"; st=1; }
    done
    python3 "$here/test_build_pack.py" > "$out/test_build_pack.txt" 2>&1 || { echo "FAIL tools/test_build_pack.py"; st=1; }
    if [ -f "$here/packs/test_packs.py" ]; then
        python3 "$here/packs/test_packs.py" > "$out/test_packs.txt" 2>&1 || { echo "FAIL tools/packs/test_packs.py"; st=1; }
    fi
    [ "$st" = 0 ] && echo "packs: TEST.GCP, the drive images and $(ls -d "$cart"/assets/packs/*/ | wc -l) content packs rebuild byte-identical; pack tool tests pass"
    result tracks "$st"
fi

run_preview() { # name args...
    local name=$1
    shift
    node "$preview" "$wasm" --quiet --out "$out/$name" "$@" > "$out/$name.txt" 2>&1
    local st=$?
    grep -E "FAIL|exports after" "$out/$name.txt"
    return $st
}

if want preview; then
    step "preview: headless runs on $(basename "$wasm")"
    st=0
    menus="$out/menus.json"
    echo '[{"from":2,"to":2,"hold":["START"]},{"from":10,"to":10,"hold":["START"]},{"from":14,"to":14,"hold":["A"]},{"from":20,"to":20,"hold":["A"]}]' > "$menus"
    run_preview replay --frames 600 --script "$here/scripts/m0_race.json" --dump-exports debug_world_sum,debug_tick || st=1
    run_preview autopilot --frames 600 --script "$menus" --call debug_set_autopilot:1 --dump-exports debug_world_sum,debug_tick || st=1
    a=$(grep -o 'debug_world_sum=[-0-9]*' "$out/replay.txt")
    b=$(grep -o 'debug_world_sum=[-0-9]*' "$out/autopilot.txt")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "ok   m0_race.json replays the autopilot's race ($a)"; else echo "FAIL m0_race.json replay '$a' != autopilot '$b'"; st=1; fi
    # M5: the M0-M4 scripts' World checksums at update 2,999, as recorded at M4.
    for g in m0_race:1125151687 m2_race:1116132432 m3_gc_race:-1540294026 m3_outflow_race:69064753; do
        n=${g%%:*}
        run_preview "golden_$n" --frames 3000 --script "$here/scripts/$n.json" --expect "debug_world_sum == ${g##*:}" \
            --dump-exports debug_world_sum > /dev/null || { echo "FAIL $n.json no longer replays to ${g##*:}"; st=1; continue; }
        echo "ok   $n.json replays to its M4 checksum ${g##*:}"
    done
    run_preview race --frames 9000 --call debug_start_race:0 --call debug_set_autopilot:1 \
        --until 'debug_screen == 5' --expect 'debug_screen == 5' --expect 'debug_lap == 3' \
        --expect 'debug_phase == 2' --expect 'debug_world_size <= 2624' \
        --dump-exports debug_tick,debug_rank,debug_best_lap,debug_world_size || st=1
    run_preview attract --frames 760 --press START:2-2 --at '700 debug_screen == 3' --at '700 debug_mode == 1' \
        --expect 'debug_follow == 0' --dump-exports debug_screen,debug_mode,debug_tick || st=1
    run_preview select --frames 120 --press START:2-2 --press START:10-10 --press A:14-14 --press RIGHT:20-20,RIGHT:30-30,RIGHT:40-40 \
        --at '50 debug_screen == 2' --at '50 debug_select_racer == 3' --press B:60-60 --at '70 debug_screen == 6' \
        --press A:80-80 --press LEFT:90-90 --press A:100-100 --at '95 debug_select_racer == 5' \
        --expect 'debug_screen == 3' --expect 'debug_mode == 0' --expect 'debug_follow == 5' \
        --dump-exports debug_screen,debug_follow || st=1
    run_preview menu --frames 80 --press START:2-2 --press START:10-10 --press DOWN:12-12,DOWN:14-14,DOWN:16-16,DOWN:18-18,DOWN:20-20 --press A:22-22 \
        --at '30 debug_screen == 6' --press UP:32-32,UP:34-34,UP:36-36,UP:38-38 --press A:40-40 --at '50 debug_screen == 2' --press A:60-60 \
        --expect 'debug_screen == 3' --expect 'debug_mode == 3' --dump-exports debug_screen,debug_mode || st=1
    run_preview pickups --frames 200 --press START:2-2 --press START:10-10 --press DOWN:12-12,DOWN:14-14,DOWN:16-16,DOWN:18-18 --press A:20-20 \
        --at '25 debug_screen == 11' --at '25 debug_pickup_cursor == 0' \
        --press RIGHT:30-30,RIGHT:34-34,RIGHT:38-38,RIGHT:42-42,DOWN:46-46,LEFT:50-50,LEFT:54-54,LEFT:58-58,LEFT:62-62 \
        --press LEFT:66-66,DOWN:70-70,LEFT:74-74,LEFT:78-78,LEFT:82-82 \
        --at '44 debug_pickup_cursor == 4' --at '48 debug_pickup_cursor == 9' --at '68 debug_pickup_cursor == 10' \
        --at '72 debug_pickup_cursor == 14' --at '84 debug_pickup_cursor == 11' --press UP:90-90 --at '92 debug_pickup_cursor == 5' \
        --press B:100-100 --at '105 debug_screen == 6' --press A:120-120 --at '125 debug_pickup_cursor == 5' \
        --expect 'debug_screen == 11' --dump-exports debug_screen,debug_pickup_cursor || st=1
    run_preview gc --frames 9000 --call debug_start_gc:0 --call debug_set_autopilot:1 --until 'debug_screen == 5' \
        --expect 'debug_screen == 5' --expect 'debug_alive == 1' --expect 'debug_gc_survivor < 6' \
        --dump-exports debug_tick,debug_gc_sweeps,debug_gc_survivor || st=1
    run_preview gags --frames 1500 --call debug_start_race:0 --call debug_set_autopilot:2 \
        --call-at '1300 debug_effect:3' --call-at '1360 debug_roll_pickup:5' --call-at '1410 debug_effect:17' \
        --call-at '1413 debug_effect:1' --press A:1307-1307,A:1312-1312,A:1332-1332,A:1337-1337 \
        --at '1301 debug_captcha > 100' --at '1360 debug_captcha == 0' --at '1420 debug_frozen > 60' \
        --at '1480 debug_forks >= 2' --dump-exports debug_forks || st=1
    run_preview link --frames 200 --press START:2-2 --press START:10-10 --press DOWN:12-12,DOWN:14-14,DOWN:16-16,DOWN:18-18,DOWN:20-20 --press A:22-22 \
        --at '30 debug_screen == 6' --at '30 debug_link_state == 0' --call-at '40 debug_link_view:2' --at '50 debug_screen == 7' \
        --press RIGHT:60-60 --call-at '70 debug_link_view:5' --at '80 debug_screen == 2' --press A:90-90 \
        --call-at '100 debug_link_view:0' --at '110 debug_screen == 7' --press B:120-120 --at '130 debug_screen == 6' \
        --press UP:140-140,UP:142-142,UP:144-144,UP:146-146,UP:148-148 --press A:150-150 --press A:170-170 \
        --expect 'debug_screen == 3' --expect 'debug_linked == 0' --dump-exports debug_screen,debug_linked || st=1
    run_preview quick2 --frames 60 --press START:2-2 --press A:10-10 --at '15 debug_screen == 2' --press A:30-30 \
        --expect 'debug_screen == 3' --expect 'debug_mode == 0' --dump-exports debug_screen,debug_mode || st=1
    run_preview circuit --frames 7700 --call debug_set_autopilot:1 \
        --press START:2-2 --press START:10-10 --press DOWN:12-12,DOWN:14-14,DOWN:16-16 --press A:18-18 --press A:22-22 --call-at '26 debug_prix_give:2000' \
        --press A:30-30 --press DOWN:34-34,DOWN:36-36 --press A:40-40 --press START:50-50 \
        --at '24 debug_screen == 8' --at '45 debug_prix_cycles == 1100' --at '60 debug_mode == 4' --at '7303 debug_screen == 5' \
        --press A:7320-7320,A:7340-7340,A:7370-7370,A:7410-7410,A:7450-7450,A:7480-7480,A:7510-7510,A:7550-7550,A:7590-7590,A:7630-7630,A:7660-7660 \
        --at '7350 debug_screen == 9' --at '7350 debug_prix_race == 1' --at '7350 debug_prix_cycles > 1100' --at '7380 debug_screen == 8' \
        --call-at '7390 debug_prix_skip:1' --call-at '7430 debug_prix_skip:1' --at '7460 debug_screen == 10' --at '7460 debug_card == 0' \
        --at '7490 debug_card == 1' --at '7490 debug_prix_league == 1' --at '7520 debug_screen == 8' \
        --call-at '7530 debug_prix_skip:1' --call-at '7570 debug_prix_skip:1' --call-at '7610 debug_prix_skip:1' \
        --expect 'debug_screen == 10' --expect 'debug_card == 2' --expect 'debug_prix_done == 1' \
        --dump-exports debug_screen,debug_card,debug_prix_cycles || st=1
    # --- M6 Track A: a BATTLE round to its end.
    run_preview battle --frames 12000 --call debug_set_autopilot:1 --call debug_battle_minutes:2 --call debug_start_battle:3 \
        --until 'debug_battle_end > 0' --expect 'debug_battle_end > 0' --expect 'debug_mode == 5' \
        --dump-exports debug_tick,debug_battle_end,debug_battle_out,debug_battle_leader || st=1
    # --- M6 Track B previews (Track B adds its runs here).
    # The menu's 7 rows, BATTLE -> select -> setup (B back, A again) -> INF lives, 2 min -> a round.
    run_preview battle_menu --frames 200 --press START:2-2 --press START:10-10 \
        --press DOWN:12-12,DOWN:14-14,DOWN:16-16,DOWN:18-18,DOWN:20-20,DOWN:22-22 --at '24 debug_menu_row == 6' \
        --press DOWN:26-26 --at '28 debug_menu_row == 0' --press DOWN:30-30,DOWN:32-32 --at '34 debug_menu_row == 2' \
        --press A:36-36 --at '40 debug_screen == 2' --press A:44-44 --at '48 debug_screen == 12' --at '48 debug_setup_row == 4' \
        --press B:52-52 --at '56 debug_screen == 2' --press A:60-60 --at '64 debug_screen == 12' \
        --press UP:70-70,UP:72-72 --press LEFT:74-74 --press UP:78-78 --press RIGHT:82-82,RIGHT:86-86,RIGHT:90-90 \
        --at '94 debug_setup_row == 1' --press A:100-100 --at '104 debug_screen == 3' --at '104 debug_mode == 5' \
        --at '104 debug_battle_left == 7200' --expect 'debug_screen == 3' --expect 'debug_mode == 5' \
        --dump-exports debug_screen,debug_mode,debug_battle_left || st=1
    # LINK BATTLE in the made-up lobby: mode row to LINK BATTLE, LIVES 3 -> 5, TIME 3 -> 5, the link select.
    run_preview battle_link --frames 160 --press START:2-2 --press START:10-10 --call-at '20 debug_link_view:2' \
        --at '24 debug_screen == 7' --press RIGHT:30-30,RIGHT:34-34 --at '38 debug_lobby_rules == 50529282' \
        --press DOWN:42-42,DOWN:46-46,DOWN:50-50 --press RIGHT:54-54 --press DOWN:58-58 --press RIGHT:62-62 \
        --at '66 debug_lobby_rules == 84214786' --call-at '80 debug_link_view:5' --at '90 debug_screen == 2' \
        --call-at '110 debug_link_view:7' --at '120 debug_screen == 7' --call-at '130 debug_link_view:0' \
        --press B:140-140 --expect 'debug_screen == 6' --dump-exports debug_screen,debug_lobby_rules || st=1
    # 1 life: SNOUTY wrecked by LEGACY is out, the claw, the kill leader's camera; pause, resume; the results.
    run_preview battle_out --frames 9000 --call debug_set_autopilot:1 --call debug_battle_minutes:2 --call debug_start_battle:1 \
        --call-at '600 debug_battle_kill:256' --at '601 debug_me_out == 1' \
        --at '760 debug_follow != 0' --press START:800-800 --at '802 debug_screen == 4' --press A:820-820 --at '824 debug_screen == 3' \
        --until 'debug_screen == 5' --expect 'debug_screen == 5' --expect 'debug_battle_end > 0' \
        --dump-exports debug_tick,debug_battle_end,debug_battle_out,debug_follow || st=1
    # The arena stress scene with the battle HUD's stress.
    run_preview battle_stress --frames 300 --call debug_battle_stress --expect 'debug_mode == 2' --expect 'debug_drawn > 30' \
        --dump-exports debug_drawn,debug_gathered || st=1
    # --- end of the M6 Track B previews.
    # --- M7 track packs: a wasm whose simulator drive holds the content packs
    # and the test pack (-Dgc-pack), rows 6.. are pack tracks (DEADMALL's
    # three, BONEYARD's three, TEST's two), arena rows 1.. the packs' arenas.
    gp="$cart/cart/src/gen/packs"
    (cd "$root" && zig build -Dcart=snouty-gc -Dgc-pack="$gp/DEADMALL.GCP,$gp/BONEYARD.GCP,$gp/TEST.GCP" --prefix "$out/packwasm") || st=1
    pw="$out/packwasm/bin/snouty-gc.wasm"
    pack_preview() { local w0="$wasm"; wasm="$pw"; run_preview "$@"; local r=$?; wasm="$w0"; return $r; }
    # The picker: QUICK RACE's select (its frames run the packs' CRCs: all
    # 14 rows are raceable by frame 60), Down to the track row, Left wraps to
    # the last row (TEST's CRUST LOOP, row 13), Left twice more to BONEYARD's
    # REENTRY FIELD (row 11), A races it on the pack track (pack_base + 2).
    pack_preview pack_picker --frames 160 --call debug_pack_count --press START:2-2 --press START:10-10 --press A:14-14 \
        --at '18 debug_screen == 2' --at '60 debug_pack_rows == 14' --press DOWN:30-30 --press LEFT:70-70 \
        --at '74 debug_select_track == 13' --press LEFT:80-80,LEFT:90-90 --at '94 debug_select_track == 11' \
        --press A:100-100 --at '104 debug_screen == 3' --at '104 debug_world_track == 130' \
        --expect 'debug_screen == 3' --dump-exports debug_screen,debug_world_track,debug_pack_rows || st=1
    # ANCHOR STORE (Dead Mall, its props and scrubber) to the results with the autopilot.
    pack_preview pack_anchor --frames 9000 --call debug_pack_count --call debug_start_pack:6 --at '1 debug_world_track == 128' \
        --until 'debug_screen == 5' --expect 'debug_screen == 5' --dump-exports debug_tick,debug_world_track,debug_drawn || st=1
    # A BATTLE round in Hangar 18 (The Boneyard's arena, row 2) runs.
    pack_preview pack_arena --frames 900 --call debug_pack_count --call debug_pack_arena:2 --expect 'debug_mode == 5' \
        --expect 'debug_world_track == 131' --expect 'debug_tick > 600' --dump-exports debug_mode,debug_world_track,debug_tick || st=1
    # --- end of the M7 pack previews.
    run_preview stress --frames 200 --call debug_stress:1 --expect 'debug_mode == 2' --expect 'debug_drawn == 64' \
        --expect 'debug_gathered > 64' --dump-exports debug_drawn,debug_gathered || st=1
    result preview "$st"
fi

if want bench; then
    step "bench: badge-bench (calibrated) $(basename "$elf"), plain and --lcd"
    bench="$root/badge-bench/bench.sh"
    "$bench" --help > /dev/null 2>&1   # create the venv once before the parallel runs
    "$bench" "$elf" --json --symbols --out "$out/bench" > "$out/bench.txt" 2>&1 &
    p1=$!
    "$bench" "$elf" --json --lcd --png 100 --out "$out/bench-lcd" > "$out/bench-lcd.txt" 2>&1 &
    p2=$!
    stress=(--poke gc_stress=1 --script "$here/scripts/m1_render_stress.json")
    "$bench" "$elf" --json --symbols "${stress[@]}" --out "$out/bench-stress" > "$out/bench-stress.txt" 2>&1 &
    p3=$!
    "$bench" "$elf" --json --lcd "${stress[@]}" --out "$out/bench-stress-lcd" > "$out/bench-stress-lcd.txt" 2>&1 &
    p4=$!
    m2=(--frames 3000 --script "$here/scripts/m2_race.json")
    "$bench" "$elf" --json "${m2[@]}" --out "$out/bench-m2" > "$out/bench-m2.txt" 2>&1 &
    p5=$!
    "$bench" "$elf" --json --lcd "${m2[@]}" --out "$out/bench-m2-lcd" > "$out/bench-m2-lcd.txt" 2>&1 &
    p6=$!
    m3o=(--frames 1500 --script "$here/scripts/m3_outflow_race.json")
    "$bench" "$elf" --json "${m3o[@]}" --out "$out/bench-m3-outflow" > "$out/bench-m3-outflow.txt" 2>&1 &
    p7=$!
    "$bench" "$elf" --json --lcd "${m3o[@]}" --out "$out/bench-m3-outflow-lcd" > "$out/bench-m3-outflow-lcd.txt" 2>&1 &
    p8=$!
    m3g=(--frames 3600 --script "$here/scripts/m3_gc_race.json")
    "$bench" "$elf" --json "${m3g[@]}" --out "$out/bench-m3-gc" > "$out/bench-m3-gc.txt" 2>&1 &
    p9=$!
    "$bench" "$elf" --json --lcd "${m3g[@]}" --out "$out/bench-m3-gc-lcd" > "$out/bench-m3-gc-lcd.txt" 2>&1 &
    p10=$!
    m5c=(--frames 3000 --script "$here/scripts/m5_circuit_race.json")
    "$bench" "$elf" --json "${m5c[@]}" --out "$out/bench-m5-circuit" > "$out/bench-m5-circuit.txt" 2>&1 &
    p13=$!
    "$bench" "$elf" --json --lcd "${m5c[@]}" --out "$out/bench-m5-circuit-lcd" > "$out/bench-m5-circuit-lcd.txt" 2>&1 &
    p14=$!
    m5k=(--frames 600 --poke gc_cards=1 --script "$here/scripts/m5_cards.json")
    "$bench" "$elf" --json "${m5k[@]}" --out "$out/bench-m5-cards" > "$out/bench-m5-cards.txt" 2>&1 &
    p15=$!
    "$bench" "$elf" --json --lcd "${m5k[@]}" --out "$out/bench-m5-cards-lcd" > "$out/bench-m5-cards-lcd.txt" 2>&1 &
    p16=$!
    m6b=(--frames 3600 --poke gc_battle=1)
    "$bench" "$elf" --json "${m6b[@]}" --out "$out/bench-m6-battle" > "$out/bench-m6-battle.txt" 2>&1 &
    p17=$!
    "$bench" "$elf" --json --lcd "${m6b[@]}" --out "$out/bench-m6-battle-lcd" > "$out/bench-m6-battle-lcd.txt" 2>&1 &
    p18=$!
    m6s=(--frames 300 --poke gc_battle=2)
    "$bench" "$elf" --json "${m6s[@]}" --out "$out/bench-m6-stress" > "$out/bench-m6-stress.txt" 2>&1 &
    p19=$!
    "$bench" "$elf" --json --lcd "${m6s[@]}" --out "$out/bench-m6-stress-lcd" > "$out/bench-m6-stress-lcd.txt" 2>&1 &
    p20=$!
    # M7: pack tracks from the drive (drive_packs.img): ANCHOR STORE (21
    # props, the scrubber drawn with a props cell) and REENTRY FIELD (the
    # busiest pack map) raced by the autopilot, each also with every drive
    # load costing 20 cycles (--flash-read-cycles: the props cells and the
    # sim's tables are read in place, PLAN L100), and the stress scene on
    # ANCHOR STORE; plain and --lcd.
    pk=(--romfs "$cart/cart/src/gen/packs/drive_packs.img")
    "$bench" "$elf" --json "${pk[@]}" --frames 3000 --poke gc_pack=1 --poke gc_pack_row=6 --out "$out/bench-m7-anchor" > "$out/bench-m7-anchor.txt" 2>&1 &
    p21=$!
    "$bench" "$elf" --json --lcd "${pk[@]}" --frames 3000 --poke gc_pack=1 --poke gc_pack_row=6 --flash-read-cycles 20 --out "$out/bench-m7-anchor-lcd-f20" > "$out/bench-m7-anchor-lcd-f20.txt" 2>&1 &
    p22=$!
    "$bench" "$elf" --json "${pk[@]}" --frames 3000 --poke gc_pack=1 --poke gc_pack_row=11 --flash-read-cycles 20 --out "$out/bench-m7-reentry-f20" > "$out/bench-m7-reentry-f20.txt" 2>&1 &
    p23=$!
    "$bench" "$elf" --json --lcd "${pk[@]}" --frames 3000 --poke gc_pack=1 --poke gc_pack_row=11 --out "$out/bench-m7-reentry-lcd" > "$out/bench-m7-reentry-lcd.txt" 2>&1 &
    p24=$!
    "$bench" "$elf" --json "${pk[@]}" --frames 300 --poke gc_pack=2 --poke gc_pack_row=6 --flash-read-cycles 20 --out "$out/bench-m7-stress-f20" > "$out/bench-m7-stress-f20.txt" 2>&1 &
    p25=$!
    "$bench" "$elf" --json --lcd "${pk[@]}" --frames 300 --poke gc_pack=2 --poke gc_pack_row=6 --out "$out/bench-m7-stress-lcd" > "$out/bench-m7-stress-lcd.txt" 2>&1 &
    p26=$!
    probe=(--poke gc_pump_probe=1)
    "$bench" "$elf" --json "${probe[@]}" "${stress[@]}" --out "$out/bench-probe-stress" > "$out/bench-probe-stress.txt" 2>&1 &
    p11=$!
    "$bench" "$elf" --json "${probe[@]}" "${m3g[@]}" --out "$out/bench-probe-gc" > "$out/bench-probe-gc.txt" 2>&1 &
    p12=$!
    st=0
    wait $p11 || st=1
    wait $p12 || st=1
    wait $p1 || st=1
    wait $p2 || st=1
    wait $p3 || st=1
    wait $p4 || st=1
    wait $p5 || st=1
    wait $p6 || st=1
    wait $p7 || st=1
    wait $p8 || st=1
    wait $p9 || st=1
    wait $p10 || st=1
    wait $p13 || st=1
    wait $p14 || st=1
    wait $p15 || st=1
    wait $p16 || st=1
    wait $p17 || st=1
    wait $p18 || st=1
    wait $p19 || st=1
    wait $p20 || st=1
    for p in $p21 $p22 $p23 $p24 $p25 $p26; do wait "$p" || st=1; done
    for j in "$out/bench/bench.json" "$out/bench-lcd/bench.json" "$out/bench-stress/bench.json" "$out/bench-stress-lcd/bench.json" \
             "$out/bench-m2/bench.json" "$out/bench-m2-lcd/bench.json" \
             "$out/bench-m3-outflow/bench.json" "$out/bench-m3-outflow-lcd/bench.json" \
             "$out/bench-m3-gc/bench.json" "$out/bench-m3-gc-lcd/bench.json" \
             "$out/bench-m5-circuit/bench.json" "$out/bench-m5-circuit-lcd/bench.json" \
             "$out/bench-m5-cards/bench.json" "$out/bench-m5-cards-lcd/bench.json" \
             "$out/bench-m6-battle/bench.json" "$out/bench-m6-battle-lcd/bench.json" \
             "$out/bench-m6-stress/bench.json" "$out/bench-m6-stress-lcd/bench.json" \
             "$out/bench-probe-stress/bench.json" "$out/bench-probe-gc/bench.json" \
             "$out/bench-m7-anchor/bench.json" "$out/bench-m7-anchor-lcd-f20/bench.json" \
             "$out/bench-m7-reentry-f20/bench.json" "$out/bench-m7-reentry-lcd/bench.json" \
             "$out/bench-m7-stress-f20/bench.json" "$out/bench-m7-stress-lcd/bench.json"; do
        [ -f "$j" ] || { echo "FAIL no $j"; st=1; continue; }
        python3 - "$j" "$max_ms" <<'EOF' || st=1
import json, sys
j = json.load(open(sys.argv[1]))
lim = float(sys.argv[2])
s = j["summary"]
ok = s["max_ms"] <= lim and not j.get("warnings")
print("%s %s: mean %.2f ms, worst %.2f ms at frame %d, p95 %.2f, %d frames; limit %.1f"
      % ("ok  " if ok else "FAIL", sys.argv[1].split("/")[-2], s["mean_ms"], s["max_ms"], s["worst_frame"],
         s["p95_ms"], s["frames"], lim))
for w in j.get("warnings", []):
    print("     warning:", w)
sys.exit(0 if ok else 1)
EOF
    done
    for j in "$out/bench-probe-stress/bench.json" "$out/bench-probe-gc/bench.json"; do
        [ -f "$j" ] || continue
        python3 - "$j" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
rows = [[int(x) for x in t.split("gc gaps:")[1].split()] for t in
        (t["text"] if isinstance(t, dict) else t for t in j.get("traces", [])) if "gc gaps:" in t]
if rows:
    names = ["top", "sim", "horizon", "floor", "lines", "sprites", "hud", "after"]
    worst = [max(r[i] for r in rows) for i in range(len(names))]
    print("     %s pump gaps (us, worst by site): %s" % (sys.argv[1].split("/")[-2],
          ", ".join("%s %d" % (n, g) for n, g in zip(names[1:], worst[1:]))))
EOF
    done
    result bench "$st"
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
