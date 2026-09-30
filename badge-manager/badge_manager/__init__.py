"""badge_manager: the headless badge station (badge-manager/PLAN.md).

Python 3.11+ standard library only. Layout:

  config.py    station.toml -> Config
  fat12.py     badge drive geometry, root-entry and cluster accounting, fit checks
  device.py    finding, mounting, wiping, filling and ejecting the badge drive;
               BlockBadge (real), LoopBadge (image, VM), DirBadge (directory, tests)
  library.py   manifest.toml: carts, roms, sets; deploy plans with short ROM names
  station.py   Station: polls the badge, runs deploy/wipe/sync under a lock, keeps a log
  build.py     cart build jobs in <library>/builds/<id>/ (PLAN.md 9.2), their own lock
  cli.py       the `badge` command (python3 -m badge_manager ...)
  server.py    JSON API + the phone page (www/index.html)

Status/JSON contract (Station.status()), M1 + M2:
  {"badge": {"present": bool, "device": str|None, "mounted": bool, "ejected": bool,
             "files": [{"name": str, "size": int,
                        "title": str,                 # library title, else the name
                        "kind": "cart"|"rom"|"other"}],
             "set": str|None,                         # set whose plan equals the files
             "free_bytes": int|None, "free_entries": int|None, "note": str},
   "busy": bool, "action": str|None,            # e.g. "deploy demo"
   "network": {"mode": "hotspot"|"ap"|"wired"|"none", "ssid": str|None,
               "address": str|None, "internet": bool},
   "share": {"url": str|None,                   # http://10.42.0.1/ in ap mode, else http://<address>/
             "ssid": str|None, "password": str|None},   # ap mode only, else None
   "build": {"local": bool, "remote": str|None, "ready": bool, "why": str,
             "where": "local"|"remote"|None},           # what "auto" would pick
   "job": None | {"id", "prompt", "name", "title", "where", "state",
                  "started", "seconds", "exit", "error",
                  "log": [str],                          # last 40 lines
                  "result": {"cart", "preview", "bench_ms", "size"} | None},
                                                # the running job, else the last one;
                                                # started = epoch s, seconds live while running
   "builds": [{"id", "name", "title", "state", "started", "seconds",
               "preview", "bench_ms", "error"}],         # newest first, last 10
   "sets": [{"name": str, "title": str, "bytes": int, "entries": int,
             "bytes_capacity": int, "entries_capacity": int,
             "fits": bool, "why": [str],
             "carts": [str], "roms": [str],       # as written in the manifest (roms may be globs)
             "files": [str]}],                    # drive names the plan would write
   "library": {"carts": [{"key": str, "title": str, "use": "ram"|"xip",
                          "mode": str, "file": str, "size": int,   # of the variant in use
                          "variants": {"ram": {"file": str, "size": int, "ok": bool, "error": str},
                                       "xip": {...}},              # only the ones that exist
                          "roms": [str], "ok": bool, "error": str, "auto": bool,
                          "build": str|None,              # the build job that made it
                          "preview": str|None}],          # "/builds/<id>/preview.gif" | None
               "roms": [{"key": str, "title": str, "file": str, "short": str, "size": int,
                         "ok": bool, "error": str, "auto": bool}],
               "error": str},
   "log": [{"t": float, "msg": str}],           # newest last, last 200 lines
   "log_seq": int}                              # change counter for /api/status?since=

HTTP routes (server.py): GET / and /static/*; GET /api/status[?since=N&wait=S];
GET /api/log?n=; POST /api/deploy {"set": key} or {"carts": [...], "roms": [...]};
POST /api/wipe; POST /api/sync; POST /api/upload; POST /api/fit {"carts", "roms"}
-> FitReport as JSON {bytes, entries, bytes_capacity, entries_capacity, fits, why, files};
POST /api/sets {"key"?, "title", "carts", "roms"}; DELETE /api/sets/<key>;
POST /api/cart-mode {"cart": key, "mode": "ram"|"xip"}; GET /qr/page.svg, /qr/wifi.svg.
Actions return {"ok": true} at once (409 when busy); edits return {"ok": true, ...}
after the manifest is rewritten.
Builds (M2, PLAN.md 9.5): POST /api/build {"prompt": str, "where"?: "auto"|"local"|"remote",
"name"?: str} -> {"ok": true, "id"}; 400 empty/too long prompt (2000 chars), 409 a job is
running, 503 build.ready false. GET /api/build -> {"job": the current or last job with its
full log}; GET /api/build/<id> -> that job; POST /api/build/cancel -> {"ok": true}, 404 when
nothing runs; GET /builds/<id>/preview.gif (also preview.png, bench.txt, summary.json from
out/). Builds never take the action lock: a deploy can run while a cart builds.
"""
__version__ = "0.1.0"
