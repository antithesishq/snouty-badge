"""The `badge` command: the same Station the phone page drives, from a shell.

    badge [--config PATH] [--fake-badge PATH] [--json] COMMAND ...

Exit codes: 0 ok, 1 error, 2 precondition (no badge, does not fit, busy,
not available yet).
"""
from __future__ import annotations
import argparse
import json
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import config as config_mod
from . import fat12
from .device import DeviceError
from .library import CartSet, LibraryError
from .station import (BuildNotReady, DoesNotFit, NoBadge, Station, StationBusy, StationError,
                      kb)

EXIT_OK, EXIT_ERROR, EXIT_PRECONDITION = 0, 1, 2
DEFAULT_SETS = Path(__file__).resolve().parents[1] / "sets.default.toml"


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

    def selection(p: argparse.ArgumentParser) -> None:
        p.add_argument("--carts", type=_csv, metavar="A,B", help="an ad-hoc selection instead of SET")
        p.add_argument("--roms", type=_csv, default=[], metavar="X,Y",
                       help="ROM keys or globs (*.gg) for --carts")

    cmd("status", "badge, network and sets at a glance")
    cmd("sets", "the sets and whether each fits")
    p = cmd("deploy", "wipe the badge, copy a set (or --carts/--roms), eject")
    p.add_argument("set", nargs="?")
    selection(p)
    p.add_argument("--yes", "-y", action="store_true", help="do not ask")
    p = cmd("wipe", "delete every file on the badge, eject")
    p.add_argument("--yes", "-y", action="store_true", help="do not ask")
    cmd("sync", "fetch UF2s from the build host into the library")
    p = cmd("log", "recent station log")
    p.add_argument("-n", type=int, default=30, help="lines (default 30)")
    p = cmd("fit", "the fit check for one set (or --carts/--roms), file by file")
    p.add_argument("set", nargs="?")
    selection(p)
    cmd("library", "carts and ROMs in the library (* = the variant sets deploy)")
    p = cmd("mode", "pick the RAM or XIP variant a cart deploys as: mode CART ram|xip, "
                    "mode --all ram|xip")
    p.add_argument("args", nargs="+", metavar="[CART] MODE")
    p.add_argument("--all", action="store_true", help="every cart that has the variant")
    p = cmd("set", "edit sets in the manifest: set save KEY --title T --carts a,b --roms x,y; "
                   "set rm KEY")
    ss = p.add_subparsers(dest="set_cmd", required=True, metavar="save|rm")
    q = ss.add_parser("save", help="create or replace set KEY", parents=[common])
    q.add_argument("key")
    q.add_argument("--title", help="shown on the page (default KEY)")
    q.add_argument("--carts", type=_csv, default=[], metavar="A,B")
    q.add_argument("--roms", type=_csv, default=[], metavar="X,Y", help="ROM keys or globs (*.gg)")
    q = ss.add_parser("rm", help="remove set KEY", parents=[common])
    q.add_argument("key")
    p = cmd("init-sets", "add the default sets and cart titles missing from the manifest")
    p.add_argument("--file", type=Path, default=DEFAULT_SETS,
                   help=f"defaults to merge (default {DEFAULT_SETS})")
    cmd("qr", "print QR codes for the page (and the station Wi-Fi in AP mode)")
    p = cmd("add-rom", "copy a ROM into the library")
    p.add_argument("path", type=Path)
    p.add_argument("--title")
    p.add_argument("--short", help="8.3 drive name (default derived from the title)")
    p = cmd("add-uf2", "copy a cart UF2 into the library")
    p.add_argument("path", type=Path)
    p.add_argument("--key", required=True, help="library key; the drive name is KEY.uf2")
    p.add_argument("--title")
    p.add_argument("--mode", choices=["ram", "xip"], help="expected mode (checked)")
    p.add_argument("--build", metavar="ID", help="the build job that made it")
    p = cmd("build", 'build a cart from a prompt: build "a Snouty cart where ..."; '
                     "build --status | --cancel | --log [ID]")
    p.add_argument("prompt", nargs="?", help="what the cart should be (at most 2000 characters)")
    where = p.add_mutually_exclusive_group()
    where.add_argument("--remote", dest="where", action="store_const", const="remote",
                       default="auto", help="build on the build VM (build_host)")
    where.add_argument("--local", dest="where", action="store_const", const="local",
                       help="build on this station")
    p.add_argument("--name", help="cart name (snouty- is added when missing); default from "
                                  "the prompt")
    p.add_argument("--no-agent", action="store_true", help="build the template cart only")
    what = p.add_mutually_exclusive_group()
    what.add_argument("--status", action="store_true", help="the running or last build")
    what.add_argument("--cancel", action="store_true", help="stop the running build")
    what.add_argument("--log", nargs="?", const="", metavar="ID",
                      help="the whole log of build ID (default the running or last one)")
    p = cmd("builds", "the last builds")
    p.add_argument("-n", type=int, default=10, help="how many (default 10)")
    return ap


