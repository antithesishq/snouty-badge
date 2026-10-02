"""The station's collection: library/manifest.toml, library/carts/*.uf2, library/roms/*.

manifest.toml:
  [carts.snouty]            # key = cart family: carts/<key>.uf2 (RAM), carts/<key>-xip.uf2 (XIP)
  title = "Snouty Run"
  use = "xip"               # the variant sets deploy (default "ram", or the only one there is)
  file = "carts/x.uf2"      # optional: the RAM variant; xip_file likewise for XIP
  roms = []                 # extensions this cart reads from the drive, e.g. [".gg", ".sms"]
  build = "20260930-141500-rain"   # optional: the build job that made it (builds/<id>/)
  # mode = "ram"|"xip" (M0): checked against the blocks; "xip" makes `file` the XIP variant

  [roms.sonic]
  file = "roms/Sonic The Hedgehog (World).gg"
  title = "Sonic GG"
  short = "SONIC.GG"        # optional; else fat12.short_name_for

  [sets.demo]
  title = "Demo reel"
  carts = ["snouty", "snouty-bugs", "snoutenstein", "snouty-maze"]
  roms = ["sonic", "*.gg"]  # ROM keys, or case-insensitive globs over ROM file names
                            # (anything with * ? [ or a leading "." as in ".gg" = "*.gg")

UF2s in carts/ and files in roms/ that the manifest does not name are added
as automatic entries (title = family key, `<stem>-xip.uf2` folded into the
family `<stem>`), so a fresh `sync` shows up without editing the manifest.
"""
from __future__ import annotations
import fnmatch
import contextlib
import fcntl
import os
import re
import shutil
import stat
import struct
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import fat12
from .device import JUNK_HINT
from .fat12 import FitReport

# tools/uf2_info.py
UF2_MAGIC0, UF2_MAGIC1, UF2_MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
UF2_FLASH = (0x101C0000, 0x10200000)
UF2_RAM = (0x20020000, 0x20080000)
UF2_FAMILIES = {0xE48BFF59, 0xE48BFF5A, 0xE48BFF5B}
VARIANTS = ("ram", "xip")
CUSTOM = "custom"            # key of an ad-hoc selection (Library.selection)
BUILD_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[a-z0-9][a-z0-9-]*")   # build.py job ids


class LibraryError(Exception):
    pass


class UF2Error(LibraryError):
    pass


@dataclass
class Variant:
    file: Path
    size: int = 0
    mode: str = "ram"        # the slot: "ram" or "xip"
    error: str = ""


@dataclass
class Cart:
    key: str
    title: str
    file: Path               # file, mode, size, error: of the variant in use
    mode: str = "ram"
    roms: list[str] = field(default_factory=list)
    size: int = 0
    error: str = ""          # why this cart cannot be deployed ("" = fine)
    auto: bool = False       # found in carts/, not named in the manifest
    use: str = "ram"
    variants: dict[str, Variant] = field(default_factory=dict)
    build: str | None = None  # id of the build job that made it (builds/<id>/)


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
    title: str = ""
    kind: str = ""       # "cart" | "rom"


def validate_uf2(path: Path) -> str:
    """"ram" | "xip" from the UF2 block addresses; raises UF2Error on mixed/malformed."""
    try:
        with os.fdopen(_open_regular_nofollow(Path(path)), "rb") as stream:
            data = stream.read()
    except OSError as e:
        raise UF2Error(f"{Path(path).name}: {e.strerror or e}") from e
    name = Path(path).name
    if not data or len(data) % 512:
        raise UF2Error(f"{name}: size {len(data)} is not a multiple of 512")
    in_flash = in_ram = True
    any_flash = any_ram = False
    expected = len(data) // 512
    seen = set()
    for i in range(0, len(data), 512):
        m0, m1, flags, addr, size, number, count, family = struct.unpack_from("<8I", data, i)
        end = struct.unpack_from("<I", data, i + 508)[0]
        if (m0, m1, end) != (UF2_MAGIC0, UF2_MAGIC1, UF2_MAGIC_END):
            raise UF2Error(f"{name}: block {i // 512} has bad magic")
        if not 0 < size <= 476 or addr + size > 0x100000000:
            raise UF2Error(f"{name}: block {i // 512} has invalid payload size {size}")
        if count != expected or number >= count or number in seen:
            raise UF2Error(f"{name}: invalid block count or number at block {i // 512}")
        seen.add(number)
        if flags & 0x2000 and family not in UF2_FAMILIES:
            raise UF2Error(f"{name}: unsupported UF2 family {family:#x}")
        in_flash &= UF2_FLASH[0] <= addr and addr + size < UF2_FLASH[1]
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


