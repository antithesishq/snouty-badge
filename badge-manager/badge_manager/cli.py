"""The `badge` command: the same Station the phone page drives, from a shell.

    badge [--config PATH] [--fake-badge PATH] [--json] COMMAND ...

Exit codes: 0 ok, 1 error, 2 precondition (no badge, does not fit, busy,
not available yet).
"""
from __future__ import annotations
import argparse
import json
import sys
import time
from pathlib import Path

from . import config as config_mod
from . import fat12
from .device import DeviceError
from .library import LibraryError
from .station import DoesNotFit, NoBadge, Station, StationBusy, StationError, kb

EXIT_OK, EXIT_ERROR, EXIT_PRECONDITION = 0, 1, 2


def _common() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--config", type=Path, default=argparse.SUPPRESS,
                   help="station.toml (default $BADGE_STATION_CONFIG or /etc/badge-station/station.toml)")
    p.add_argument("--fake-badge", default=argparse.SUPPRESS, metavar="PATH",
                   help="FAT12 image (loop-mounted) or directory instead of the USB badge")
    p.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                   help="machine-readable output (status, sets, library)")
    return p


def build_parser() -> argparse.ArgumentParser:
    common = _common()
    ap = argparse.ArgumentParser(prog="badge", parents=[common],
                                 description="Deploy cart sets onto a SYCL badge.")
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="COMMAND")

    def cmd(name: str, help: str) -> argparse.ArgumentParser:
        return sub.add_parser(name, help=help, parents=[common])

    cmd("status", "badge, network and sets at a glance")
    cmd("sets", "the sets and whether each fits")
    p = cmd("deploy", "wipe the badge, copy a set, eject")
    p.add_argument("set")
    p.add_argument("--yes", "-y", action="store_true", help="do not ask")
    p = cmd("wipe", "delete every file on the badge, eject")
    p.add_argument("--yes", "-y", action="store_true", help="do not ask")
    cmd("sync", "fetch UF2s from the build host into the library")
    p = cmd("log", "recent station log")
    p.add_argument("-n", type=int, default=30, help="lines (default 30)")
    p = cmd("fit", "the fit check for one set, file by file")
    p.add_argument("set")
    cmd("library", "carts and ROMs in the library")
    p = cmd("add-rom", "copy a ROM into the library")
    p.add_argument("path", type=Path)
    p.add_argument("--title")
    p.add_argument("--short", help="8.3 drive name (default derived from the title)")
    p = cmd("add-uf2", "copy a cart UF2 into the library")
    p.add_argument("path", type=Path)
    p.add_argument("--key", required=True, help="library key; the drive name is KEY.uf2")
    p.add_argument("--title")
    p.add_argument("--mode", choices=["ram", "xip"], help="expected mode (checked)")
    p = cmd("build", "build a cart from a prompt (M2)")
    p.add_argument("prompt")
    return ap


def _station(a: argparse.Namespace, stream: bool = False, poll: bool = True) -> Station:
    cfg = config_mod.load(getattr(a, "config", None))
    fake = getattr(a, "fake_badge", None)
    if fake:
        cfg.fake_badge = str(Path(fake).resolve())
    st = Station(cfg, on_log=(lambda m: print(m, flush=True)) if stream else None,
                 persist_log=stream)
    if poll:
        st.poll()
    return st


def _json(obj) -> None:
    print(json.dumps(obj, indent=2, default=str))


def _confirm(a: argparse.Namespace, question: str) -> bool:
    if getattr(a, "yes", False) or not sys.stdin.isatty():
        return True
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


def _badge_lines(b: dict) -> list[str]:
    if not b["present"]:
        return [f"Badge:   {b['note']}"]
    if not b["mounted"]:
        return [f"Badge:   {b['device']}: {b['note']}"]
    names = ", ".join(f["name"] for f in b["files"]) or "empty"
    return [f"Badge:   connected ({b['device']}), {fat12.kb_down(b['free_bytes'] or 0)} free, "
            f"{b['free_entries']} root entries free",
            f"         on it: {names}"]


def _set_lines(sets: list[dict]) -> list[str]:
    out = []
    w = max([len(s["name"]) for s in sets] + [4])
    for s in sets:
        mark = "ok " if s["fits"] else "NO "
        out.append(f"  {mark} {s['name']:<{w}}  {s['title']:<24} {kb(s['bytes']):>9}  "
                   f"{s['entries']:>2}/{s['entries_capacity']} entries")
        out += [f"       {w * ' '}  {why}" for why in s["why"]]
    return out or ["  (no sets in the library manifest)"]


def cmd_status(st: Station, a) -> int:
    s = st.status()
    if getattr(a, "json", False):
        _json(s)
        return EXIT_OK
    n = s["network"]
    lines = _badge_lines(s["badge"])
    lines.append(f"Network: {n['mode']}" + (f" '{n['ssid']}'" if n["ssid"] else "")
                 + (f", {n['address']}" if n["address"] else "")
                 + f", internet {'yes' if n['internet'] else 'no'}")
    lines.append(f"Build:   local {'yes' if s['build']['local'] else 'no'}, "
                 f"remote {s['build']['remote'] or 'none'}")
    if s["busy"]:
        lines.append(f"Busy:    {s['action']}")
    lines.append("Sets:")
    lines += _set_lines(s["sets"])
    print("\n".join(lines))
    return EXIT_OK