def _csv(text: str) -> list[str]:
    return [x.strip() for x in text.split(",") if x.strip()]


def _station(a: argparse.Namespace, stream: bool = False, poll: bool = True,
             keep_log: bool = False) -> Station:
    """STREAM prints and keeps the station log lines; KEEP_LOG only keeps them."""
    cfg = config_mod.load(getattr(a, "config", None))
    fake = getattr(a, "fake_badge", None)
    if fake:
        cfg.fake_badge = str(Path(fake).resolve())
    st = Station(cfg, on_log=(lambda m: print(m, flush=True)) if stream else None,
                 persist_log=stream or keep_log)
    if poll:
        st.poll()
    return st


def _json(obj) -> None:
    print(json.dumps(obj, indent=2, default=str))


def _confirm(a: argparse.Namespace, question: str) -> bool:
    if getattr(a, "yes", False) or not sys.stdin.isatty():
        return True
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


def _badge_lines(b: dict, sets: list[dict]) -> list[str]:
    if not b["present"]:
        return [f"Badge:   {b['note']}"]
    if not b["mounted"]:
        return [f"Badge:   {b['device']}: {b['note']}"]
    return [f"Badge:   connected ({b['device']}), {fat12.kb_down(b['free_bytes'] or 0)} free, "
            f"{b['free_entries']} root entries free",
            f"         on it: {_on_it(b, sets)}"]


def _on_it(b: dict, sets: list[dict]) -> str:
    """"Demo reel (snouty.uf2, ...)" when the files are a set's plan, else the titles."""
    files = [f for f in b["files"] if not f["name"].startswith(".")]
    if not files:
        return "empty"
    titles = {s["name"]: s["title"] for s in sets}
    if b.get("set"):
        return f"{titles.get(b['set'], b['set'])} ({', '.join(f['name'] for f in files)})"
    return ", ".join(f.get("title") or f["name"] for f in files)


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
    lines = _badge_lines(s["badge"], s["sets"])
    lines.append(f"Network: {n['mode']}" + (f" '{n['ssid']}'" if n["ssid"] else "")
                 + (f", {n['address']}" if n["address"] else "")
                 + f", internet {'yes' if n['internet'] else 'no'}")
    b = s["build"]
    lines.append(f"Build:   local {'yes' if b['local'] else 'no'}, "
                 f"remote {b['remote'] or 'none'}, "
                 + (f"ready ({b['where']})" if b["ready"] else f"not ready: {b['why']}"))
    if s["job"] and s["job"]["state"] in ("queued", "running"):
        lines.append(f"         building {s['job']['name']}, {s['job']['seconds']:.0f} s")
    if s["share"]["url"]:
        lines.append(f"Share:   {s['share']['url']}" + (
            f", Wi-Fi '{s['share']['ssid']}'" if s["share"]["ssid"] else ""))
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


def _target(st: Station, a) -> CartSet:
    """The set named on the command line, or the --carts/--roms selection."""
    lib = st.library
    if a.carts is not None:
        if a.set:
            raise LibraryError("give a SET or --carts, not both")
        return lib.selection(a.carts, a.roms)
    if a.roms:
        raise LibraryError("--roms needs --carts (use --carts '' for ROMs only)")
    if not a.set:
        raise LibraryError(f"give a SET ({', '.join(lib.sets) or 'none'}) or --carts")
    if a.set not in lib.sets:
        raise LibraryError(f"no set called {a.set!r} (try: {', '.join(lib.sets) or 'none'})")
    return lib.sets[a.set]


def _print_plan(st: Station, s: CartSet) -> bool:
    lib = st.library
    rep = lib.fit(s, _badge_geom(st))
    items, _ = lib._resolve(s)
    verdict = "fits" if rep.fits else "does NOT fit"
    print(f"{s.title} ({s.key}): {len(items)} files, {kb(rep.bytes_used)} of "
          f"{fat12.kb_down(rep.bytes_capacity)}, {rep.entries_used} of {rep.entries_capacity} "
          f"root entries: {verdict}")
    for it in items:
        print(f"  {it.name:<36} {kb(it.size):>9}  {fat12.root_entries_for(it.name)} entries")
    for why in rep.why:
        print(f"  ! {why}")
    sys.stdout.flush()
    return rep.fits


