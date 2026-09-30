"""The station's collection: library/manifest.toml, library/carts/*.uf2, library/roms/*.

manifest.toml:
  [carts.snouty]            # key = drive file stem; file defaults to carts/<key>.uf2
  title = "Snouty Run"
  mode = "ram"              # or "xip"; informational + validated with uf2 block addresses
  roms = []                 # extensions this cart reads from the drive, e.g. [".gg", ".sms"]

  [roms.sonic]
  file = "roms/Sonic The Hedgehog (World).gg"
  title = "Sonic GG"
  short = "SONIC.GG"        # optional; else fat12.short_name_for

  [sets.demo]
  title = "Demo reel"
  carts = ["snouty", "snouty-bugs", "snoutenstein", "snouty-maze"]
  roms = []

UF2s in carts/ and files in roms/ that the manifest does not name are added
as automatic entries (title = file stem, mode from the UF2 blocks), so a
fresh `sync` shows up without editing the manifest.
"""
from __future__ import annotations
import re
import shutil
import struct
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import fat12
from .fat12 import FitReport

# tools/uf2_info.py
UF2_MAGIC0, UF2_MAGIC1, UF2_MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
UF2_FLASH = (0x101C0000, 0x10200000)
UF2_RAM = (0x20020000, 0x20080000)


class LibraryError(Exception):
    pass


class UF2Error(LibraryError):
    pass


@dataclass
class Cart:
    key: str
    title: str
    file: Path
    mode: str = "ram"
    roms: list[str] = field(default_factory=list)
    size: int = 0
    error: str = ""          # why this cart cannot be deployed ("" = fine)
    auto: bool = False       # found in carts/, not named in the manifest


@dataclass
class Rom:
    key: str
    title: str
    file: Path
    short: str = ""
    size: int = 0
    error: str = ""
    auto: bool = False


@dataclass
class CartSet:
    key: str
    title: str
    carts: list[str]
    roms: list[str]


@dataclass
class PlanItem:
    src: Path
    name: str            # name on the drive
    size: int


def validate_uf2(path: Path) -> str:
    """"ram" | "xip" from the UF2 block addresses; raises UF2Error on mixed/malformed."""
    try:
        data = Path(path).read_bytes()
    except OSError as e:
        raise UF2Error(f"{Path(path).name}: {e.strerror or e}") from e
    name = Path(path).name
    if not data or len(data) % 512:
        raise UF2Error(f"{name}: size {len(data)} is not a multiple of 512")
    in_flash = in_ram = True
    any_flash = any_ram = False
    for i in range(0, len(data), 512):
        m0, m1, _flags, addr, size = struct.unpack_from("<5I", data, i)
        end = struct.unpack_from("<I", data, i + 508)[0]
        if (m0, m1, end) != (UF2_MAGIC0, UF2_MAGIC1, UF2_MAGIC_END):
            raise UF2Error(f"{name}: block {i // 512} has bad magic")
        in_flash &= UF2_FLASH[0] <= addr and addr + size <= UF2_FLASH[1]
        in_ram &= UF2_RAM[0] <= addr and addr + size <= UF2_RAM[1]
        any_flash |= UF2_FLASH[0] <= addr < UF2_FLASH[1]
        any_ram |= UF2_RAM[0] <= addr < UF2_RAM[1]
    if in_flash:
        return "xip"
    if in_ram:
        return "ram"
    if any_flash and any_ram:
        raise UF2Error(f"{name}: mixed flash and RAM blocks, the loader rejects it")
    raise UF2Error(f"{name}: blocks outside both cart windows")


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "item"


def _toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    s = str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{s}"'


def _toml_key(k: str) -> str:
    return k if re.fullmatch(r"[A-Za-z0-9_-]+", k) else _toml_value(k)


def dump_toml(data: dict, prefix: str = "") -> str:
    """Enough TOML for the manifest: scalars, lists of scalars, nested tables."""
    lines = [f"{_toml_key(k)} = {_toml_value(v)}" for k, v in data.items()
             if not isinstance(v, dict)]
    out = "\n".join(lines) + ("\n" if lines else "")
    for k, v in data.items():
        if isinstance(v, dict):
            name = f"{prefix}.{_toml_key(k)}" if prefix else _toml_key(k)
            has_scalars = any(not isinstance(x, dict) for x in v.values())
            body = dump_toml(v, name)
            out += (f"\n[{name}]\n" if has_scalars or not v else "") + body
    return out


