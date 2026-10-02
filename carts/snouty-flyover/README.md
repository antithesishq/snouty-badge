# Snouty Flyover: Memory Lane

A Comanche-style voxel heightfield flyover for the SYCL Badge V2, written
in Zig for Antithesis, in which the terrain is the machine. A low-poly 3D
anteater, flapping its forelegs and seen from the same tilted view as the
terrain, flies down an endless 256-cell strip generated on the badge as it
comes into view (the cart ships no map data): the Bus of pulsing lanes,
the Heap where blocks malloc and free and a white garbage-collector wall
sweeps the unreferenced ones to rubble, the Sort where 64-bar bands run a
live quicksort, the binary Tree with a search lighting its path, the Hash
table growing collision terraces until a rehash doubles it, the Stack
canyon the flight dives into frame by frame until the stack overflows, and
the Pipeline whose packets braid through dams into a mirror lake that
reflects the Antithesis Iris sun. Everything is Q16 integer, so the
simulator, the emulated benchmark and the badge draw identical frames, at
a locked 30 fps.

Controls: the stick banks and pitches, A boosts (the fog pulls in), B does
the district's verb (send a packet, collect garbage, shuffle, insert,
rehash, push a frame, burst the pipe), Select skips to the next district,
Start toggles the autopilot, which flies and presses B by itself at boot
and 15 s after the last input.

Status: M4.1, the last planned milestone plus the 3D flyer (tag
`snouty-flyover/m4.1`). Calibrated badge-bench worst frame 15.07 ms of the
22 ms budget over the 2400-frame attract run; not yet run on a badge. GIFs:
`docs/preview_m4_attract.gif`, `docs/preview_m4_verbs.gif`.

```sh
(cd ../.. && zig build -Dcart=snouty-flyover)   # ../../zig-out/firmware/snouty-flyover.uf2, ../../zig-out/bin/snouty-flyover.wasm
```

- `docs/RUNNING.md`: build options, simulator, headless preview, scripts, exports, bench.
- `SPEC.md`: design. `PLAN.md`: milestone contracts and status with the bench numbers.
- `docs/concept/`: the numpy concept renders the look was settled on.