def cmd_fit(st: Station, a) -> int:
    return EXIT_OK if _print_plan(st, _target(st, a)) else EXIT_PRECONDITION


def cmd_deploy(st: Station, a) -> int:
    s = _target(st, a)
    if not _print_plan(st, s):
        return EXIT_PRECONDITION
    if st._badge is None:
        print(f"cannot deploy: {st.status()['badge']['note']}", file=sys.stderr)
        return EXIT_PRECONDITION
    if not _confirm(a, f"Wipe the badge and deploy {s.title}?"):
        return EXIT_ERROR
    st.deploy(s if a.carts is not None else s.key)
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
        modes = "  ".join(f"{m}{'*' if m == c['use'] else ' '}" if m in c["variants"] else "    "
                          for m in ("ram", "xip"))
        print(f"  {c['key']:<22} {modes} {kb(c['size']):>9}  {c['title']}{flag}")
    print("ROMs:")
    for r in lib["roms"]:
        flag = "" if r["ok"] else f"  ! {r['error']}"
        print(f"  {r['key']:<22} {r['short']:<12} {kb(r['size']):>9}  {r['file']}{flag}")
    return EXIT_OK


def cmd_add_rom(st: Station, a) -> int:
    r = st.library.add_rom(a.path, a.title, short=a.short)
    print(f"added ROM {r.key}: {r.file.name}, {kb(r.size)}, "
          f"drive name {st.library.drive_name(r)}")
    return EXIT_OK


def cmd_add_uf2(st: Station, a) -> int:
    c = st.library.import_uf2(a.path, a.key, a.title, a.mode, a.build)
    print(f"added cart {c.key}: {c.file.name}, {c.mode.upper()}, {kb(c.size)}")
    return EXIT_OK


def cmd_mode(st: Station, a) -> int:
    args = a.args
    if len(args) != (1 if a.all else 2) or args[-1] not in ("ram", "xip"):
        print("usage: badge mode CART ram|xip, or badge mode --all ram|xip", file=sys.stderr)
        return EXIT_ERROR
    mode = args[-1]
    if not a.all:
        st.set_cart_mode(args[0], mode)
        return EXIT_OK
    for c in list(st.library.carts.values()):
        if mode not in c.variants:
            print(f"{c.key}: no {mode.upper()} variant, left as {c.use.upper()}")
        elif c.use != mode:
            st.set_cart_mode(c.key, mode)
    return EXIT_OK


def cmd_set(st: Station, a) -> int:
    if a.set_cmd == "rm":
        st.delete_set(a.key)
    else:
        st.save_set(a.title or a.key, a.carts, a.roms, a.key)
    return EXIT_OK


def cmd_init_sets(st: Station, a) -> int:
    added = st.library.init_defaults(a.file)
    print(f"added {', '.join(added)}" if added else f"nothing to add from {a.file}")
    return EXIT_OK


def cmd_qr(st: Station, a) -> int:
    if not shutil.which("qrencode"):
        print("badge qr needs qrencode (sudo apt install qrencode)", file=sys.stderr)
        return EXIT_PRECONDITION
    sh = st.share()
    if not sh["url"]:
        print("no address to share: the station has no network", file=sys.stderr)
        return EXIT_PRECONDITION
    codes = [(f"The page: {sh['url']}", sh["url"])]
    if sh["ssid"]:
        codes.append((f"Wi-Fi '{sh['ssid']}', password {sh['password']}",
                      f"WIFI:T:WPA;S:{_wifi_escape(sh['ssid'])};P:{_wifi_escape(sh['password'])};;"))
    for label, text in codes:
        print(label, flush=True)
        subprocess.run(["qrencode", "-t", "UTF8", text], check=True)
    return EXIT_OK


def _wifi_escape(text: str) -> str:
    return "".join("\\" + ch if ch in '\\;,:"' else ch for ch in text)