def cmd_sets(st: Station, a) -> int:
    sets = st.library.to_json(_badge_geom(st))["sets"]
    if getattr(a, "json", False):
        _json(sets)
    else:
        print("\n".join(_set_lines(sets)))
    return EXIT_OK


def _badge_geom(st: Station) -> fat12.Geometry | None:
    b = st._badge
    try:
        return b.geometry() if b else None
    except DeviceError:
        return None


def _print_plan(st: Station, key: str) -> bool:
    lib = st.library
    if key not in lib.sets:
        raise LibraryError(f"no set called {key!r} (try: {', '.join(lib.sets) or 'none'})")
    s = lib.sets[key]
    rep = lib.fit(key, _badge_geom(st))
    items, _ = lib._resolve(key)
    verdict = "fits" if rep.fits else "does NOT fit"
    print(f"{s.title} ({key}): {len(items)} files, {kb(rep.bytes_used)} of "
          f"{fat12.kb_down(rep.bytes_capacity)}, {rep.entries_used} of {rep.entries_capacity} "
          f"root entries: {verdict}")
    for it in items:
        print(f"  {it.name:<36} {kb(it.size):>9}  {fat12.root_entries_for(it.name)} entries")
    for why in rep.why:
        print(f"  ! {why}")
    sys.stdout.flush()
    return rep.fits


def cmd_fit(st: Station, a) -> int:
    return EXIT_OK if _print_plan(st, a.set) else EXIT_PRECONDITION


def cmd_deploy(st: Station, a) -> int:
    if not _print_plan(st, a.set):
        return EXIT_PRECONDITION
    if st._badge is None:
        print(f"cannot deploy: {st.status()['badge']['note']}", file=sys.stderr)
        return EXIT_PRECONDITION
    if not _confirm(a, f"Wipe the badge and deploy {a.set}?"):
        return EXIT_ERROR
    st.deploy(a.set)
    return EXIT_OK


def cmd_wipe(st: Station, a) -> int:
    if st._badge is None:
        print(f"cannot wipe: {st.status()['badge']['note']}", file=sys.stderr)
        return EXIT_PRECONDITION
    if not _confirm(a, "Delete every file on the badge?"):
        return EXIT_ERROR
    st.wipe()
    return EXIT_OK


def cmd_sync(st: Station, a) -> int:
    return EXIT_OK if st.sync() else EXIT_ERROR


def cmd_log(st: Station, a) -> int:
    for e in st.log_lines(a.n):
        print(f"{time.strftime('%H:%M:%S', time.localtime(e['t']))}  {e['msg']}")
    return EXIT_OK


def cmd_library(st: Station, a) -> int:
    lib = st.library.to_json()["library"]
    if getattr(a, "json", False):
        _json(lib)
        return EXIT_OK
    if lib["error"]:
        print(f"! {lib['error']}")
    print("Carts:")
    for c in lib["carts"]:
        flag = "" if c["ok"] else f"  ! {c['error']}"
        print(f"  {c['key']:<22} {c['mode']:<4} {kb(c['size']):>9}  {c['title']}{flag}")
    print("ROMs:")
    for r in lib["roms"]:
        flag = "" if r["ok"] else f"  ! {r['error']}"
        print(f"  {r['key']:<22} {r['short']:<12} {kb(r['size']):>9}  {r['file']}{flag}")
    return EXIT_OK


def cmd_add_rom(st: Station, a) -> int:
    r = st.library.add_rom(a.path, a.title, short=a.short)
    print(f"added ROM {r.key}: {r.file.name}, {kb(r.size)}, "
          f"drive name {r.short or st.library.short_name(r, set())}")
    return EXIT_OK


def cmd_add_uf2(st: Station, a) -> int:
    c = st.library.import_uf2(a.path, a.key, a.title, a.mode)
    print(f"added cart {c.key}: {c.file.name}, {c.mode.upper()}, {kb(c.size)}")
    return EXIT_OK


def cmd_build(st: Station, a) -> int:
    print("badge build is not yet available in M0", file=sys.stderr)
    return EXIT_PRECONDITION


COMMANDS = {"status": cmd_status, "sets": cmd_sets, "deploy": cmd_deploy, "wipe": cmd_wipe,
            "sync": cmd_sync, "log": cmd_log, "fit": cmd_fit, "library": cmd_library,
            "add-rom": cmd_add_rom, "add-uf2": cmd_add_uf2, "build": cmd_build}
STREAMING = {"deploy", "wipe", "sync"}
NO_BADGE = {"library", "log", "add-rom", "add-uf2"}      # never touch the drive


def main(argv: list[str] | None = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        if a.cmd == "build":
            return cmd_build(None, a)
        st = _station(a, stream=a.cmd in STREAMING, poll=a.cmd not in NO_BADGE)
        return COMMANDS[a.cmd](st, a)
    except (NoBadge, DoesNotFit, StationBusy) as e:
        print(f"badge: {e}", file=sys.stderr)
        return EXIT_PRECONDITION
    except (StationError, LibraryError, DeviceError, OSError) as e:
        print(f"badge: {e}", file=sys.stderr)
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