class Library:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.carts: dict[str, Cart] = {}
        self.roms: dict[str, Rom] = {}
        self.sets: dict[str, CartSet] = {}
        self.error = ""          # manifest parse problem, shown on the page
        self._raw: dict = {}
        self.reload()

    @property
    def manifest(self) -> Path:
        return self.root / "manifest.toml"

    def reload(self) -> None:
        """Re-read manifest and file sizes (new dicts swapped in at the end)."""
        error = ""
        try:
            raw = tomllib.loads(self.manifest.read_text()) if self.manifest.exists() else {}
        except (tomllib.TOMLDecodeError, OSError) as e:
            error, raw = f"manifest.toml: {e}", {}
        self._raw = raw
        carts = {k: self._cart(k, v) for k, v in self._tables("carts").items()}
        roms = {k: self._rom(k, v) for k, v in self._tables("roms").items()}
        sets = {k: CartSet(k, str(v.get("title", k)), list(v.get("carts", [])),
                           list(v.get("roms", [])))
                for k, v in self._tables("sets").items()}
        self._discover(carts, roms)
        self.carts, self.roms, self.sets, self.error = carts, roms, sets, error

    def _tables(self, name: str) -> dict[str, dict]:
        t = self._raw.get(name, {})
        return {k: v for k, v in t.items() if isinstance(v, dict)} if isinstance(t, dict) else {}

    def _path(self, rel: str) -> Path:
        p = Path(rel)
        return p if p.is_absolute() else self.root / p

    def _cart(self, key: str, t: dict, auto: bool = False) -> Cart:
        c = Cart(key, str(t.get("title", key)), self._path(t.get("file", f"carts/{key}.uf2")),
                 str(t.get("mode", "ram")), list(t.get("roms", [])), auto=auto)
        try:
            c.size = c.file.stat().st_size
        except OSError:
            c.error = f"{c.file.name} is missing from the library"
            return c
        try:
            kind = validate_uf2(c.file)
        except UF2Error as e:
            c.error = str(e)
            return c
        if auto or "mode" not in t:
            c.mode = kind
        elif kind != c.mode:
            c.error = f"{c.file.name} is a {kind.upper()} cart, the manifest says {c.mode.upper()}"
        return c

    def _rom(self, key: str, t: dict, auto: bool = False) -> Rom:
        f = self._path(t.get("file", f"roms/{key}"))
        r = Rom(key, str(t.get("title", f.stem)), f, str(t.get("short", "")), auto=auto)
        try:
            r.size = f.stat().st_size
        except OSError:
            r.error = f"{f.name} is missing from the library"
        return r

    def _discover(self, carts: dict[str, Cart], roms: dict[str, Rom]) -> None:
        known = {c.file.resolve() for c in carts.values()}
        for p in sorted((self.root / "carts").glob("*.uf2")):
            if p.resolve() not in known and p.stem not in carts:
                carts[p.stem] = self._cart(p.stem, {"file": str(p)}, auto=True)
        known = {r.file.resolve() for r in roms.values()}
        for p in sorted((self.root / "roms").glob("*")):
            if p.is_file() and not p.name.startswith(".") and p.resolve() not in known:
                key = self._free_key(slug(p.stem), roms)
                roms[key] = self._rom(key, {"file": str(p)}, auto=True)

    @staticmethod
    def _free_key(key: str, taken: dict) -> str:
        n, k = 2, key
        while k in taken:
            k, n = f"{key}-{n}", n + 1
        return k

    # -- plans and fit --------------------------------------------------

    def _resolve(self, set_key: str) -> tuple[list[PlanItem], list[str]]:
        if set_key not in self.sets:
            raise LibraryError(f"no set called {set_key!r}")
        s = self.sets[set_key]
        items: list[PlanItem] = []
        problems: list[str] = []
        for k in s.carts:
            c = self.carts.get(k)
            if c is None:
                problems.append(f"cart {k!r} is not in the library")
            elif c.error:
                problems.append(c.error)
            else:
                items.append(PlanItem(c.file, c.file.name, c.size))
        taken = {i.name for i in items} | {r.short for k in s.roms
                                           if (r := self.roms.get(k)) and r.short}
        for k in s.roms:
            r = self.roms.get(k)
            if r is None:
                problems.append(f"ROM {k!r} is not in the library")
                continue
            if r.error:
                problems.append(r.error)
                continue
            name = r.short or self.short_name(r, taken)
            taken.add(name)
            items.append(PlanItem(r.file, name, r.size))
        return items, problems

    @staticmethod
    def short_name(rom: Rom, taken: set[str]) -> str:
        """8.3 drive name from the title (or file name) plus the file's extension."""
        return fat12.short_name_for((rom.title or rom.file.stem) + rom.file.suffix, taken)

    def plan(self, set_key: str) -> list[PlanItem]:
        """UF2s first, then ROMs. Raises LibraryError when something is missing."""
        items, problems = self._resolve(set_key)
        if problems:
            raise LibraryError("; ".join(problems))
        return items

    def fit(self, set_key: str, geom: fat12.Geometry | None = None) -> FitReport:
        items, problems = self._resolve(set_key)
        rep = fat12.fit([(i.name, i.size) for i in items], geom=geom)
        rep.why[:0] = problems
        return rep

    def validate_uf2(self, path: Path) -> str:
        """"ram" | "xip", raises on mixed/malformed (tools/uf2_info.py logic)."""
        return validate_uf2(path)

    # -- adding things --------------------------------------------------

    def add_rom(self, path: Path, title: str | None = None, key: str | None = None,
                short: str | None = None) -> Rom:
        """Copy PATH into roms/ and name it in the manifest. Returns the new Rom."""
        path = Path(path)
        dst = self.root / "roms" / path.name
        dst.parent.mkdir(parents=True, exist_ok=True)
        if path.resolve() != dst.resolve():
            shutil.copyfile(path, dst)
        existing = [k for k, r in self.roms.items() if r.file.resolve() == dst.resolve()
                    and not r.auto]
        key = key or (existing[0] if existing else
                      self._free_key(slug(title or path.stem), self._tables("roms")))
        t = dict(self._tables("roms").get(key, {}))
        t["file"] = f"roms/{dst.name}"
        t["title"] = title or t.get("title") or path.stem
        if short:
            t["short"] = short
        self._set_table("roms", key, t)
        return self.roms[key]

    def import_uf2(self, path: Path, key: str, title: str | None = None,
                   mode: str | None = None) -> Cart:
        """Validate PATH, copy it to carts/<key>.uf2 and name it in the manifest."""
        path = Path(path)
        kind = validate_uf2(path)
        if mode and mode != kind:
            raise UF2Error(f"{path.name} is a {kind.upper()} cart, not {mode.upper()}")
        dst = self.root / "carts" / f"{key}.uf2"
        dst.parent.mkdir(parents=True, exist_ok=True)
        if path.resolve() != dst.resolve():
            shutil.copyfile(path, dst)
        t = dict(self._tables("carts").get(key, {}))
        t.pop("file", None)
        t["title"] = title or t.get("title") or key
        t["mode"] = kind
        t.setdefault("roms", [])
        self._set_table("carts", key, t)
        return self.carts[key]

    def _set_table(self, section: str, key: str, table: dict) -> None:
        raw = dict(self._raw)
        sec = dict(raw.get(section, {}))
        sec[key] = table
        raw[section] = sec
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.manifest.with_suffix(".toml.tmp")
        tmp.write_text("# badge station library (rewritten by badge_manager)\n" + dump_toml(raw))
        tmp.replace(self.manifest)
        self.reload()

    # -- JSON -----------------------------------------------------------

    def to_json(self, geom: fat12.Geometry | None = None) -> dict:
        """The "sets"/"library" parts of Station.status()."""
        sets = []
        for k, s in self.sets.items():
            items, _ = self._resolve(k)
            rep = self.fit(k, geom)
            sets.append({"name": k, "title": s.title, "bytes": rep.bytes_used,
                         "entries": rep.entries_used, "fits": rep.fits, "why": rep.why,
                         "bytes_capacity": rep.bytes_capacity,
                         "entries_capacity": rep.entries_capacity,
                         "carts": list(s.carts), "roms": list(s.roms),
                         "files": [i.name for i in items]})
        carts = [{"key": c.key, "title": c.title, "file": c.file.name, "mode": c.mode,
                  "size": c.size, "roms": c.roms, "ok": not c.error, "error": c.error,
                  "auto": c.auto} for c in self.carts.values()]
        roms = [{"key": r.key, "title": r.title, "file": r.file.name,
                 "short": r.short or self.short_name(r, set()), "size": r.size,
                 "ok": not r.error, "error": r.error, "auto": r.auto}
                for r in self.roms.values()]
        return {"sets": sets, "library": {"carts": carts, "roms": roms, "error": self.error}}
