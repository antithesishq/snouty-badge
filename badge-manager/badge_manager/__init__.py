"""badge_manager: the headless badge station (badge-manager/PLAN.md).

Python 3.11+ standard library only. Layout:

  config.py    station.toml -> Config
  fat12.py     badge drive geometry, root-entry and cluster accounting, fit checks
  device.py    finding, mounting, wiping, filling and ejecting the badge drive;
               BlockBadge (real), LoopBadge (image, VM), DirBadge (directory, tests)
  library.py   manifest.toml: carts, roms, sets; deploy plans with short ROM names
  station.py   Station: polls the badge, runs deploy/wipe/sync under a lock, keeps a log
  cli.py       the `badge` command (python3 -m badge_manager ...)
  server.py    JSON API + the phone page (www/index.html)

Status/JSON contract (Station.status()), M1:
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
   "build": {"local": bool, "remote": str|None},
   "sets": [{"name": str, "title": str, "bytes": int, "entries": int,
             "bytes_capacity": int, "entries_capacity": int,
             "fits": bool, "why": [str],
             "carts": [str], "roms": [str],       # as written in the manifest (roms may be globs)
             "files": [str]}],                    # drive names the plan would write
   "library": {"carts": [{"key": str, "title": str, "use": "ram"|"xip",
                          "mode": str, "file": str, "size": int,   # of the variant in use
                          "variants": {"ram": {"file": str, "size": int, "ok": bool, "error": str},
                                       "xip": {...}},              # only the ones that exist
                          "roms": [str], "ok": bool, "error": str, "auto": bool}],
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
"""
__version__ = "0.1.0"