def cmd_build(st: Station, a) -> int:
    if a.status:
        return _build_status(st, a)
    if a.cancel:
        if not st.cancel_build():
            print("no build is running", file=sys.stderr)
            return EXIT_PRECONDITION
        print("cancelled")
        return EXIT_OK
    if a.log is not None:
        return _build_log(st, a.log or None)
    if not a.prompt:
        print('usage: badge build "PROMPT" [--remote|--local] [--name NAME] [--no-agent]',
              file=sys.stderr)
        return EXIT_ERROR
    return _build_run(st, a)


def _build_run(st: Station, a) -> int:
    """Start a build and stream its log; Ctrl-C (or a dropped ssh) cancels it."""
    job_id = st.start_build(a.prompt, a.where, a.name, a.no_agent,
                            on_line=lambda line: print(line, flush=True))
    old = {s: signal.signal(s, _interrupt) for s in (signal.SIGTERM, signal.SIGHUP)}
    try:
        while not st.wait_build(0.2):
            pass
    except KeyboardInterrupt:
        print("cancelling the build", file=sys.stderr, flush=True)
        st.cancel_build()
        st.wait_build(30)
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    job = st.build_job(job_id) or {}
    if job.get("state") != "done":
        return EXIT_ERROR
    r = job["result"]
    print(f"{job['title']} is in the library as {r['cart']} (build {job_id})")
    return EXIT_OK


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def _build_lines(job: dict) -> list[str]:
    lines = [f"Build:   {job['id']} ({job['state']}, {job['seconds']:.0f} s, "
             f"{'on the build VM' if job['where'] == 'remote' else 'on the station'})",
             f"Prompt:  {job['prompt']}"]
    r = job.get("result")
    if r:
        ms = f", {r['bench_ms']:g} ms" if r.get("bench_ms") is not None else ""
        lines.append(f"Cart:    {r['cart']}, {job['title']}, {kb(r['size'])}{ms}")
    if job.get("error"):
        lines.append(f"Error:   {job['error']}")
    return lines


def _build_status(st: Station, a) -> int:
    job = st.build_job()
    if getattr(a, "json", False):
        _json({"build": st.build_info(), "job": job})
        return EXIT_OK
    info = st.build_info()
    print(f"Builds:  {'ready, ' + info['where'] if info['ready'] else 'not ready: ' + info['why']}")
    if job is None:
        print("no builds yet")
        return EXIT_OK
    print("\n".join(_build_lines(job)))
    print("\n".join("  " + line for line in job["log"][-10:]))
    return EXIT_OK


def _build_log(st: Station, job_id: str | None) -> int:
    job = st.build_job(job_id)
    if job is None:
        print(f"no build {job_id}" if job_id else "no builds yet", file=sys.stderr)
        return EXIT_ERROR
    print("\n".join(job["log"]))
    return EXIT_OK


def cmd_builds(st: Station, a) -> int:
    rows = st.builds(max(1, a.n))
    if getattr(a, "json", False):
        _json(rows)
        return EXIT_OK
    if not rows:
        print("no builds yet")
    for r in rows:
        what = r.get("title") or r.get("name") or ""
        if r.get("error"):
            what += f"  ! {r['error']}"
        print(f"  {r['id']:<34} {r['state']:<9} {r['seconds']:>5.0f} s  {what}")
    return EXIT_OK


COMMANDS = {"status": cmd_status, "sets": cmd_sets, "deploy": cmd_deploy, "wipe": cmd_wipe,
            "sync": cmd_sync, "log": cmd_log, "fit": cmd_fit, "library": cmd_library,
            "add-rom": cmd_add_rom, "add-uf2": cmd_add_uf2, "mode": cmd_mode, "set": cmd_set,
            "init-sets": cmd_init_sets, "qr": cmd_qr, "build": cmd_build,
            "builds": cmd_builds}
STREAMING = {"deploy", "wipe", "sync", "mode", "set"}    # log lines printed and kept
NO_BADGE = {"library", "log", "add-rom", "add-uf2", "mode", "set", "init-sets",
            "qr", "build", "builds"}                     # never touch the drive
KEEP_LOG = {"build"}                                     # log lines kept, not printed


def main(argv: list[str] | None = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        st = _station(a, stream=a.cmd in STREAMING, poll=a.cmd not in NO_BADGE,
                      keep_log=a.cmd in KEEP_LOG)
        return COMMANDS[a.cmd](st, a)
    except (NoBadge, DoesNotFit, StationBusy, BuildNotReady) as e:
        print(f"badge: {e}", file=sys.stderr)
        return EXIT_PRECONDITION
    except (StationError, LibraryError, DeviceError, OSError) as e:
        print(f"badge: {e}", file=sys.stderr)
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