def is_pattern(entry: str) -> bool:
    """A set's ROM entry that is a glob ("*.gg", "Sonic*", ".gg") rather than a key."""
    return entry.startswith(".") or any(ch in entry for ch in "*?[")


def family_of(stem: str) -> tuple[str, str]:
    """UF2 stem -> (family key, slot): "snouty-xip" -> ("snouty", "xip")."""
    if stem.endswith("-xip") and len(stem) > 4:
        return stem[:-4], "xip"
    return stem, "ram"


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "item"


def _toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    s = str(v).replace("\\", "\\\\").replace('"', '\\"')
    s = ''.join({'\b': '\\b', '\t': '\\t', '\n': '\\n', '\f': '\\f', '\r': '\\r'}.get(ch, ch)
                for ch in s)
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in s):
        raise LibraryError("text contains an unsupported control character")
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


def _open_regular_nofollow(path: Path) -> int:
    """Open a source without following a symlink in any path component."""
    path = Path(os.path.abspath(path))
    parts = path.parts[1:]
    parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise LibraryError(f"{path.name}: source is not a regular file")
        return fd
    finally:
        os.close(parent)


class Library:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.carts: dict[str, Cart] = {}
        self.roms: dict[str, Rom] = {}
        self.sets: dict[str, CartSet] = {}
        self.error = ""          # manifest parse problem, shown on the page
        self._raw: dict = {}
        self._drive: dict[str, str] = {}    # ROM key -> its 8.3 drive name
        self.reload()

    @property
    def manifest(self) -> Path:
        return self.root / "manifest.toml"

    @contextlib.contextmanager
    def locked(self):
        """Process-wide library boundary; readers may hold it through staging."""
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / ".manifest.lock").open("a+b") as lock:
            os.fchmod(lock.fileno(), 0o664)
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    @staticmethod
    def _validate_raw(raw: dict) -> None:
        if not isinstance(raw, dict):
            raise LibraryError("root must be a table")
        for section in ("carts", "roms", "sets"):
            value = raw.get(section, {})
            if not isinstance(value, dict) or any(not isinstance(v, dict) for v in value.values()):
                raise LibraryError(f"{section} must contain tables")

    def _fresh_raw(self) -> dict:
        try:
            raw = tomllib.loads(self.manifest.read_text()) if self.manifest.exists() else {}
            self._validate_raw(raw)
            return raw
        except (OSError, tomllib.TOMLDecodeError, LibraryError) as e:
            raise LibraryError(f"cannot edit invalid manifest.toml; repair it first: {e}") from e

    def _commit(self, raw: dict) -> None:
        candidate = "# badge station library (rewritten by badge_manager)\n" + dump_toml(raw)
        try:
            parsed = tomllib.loads(candidate)
            self._validate_raw(parsed)
            if parsed != raw:
                raise LibraryError("manifest did not round-trip")
        except tomllib.TOMLDecodeError as e:
            raise LibraryError(f"candidate manifest is invalid: {e}") from e
        fd, name = tempfile.mkstemp(prefix=".manifest.", suffix=".tmp", dir=self.root)
        try:
            previous = self.manifest.stat() if self.manifest.exists() else None
            os.fchmod(fd, stat.S_IMODE(previous.st_mode) if previous else 0o664)
            if os.geteuid() == 0:
                os.fchown(fd, previous.st_uid if previous else os.geteuid(),
                           previous.st_gid if previous else self.root.stat().st_gid)
            with os.fdopen(fd, "w") as stream:
                stream.write(candidate)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.manifest)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        self.reload()

    def _mutate(self, change):
        with self.locked():
            raw = self._fresh_raw()
            self.reload()
            result = change(raw)
            self._commit(raw)
            return result

    def reload(self) -> None:
        """Re-read manifest and file sizes (new dicts swapped in at the end)."""
        error = ""
        try:
            raw = tomllib.loads(self.manifest.read_text()) if self.manifest.exists() else {}
        except (tomllib.TOMLDecodeError, OSError, LibraryError) as e:
            error, raw = f"manifest.toml: {e}", {}
        if not error:
            try:
                self._validate_raw(raw)
            except LibraryError as e:
                error, raw = f"manifest.toml: {e}", {}
        self._raw = raw
        carts = {k: self._cart(k, v) for k, v in self._tables("carts").items()}
        roms = {k: self._rom(k, v) for k, v in self._tables("roms").items()}
        sets = {k: CartSet(k, str(v.get("title", k)), list(v.get("carts", [])),
                           list(v.get("roms", [])))
                for k, v in self._tables("sets").items()}
        self._discover(carts, roms)
        self.carts, self.roms, self.sets, self.error = carts, roms, sets, error
        self._drive = self._drive_names()

    def _drive_names(self) -> dict[str, str]:
        """One drive name per ROM, library-wide (manifest order, explicit `short`s reserved),
        so a ROM has the same name in every set and on the page."""
        taken = {r.short.upper() for r in self.roms.values() if r.short}
        out = {}
        for k, r in self.roms.items():
            out[k] = r.short or self.short_name(r, taken)
            taken.add(out[k].upper())
        return out

    def drive_name(self, rom: Rom) -> str:
        """ROM's name on the badge drive."""
        return self._drive.get(rom.key) or rom.short or self.short_name(rom, set())

    def _tables(self, name: str) -> dict[str, dict]:
        t = self._raw.get(name, {})
        return {k: v for k, v in t.items() if isinstance(v, dict)} if isinstance(t, dict) else {}

    def _path(self, rel: str) -> Path:
        p = Path(rel)
        return p if p.is_absolute() else self.root / p

    def _cart(self, key: str, t: dict, auto: bool = False,
              paths: dict[str, tuple[str, bool]] | None = None) -> Cart:
        """Cart family KEY from manifest table T; PATHS = {slot: (file, named)} overrides."""
        pinned = str(t.get("mode", ""))
        if paths is None:
            if pinned == "xip":
                paths = {"xip": (t.get("xip_file") or t.get("file") or f"carts/{key}.uf2",
                                 "file" in t or "xip_file" in t)}
            else:
                paths = {"ram": (t.get("file", f"carts/{key}.uf2"), "file" in t),
                         "xip": (t.get("xip_file", f"carts/{key}-xip.uf2"), "xip_file" in t)}
        variants: dict[str, Variant] = {}
        kinds: dict[str, str | None] = {}
        for slot, (rel, named) in paths.items():
            f = self._path(rel)
            if named or f.exists():
                variants[slot], kinds[slot] = self._variant(f, slot, pinned == slot)
        if "ram" in variants and kinds["ram"] == "xip" and "xip" not in variants and not pinned:
            v = variants.pop("ram")                   # an XIP UF2 without the -xip name
            variants["xip"] = Variant(v.file, v.size, "xip")
        if not auto and pinned != "xip" and not t.get("use") and "ram" not in variants:
            f = self._path(paths["ram"][0])
            variants["ram"] = Variant(f, 0, "ram", f"{f.name} is missing from the library")
        if not variants:
            slot = "xip" if pinned == "xip" else "ram"
            f = self._path(paths[slot][0])
            variants[slot] = Variant(f, 0, slot, f"{f.name} is missing from the library")
        use = str(t.get("use", ""))
        if not use:
            use = "ram" if "ram" in variants else next(iter(variants))
        v = variants.get(use)
        c = Cart(key, str(t.get("title", key)), (v or next(iter(variants.values()))).file,
                 use, list(t.get("roms", [])), auto=auto, use=use, variants=variants,
                 build=str(t["build"]) if t.get("build") else None)
        if v is None:
            c.error = (f"{c.title} has no {use.upper()} variant in the library" if use in VARIANTS
                       else f"{key}: use = {use!r}, expected \"ram\" or \"xip\"")
        else:
            c.size, c.error = v.size, v.error
        return c

    @staticmethod
    def _variant(f: Path, slot: str, pinned: bool) -> tuple[Variant, str | None]:
        """The variant in SLOT and the UF2's detected kind (None when unreadable)."""
        v = Variant(f, mode=slot)
        try:
            v.size = f.stat().st_size
        except OSError:
            v.error = f"{f.name} is missing from the library"
            return v, None
        try:
            kind = validate_uf2(f)
        except UF2Error as e:
            v.error = str(e)
            return v, None
        if kind != slot:
            v.error = (f"{f.name} is a {kind.upper()} cart, the manifest says {slot.upper()}"
                       if pinned else f"{f.name} is a {kind.upper()} cart, not {slot.upper()}")
        return v, kind

    def _rom(self, key: str, t: dict, auto: bool = False) -> Rom:
        f = self._path(t.get("file", f"roms/{key}"))
        r = Rom(key, str(t.get("title", f.stem)), f, str(t.get("short", "")), auto=auto)
        try:
            r.size = f.stat().st_size
        except OSError:
            r.error = f"{f.name} is missing from the library"
        if r.short:
            try:
                fat12.validate_filename(r.short)
            except ValueError as e:
                r.error = f"{key}: invalid ROM destination {r.short!r}: {e}"
        return r

    def _discover(self, carts: dict[str, Cart], roms: dict[str, Rom]) -> None:
        known = {v.file.resolve() for c in carts.values() for v in c.variants.values()}
        found: dict[str, dict[str, tuple[str, bool]]] = {}
        for p in sorted((self.root / "carts").glob("*.uf2")):
            if p.resolve() in known:
                continue
            fam, slot = family_of(p.stem)
            if fam in carts or slot in found.get(fam, {}):
                fam, slot = p.stem, "ram"             # the family names other files
                if fam in carts:
                    continue
            found.setdefault(fam, {})[slot] = (str(p), True)
        for fam, paths in found.items():
            carts[fam] = self._cart(fam, {}, auto=True, paths=paths)
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

    def _set(self, target: str | CartSet) -> CartSet:
        if isinstance(target, CartSet):
            return target
        if target not in self.sets:
            raise LibraryError(f"no set called {target!r}")
        return self.sets[target]

    def _rom_keys(self, entries: list[str]) -> list[str]:
        """ROM keys and patterns -> keys: patterns expand in library order, no duplicates."""
        order = sorted(self.roms.values(), key=lambda r: (r.title.lower(), r.key))
        out: list[str] = []
        for e in entries:
            if not is_pattern(e):
                keys = [e]
            else:
                pat = ("*" + e if e.startswith(".") else e).lower()
                keys = [r.key for r in order if fnmatch.fnmatchcase(r.file.name.lower(), pat)]
            out += [k for k in keys if k not in out]
        return out

    def _resolve(self, target: str | CartSet) -> tuple[list[PlanItem], list[str]]:
        s = self._set(target)
        items: list[PlanItem] = []
        problems: list[str] = []
        for k in dict.fromkeys(s.carts):
            c = self.carts.get(k)
            if c is None:
                problems.append(f"cart {k!r} is not in the library")
            elif c.error:
                problems.append(c.error)
            else:
                try:
                    fat12.validate_filename(c.file.name)
                except ValueError as e:
                    problems.append(f"{c.key}: invalid cart destination: {e}")
                else:
                    items.append(PlanItem(c.file, c.file.name, c.size, c.title, "cart"))
        keys = self._rom_keys(s.roms)
        taken = {i.name for i in items} | {r.short for k in keys
                                           if (r := self.roms.get(k)) and r.short}
        for k in keys:
            r = self.roms.get(k)
            if r is None:
                problems.append(f"ROM {k!r} is not in the library")
                continue
            if r.error:
                problems.append(r.error)
                continue
            name = self.drive_name(r)
            if name.upper() in {n.upper() for n in taken} and name != r.short:
                name = self.short_name(r, taken)
            try:
                fat12.validate_filename(name)
            except ValueError as e:
                problems.append(f"{k}: invalid ROM destination: {e}")
                continue
            if name.upper() in {i.name.upper() for i in items}:
                problems.append(f"{k}: destination {name!r} conflicts with another file")
                continue
            taken.add(name)
            items.append(PlanItem(r.file, name, r.size, r.title, "rom"))
        if not items and not problems:
            problems.append("nothing to deploy")
        return items, problems

    @staticmethod
    def short_name(rom: Rom, taken: set[str]) -> str:
        """8.3 drive name from the title (or file name) plus the file's extension."""
        return fat12.short_name_for((rom.title or rom.file.stem) + rom.file.suffix, taken)

    def plan(self, target: str | CartSet) -> list[PlanItem]:
        """UF2s first, then ROMs. Raises LibraryError when something is missing."""
        items, problems = self._resolve(target)
        if problems:
            raise LibraryError("; ".join(problems))
        return items

    @staticmethod
    def _fit_items(items: list[PlanItem], problems: list[str],
                   geom: fat12.Geometry | None) -> FitReport:
        rep = fat12.fit([(i.name, i.size) for i in items], geom=geom)
        rep.why[:0] = problems
        return rep

    def fit(self, target: str | CartSet, geom: fat12.Geometry | None = None) -> FitReport:
        return self._fit_items(*self._resolve(target), geom)

    def fit_json(self, target: str | CartSet, geom: fat12.Geometry | None = None) -> dict:
        """{bytes, entries, bytes_capacity, entries_capacity, fits, why, files} (POST /api/fit)."""
        items, problems = self._resolve(target)
        rep = self._fit_items(items, problems, geom)
        return {"bytes": rep.bytes_used, "entries": rep.entries_used,
                "bytes_capacity": rep.bytes_capacity, "entries_capacity": rep.entries_capacity,
                "fits": rep.fits, "why": rep.why, "files": [i.name for i in items]}

    def selection(self, carts: list[str], roms: list[str]) -> CartSet:
        """An ad-hoc set (key "custom", title "Selection"); unknown keys show up in fit()."""
        for what, v in (("carts", carts), ("roms", roms)):
            if not isinstance(v, (list, tuple)) or not all(isinstance(x, str) for x in v):
                raise LibraryError(f"{what} must be a list of strings")
        return CartSet(CUSTOM, "Selection", list(dict.fromkeys(carts)), list(dict.fromkeys(roms)))

    def identify(self, files: list[dict]) -> tuple[list[dict], str | None]:
        """FILES (name, size) with title and kind added, and the set whose plan they are."""
        names: dict[str, tuple[str, str]] = {}
        for c in self.carts.values():
            for v in c.variants.values():
                names[v.file.name.lower()] = (c.title, "cart")
        for r in self.roms.values():
            names.setdefault(r.file.name.lower(), (r.title, "rom"))
            names[self.drive_name(r).lower()] = (r.title, "rom")
        plans: dict[str, dict[str, tuple[str, str]]] = {}
        for k in self.sets:
            items, problems = self._resolve(k)
            plan = {i.name.lower(): (i.title, i.kind) for i in items}
            for n, v in plan.items():
                names.setdefault(n, v)
            if not problems:
                plans[k] = plan
        on = {f["name"].lower() for f in files
              if not f["name"].startswith(".") and f["name"] not in JUNK_HINT}
        match = next((k for k, p in plans.items() if on and set(p) == on), None)
        if match:                      # short ROM names depend on the set; trust its plan
            names.update(plans[match])
        out = []
        for f in files:
            title, kind = names.get(f["name"].lower(), (f["name"], "other"))
            out.append({**f, "title": title, "kind": kind})
        return out, match

    def validate_uf2(self, path: Path) -> str:
        """"ram" | "xip", raises on mixed/malformed (tools/uf2_info.py logic)."""
        return validate_uf2(path)

    # -- adding things --------------------------------------------------

    def add_rom(self, path: Path, title: str | None = None, key: str | None = None,
                short: str | None = None) -> Rom:
        """Copy PATH into roms/ and name it in the manifest. Returns the new Rom."""
        path = Path(path)
        if short:
            try:
                fat12.validate_filename(short)
            except ValueError as e:
                raise LibraryError(f"invalid ROM destination {short!r}: {e}") from e
        dst = self.root / "roms" / path.name
        with self.locked():
            raw = self._fresh_raw()
            self.reload()
            existing = [k for k, r in self.roms.items() if r.file.resolve() == dst.resolve()
                        and not r.auto]
            key = key or (existing[0] if existing else
                          self._free_key(slug(title or path.stem), raw.get("roms", {})))
            t = dict(raw.get("roms", {}).get(key, {}))
            t["file"] = f"roms/{dst.name}"
            t["title"] = title or t.get("title") or path.stem
            if short:
                t["short"] = short
            raw.setdefault("roms", {})[key] = t
            self._promote({dst: path}, raw)
        return self.roms[key]

    def _promote(self, files: dict[Path, Path], raw: dict,
                 expected_kinds: dict[Path, str] | None = None) -> None:
        """Stage artifacts, replace them, then commit metadata; restore on failure.

        Caller holds locked() and has read a valid current manifest.
        """
        staged: dict[Path, Path] = {}
        backups: dict[Path, Path] = {}
        promoted: list[Path] = []
        try:
            for dst, src in files.items():
                dst.parent.mkdir(parents=True, exist_ok=True)
                fd, name = tempfile.mkstemp(prefix=f".{dst.name}.", dir=dst.parent)
                staged[dst] = Path(name)
                previous = dst.stat() if dst.exists() else None
                os.fchmod(fd, stat.S_IMODE(previous.st_mode) if previous else 0o664)
                if os.geteuid() == 0:
                    os.fchown(fd, previous.st_uid if previous else os.geteuid(),
                               previous.st_gid if previous else dst.parent.stat().st_gid)
                try:
                    source_fd = _open_regular_nofollow(src)
                    with os.fdopen(source_fd, "rb") as inp, os.fdopen(fd, "wb") as out:
                        before = os.fstat(inp.fileno())
                        if not stat.S_ISREG(before.st_mode):
                            raise LibraryError(f"{src.name}: source is not a regular file")
                        shutil.copyfileobj(inp, out)
                        after = os.fstat(inp.fileno())
                        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                            raise LibraryError(f"{src.name}: source changed while staging")
                        out.flush()
                        os.fsync(out.fileno())
                except Exception:
                    # fdopen owns fd only after both context managers have entered.
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    raise
                if expected_kinds and dst in expected_kinds:
                    actual = validate_uf2(staged[dst])
                    if actual != expected_kinds[dst]:
                        raise UF2Error(f"{src.name}: staged cart changed from {expected_kinds[dst].upper()} to {actual.upper()}")
            for dst, tmp in staged.items():
                if dst.exists():
                    fd, name = tempfile.mkstemp(prefix=f".{dst.name}.backup.", dir=dst.parent)
                    with os.fdopen(fd, "wb") as out, dst.open("rb") as inp:
                        shutil.copyfileobj(inp, out)
                    backups[dst] = Path(name)
                os.replace(tmp, dst)
                promoted.append(dst)
            self._commit(raw)
        except Exception:
            for dst in reversed(promoted):
                if dst in backups:
                    os.replace(backups.pop(dst), dst)
                else:
                    dst.unlink(missing_ok=True)
            self.reload()
            raise
        finally:
            for tmp in [*staged.values(), *backups.values()]:
                tmp.unlink(missing_ok=True)

    def import_uf2(self, path: Path, key: str, title: str | None = None,
                   mode: str | None = None, build: str | None = None) -> Cart:
        """Validate PATH, copy it to carts/<key>.uf2 and name it in the manifest.

        An XIP UF2 keyed <family>-xip for a cart family that exists becomes that
        family's XIP variant (carts/<family>-xip.uf2) instead of a second cart.
        BUILD records the build job that made it (`build = "<id>"`); a UF2 imported
        without one drops any old `build` of that cart."""
        result = self.import_uf2s([(Path(path), key, title, mode, build)])
        return result[0]

    def import_uf2s(self, entries: list[tuple[Path, str, str | None, str | None, str | None]]) -> list[Cart]:
        """Validate and register a batch of UF2s under one library transaction."""
        with self.locked():
            raw = self._fresh_raw()
            self.reload()
            files: dict[Path, Path] = {}
            expected_kinds: dict[Path, str] = {}
            result_keys = []
            for path, key, title, mode, build in entries:
                path = Path(path)
                if not re.fullmatch(r"[A-Za-z0-9_-]+", key) or key.startswith("-"):
                    raise LibraryError(f"invalid cart key {key!r}")
                kind = validate_uf2(path)
                if mode and mode != kind:
                    raise UF2Error(f"{path.name} is a {kind.upper()} cart, not {mode.upper()}")
                tables = raw.setdefault("carts", {})
                fam, slot = family_of(key)
                fold = (slot == "xip" and kind == "xip" and key not in tables and (fam in self.carts or fam in tables)
                        and tables.get(fam, {}).get("mode") != "xip")
                dst = self.root / "carts" / f"{key}.uf2"
                if dst in files:
                    raise LibraryError(f"duplicate cart destination {dst.name}")
                files[dst] = path
                expected_kinds[dst] = kind
                if fold:
                    t = dict(tables.get(fam, {}))
                    t.pop("xip_file", None)
                    t["title"] = t.get("title") or title or fam
                    t.setdefault("roms", [])
                    tables[fam] = t
                    result_keys.append(fam)
                else:
                    t = dict(tables.get(key, {}))
                    t.pop("file", None)
                    t.pop("xip_file", None)
                    t["title"] = title or t.get("title") or key
                    t["mode"] = kind
                    t.setdefault("roms", [])
                    t.pop("build", None)
                    if build:
                        t["build"] = build
                    tables[key] = t
                    result_keys.append(key)
            if entries:
                self._promote(files, raw, expected_kinds)
            return [self.carts[k] for k in result_keys]

    def add_uf2(self, path: Path, key: str, title: str | None = None,
                mode: str | None = None, build: str | None = None) -> Cart:
        """import_uf2 under the name PLAN.md 9.2 uses."""
        return self.import_uf2(path, key, title, mode, build)

    def preview_url(self, build: str | None) -> str | None:
        """/builds/<id>/preview.gif when that build left a GIF, else None."""
        if build and BUILD_ID.fullmatch(build) and (
                self.root / "builds" / build / "out" / "preview.gif").is_file():
            return f"/builds/{build}/preview.gif"
        return None

    def set_cart_mode(self, key: str, mode: str) -> Cart:
        """Make sets deploy KEY's MODE ("ram" | "xip") variant; persists as `use`."""
        def change(raw):
            c = self.carts.get(key)
            if c is None:
                raise LibraryError(f"no cart called {key!r}")
            if mode not in c.variants:
                raise LibraryError(f"{c.title} has no {mode.upper()} variant in the library")
            t = dict(raw.get("carts", {}).get(key, {}))
            if c.auto:
                for slot, v in c.variants.items():
                    default = self.root / "carts" / (f"{key}.uf2" if slot == "ram" else f"{key}-xip.uf2")
                    if v.file.resolve() != default.resolve():
                        t["file" if slot == "ram" else "xip_file"] = self._rel(v.file)
            t["use"] = mode
            raw.setdefault("carts", {})[key] = t
        self._mutate(change)
        return self.carts[key]

    def save_set(self, title: str, carts: list[str], roms: list[str],
                 key: str | None = None, *, replace: bool = False) -> CartSet:
        """Create a set; replacing an existing key requires explicit replace=True."""
        title = str(title or "").strip()
        if not title:
            raise LibraryError("a set needs a title")
        sel = self.selection(carts, roms)
        if not sel.carts and not sel.roms:
            raise LibraryError("nothing selected")
        key = str(key or slug(title)).strip()
        if not key:
            raise LibraryError("a set needs a key")
        def change(raw):
            unknown = [f"cart {k!r}" for k in sel.carts if k not in self.carts]
            unknown += [f"ROM {k!r}" for k in sel.roms if not is_pattern(k) and k not in self.roms]
            if unknown:
                raise LibraryError(", ".join(unknown) + " not in the library")
            sec = raw.setdefault("sets", {})
            if key in sec and not replace:
                raise LibraryError(f"set {key!r} already exists as {str(sec[key].get('title', key))!r}; choose Replace")
            same_title = next((k for k, v in sec.items()
                               if k != key and slug(str(v.get("title", k))) == slug(title)), None)
            if same_title is not None:
                raise LibraryError(f"set {same_title!r} already exists as {str(sec[same_title].get('title', same_title))!r}; choose Replace with its key")
            t = dict(sec.get(key, {}))
            t.update(title=title, carts=sel.carts, roms=sel.roms)
            sec[key] = t
        self._mutate(change)
        return self.sets[key]

    def delete_set(self, key: str) -> None:
        def change(raw):
            sec = raw.get("sets", {})
            if key not in sec:
                raise LibraryError(f"no set called {key!r}")
            del sec[key]
        self._mutate(change)

    def init_defaults(self, path: Path) -> list[str]:
        """Add PATH's cart and set tables missing from the manifest; returns "carts.x"/"sets.y"."""
        try:
            defaults = tomllib.loads(Path(path).read_text())
        except (tomllib.TOMLDecodeError, OSError) as e:
            raise LibraryError(f"{path}: {e}") from e
        added = []
        def change(raw):
            for section in ("carts", "sets"):
                sec = raw.setdefault(section, {})
                for k, v in defaults.get(section, {}).items():
                    if not isinstance(v, dict):
                        continue
                    if k not in sec:
                        sec[k] = v
                        added.append(f"{section}.{k}")
                    elif section == "carts":
                        t = dict(sec[k])
                        fills = {kk: vv for kk, vv in v.items()
                                 if kk not in t or (kk == "title" and t[kk] == k)}
                        if fills:
                            sec[k] = {**t, **fills}
                            added.append(f"{section}.{k}." + ".".join(fills))
        self._mutate(change)
        return added

    def _rel(self, p: Path) -> str:
        try:
            return str(p.resolve().relative_to(self.root.resolve()))
        except ValueError:
            return str(p)

    def _set_table(self, section: str, key: str, table: dict) -> None:
        self._mutate(lambda raw: raw.setdefault(section, {}).__setitem__(key, table))

    def _del_table(self, section: str, key: str) -> None:
        self._mutate(lambda raw: raw.get(section, {}).pop(key, None))

    def _write(self, raw: dict) -> None:
        """Compatibility hook for callers with a complete replacement document."""
        with self.locked():
            self._fresh_raw()
            self._commit(raw)

    # -- JSON -----------------------------------------------------------

    def to_json(self, geom: fat12.Geometry | None = None) -> dict:
        """The "sets"/"library" parts of Station.status()."""
        sets = []
        for k, s in self.sets.items():
            sets.append({"name": k, "title": s.title, **self.fit_json(k, geom),
                         "carts": list(s.carts), "roms": list(s.roms)})
        carts = [{"key": c.key, "title": c.title, "use": c.use, "file": c.file.name,
                  "mode": c.mode, "size": c.size,
                  "variants": {m: {"file": v.file.name, "size": v.size, "ok": not v.error,
                                   "error": v.error} for m, v in c.variants.items()},
                  "roms": c.roms, "ok": not c.error, "error": c.error, "auto": c.auto,
                  "build": c.build, "preview": self.preview_url(c.build)}
                 for c in self.carts.values()]
        roms = [{"key": r.key, "title": r.title, "file": r.file.name,
                 "short": self.drive_name(r), "size": r.size,
                 "ok": not r.error, "error": r.error, "auto": r.auto}
                for r in self.roms.values()]
        return {"sets": sets, "library": {"carts": carts, "roms": roms, "error": self.error}}
