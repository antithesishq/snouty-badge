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

Status/JSON contract (Station.status()):
  {"badge": {"present": bool, "device": str|None, "mounted": bool,
             "files": [{"name": str, "size": int}], "free_bytes": int|None,
             "free_entries": int|None, "note": str},
   "busy": bool, "action": str|None,            # e.g. "deploy demo"
   "network": {"mode": "hotspot"|"ap"|"wired"|"none", "ssid": str|None,
               "address": str|None, "internet": bool},
   "build": {"local": bool, "remote": str|None},
   "sets": [{"name": str, "title": str, "bytes": int, "entries": int,
             "fits": bool, "why": [str]}],
   "library": {"carts": [...], "roms": [...]},
   "log": [{"t": float, "msg": str}]}          # newest last, last 200 lines
"""
__version__ = "0.1.0"
