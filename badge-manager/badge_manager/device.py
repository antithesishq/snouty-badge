"""The badge drive: find it, mount it, wipe it, fill it, eject it.

Real badge: USB mass storage, VID:PID 04d2:04d2, FAT12 label SYCLBADGE
(with the badge's exact volume geometry). The station runs as root and mounts with
`mount -t vfat -o sync,flush,utf8,shortname=mixed`. Eject = umount +
`udisksctl power-off -b DEV` (fallback: echo 1 > /sys/block/X/device/delete).

Privileged commands (mount, umount, udisksctl) run directly as root, else
through `sudo -n`; when neither works a DeviceError says so.
"""
from __future__ import annotations
import glob
import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from . import fat12

USB_ID = ("04d2", "04d2")
BY_LABEL = Path("/dev/disk/by-label") / fat12.LABEL
MOUNT_OPTS = "sync,flush,utf8,shortname=mixed"
JUNK_HINT = (".fseventsd", ".Spotlight-V100", ".Trashes", "System Volume Information")


@dataclass
class Entry:
    name: str
    size: int
    is_dir: bool = False


class Badge(Protocol):
    """One plugged-in badge drive. Methods raise DeviceError on failure."""
    device: str                       # /dev/sdX, image path, or directory
    fake: bool                        # LoopBadge/DirBadge: never really unplugs
    def mount(self) -> Path: ...      # idempotent, returns the mount point
    def unmount(self) -> None: ...
    def eject(self) -> None: ...      # unmount + power off; badge must be re-plugged after
    def listdir(self) -> list[Entry]: ...   # root files, hidden/host junk included
    def free_bytes(self) -> int: ...
    def free_entries(self) -> int: ...      # root directory entries left (read the FAT, not statvfs)
    def geometry(self) -> fat12.Geometry: ...  # capacity of the empty volume
    def fragmented(self) -> list[str]: ...  # files whose cluster chain is not one run
    def wipe(self) -> int: ...              # delete every root entry except the volume label; returns count
    def copy(self, src: Path, name: str) -> None: ...  # write + fsync; name is the drive name


class DeviceError(Exception):
    pass


def find_badge(fake: str | None = None,
               mount_root: Path = Path("/run/badge-station")) -> Badge | None:
    """FAKE = image path (LoopBadge, or ImageBadge when the kernel has no vfat;
    $BADGE_STATION_IMAGE=loop|builtin forces one) or directory (DirBadge); else
    scan /sys/bus/usb for exactly one 04d2:04d2 device -> BlockBadge.
    BlockBadge checks USB identity, volume label and geometry before mounting.
    A FAKE path that does not exist counts as unplugged."""
    if fake:
        p = Path(fake)
        if p.is_dir():
            return DirBadge(p)
        if p.is_file():
            mode = os.environ.get("BADGE_STATION_IMAGE") or ("loop" if kernel_has_vfat() else "builtin")
            return LoopBadge(p, mount_root) if mode == "loop" else ImageBadge(p)
        return None
    dev = _by_usb_id()
    return BlockBadge(dev, mount_root) if dev else None


def kernel_has_vfat() -> bool:
    """vfat registered, or available as a module (some VMs have neither)."""
    if "vfat" in (_read("/proc/filesystems") or ""):
        return True
    dep = _read(f"/lib/modules/{os.uname().release}/modules.dep") or ""
    return "/vfat.ko" in dep


def _by_label() -> str | None:
    if BY_LABEL.exists():
        return os.path.realpath(BY_LABEL)
    return None


def _by_usb_id(sys_usb: str = "/sys/bus/usb/devices") -> str | None:
    """Find the block device of a 04d2:04d2 USB device (whole disk or its first partition)."""
    candidates = set()
    for d in sorted(glob.glob(os.path.join(sys_usb, "*"))):
        if (_read(os.path.join(d, "idVendor")), _read(os.path.join(d, "idProduct"))) != USB_ID:
            continue
        for root, dirs, _ in os.walk(os.path.realpath(d)):
            if os.path.basename(root) != "block":
                continue
            for disk in sorted(dirs):
                if _read(f"/sys/block/{disk}/size") in (None, "0"):
                    continue      # no medium
                parts = sorted(glob.glob(f"/sys/block/{disk}/{disk}*"))
                name = os.path.basename(parts[0]) if parts else disk
                candidates.add(f"/dev/{name}")
    if len(candidates) > 1:
        raise DeviceError("multiple badges found; connect only the badge to change")
    return next(iter(candidates), None)


def _usb_identity(devnode: str) -> tuple[str | None, str | None]:
    path = Path("/sys/class/block") / Path(devnode).name
    for parent in path.resolve().parents:
        vendor = _read(str(parent / "idVendor"))
        if vendor is not None:
            return vendor, _read(str(parent / "idProduct"))
    return None, None


def _destination(root: Path, name: str) -> Path:
    try:
        fat12.validate_filename(name)
    except ValueError as e:
        raise DeviceError(str(e)) from e
    return root / name


def _read(path: str) -> str | None:
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def _priv(cmd: list[str], timeout: float = 30) -> subprocess.CompletedProcess:
    """Run CMD as root: directly when we are root, else via `sudo -n`."""
    full = cmd if os.geteuid() == 0 else ["sudo", "-n", *cmd]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as e:
        raise DeviceError(f"{full[0]} is not installed") from e
    except subprocess.TimeoutExpired as e:
        raise DeviceError(f"{' '.join(cmd)} timed out") from e
    if r.returncode != 0:
        msg = ((r.stderr or r.stdout).strip().splitlines() or ["exit %d" % r.returncode])[0]
        msg = msg.rsplit(": ", 1)[-1] if msg.startswith(cmd[0] + ":") else msg
        if os.geteuid() != 0 and "password" in msg.lower():
            msg = "this needs root: run the station as root or allow passwordless sudo"
        raise DeviceError(f"{cmd[0]} failed: {msg}")
    return r


def _mount_sources() -> dict[str, str]:
    """Mount point -> source device, from /proc/self/mounts."""
    out = {}
    try:
        for line in Path("/proc/self/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                out[parts[1].replace("\\040", " ")] = parts[0]
    except OSError:
        pass
    return out


def _loop_backing(dev: str) -> str | None:
    name = os.path.basename(dev)
    return _read(f"/sys/block/{name}/loop/backing_file")


def _list_root(root: Path) -> list[Entry]:
    out = []
    try:
        with os.scandir(root) as it:
            for e in it:
                is_dir = e.is_dir(follow_symlinks=False)
                size = 0 if is_dir else e.stat(follow_symlinks=False).st_size
                out.append(Entry(e.name, size, is_dir))
    except OSError as e:
        raise DeviceError(f"cannot list {root}: {e}") from e
    return sorted(out, key=lambda x: x.name.lower())


def _wipe_root(root: Path) -> int:
    """Remove every file and directory under ROOT (host junk included)."""
    n = 0
    try:
        with os.scandir(root) as it:
            entries = list(it)
        for e in entries:
            if e.is_dir(follow_symlinks=False):
                shutil.rmtree(e.path)
            else:
                os.unlink(e.path)
            n += 1
    except OSError as e:
        raise DeviceError(f"wipe failed: {e}") from e
    os.sync()
    return n


def _copy_file(src: Path, dst: Path) -> None:
    try:
        with open(src, "rb") as fi, os.fdopen(os.open(
                dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644), "wb") as fo:
            shutil.copyfileobj(fi, fo, 64 * 1024)
            fo.flush()
            os.fsync(fo.fileno())
        if dst.stat().st_size != src.stat().st_size:
            raise DeviceError(f"copy of {dst.name} is short")
        with open(src, "rb") as fi, open(dst, "rb") as fo:
            if hashlib.file_digest(fi, "sha256").digest() != hashlib.file_digest(fo, "sha256").digest():
                raise DeviceError(f"copy of {dst.name} failed content verification")
    except OSError as e:
        raise DeviceError(f"verification of {dst.name} failed: {e}") from e


class _Mounted:
    """Shared mount/list/wipe/copy for a FAT volume mounted at mount_root/badge."""
    device: str
    fake = False

    def __init__(self, mount_root: Path):
        self.mount_root = Path(mount_root)
        self.mountpoint = self.mount_root / "badge"
        self._mounted = False

    # subclasses: _source() (what mount takes), _owns(src) (is SRC ours), _mount_extra
    _mount_extra = ""

    def _source(self) -> str:
        return self.device

    def _owns(self, src: str) -> bool:
        return os.path.realpath(src) == os.path.realpath(self.device)

    def _raw_path(self) -> str:
        return self.device

    def mount(self) -> Path:
        mp = str(self.mountpoint)
        src = _mount_sources().get(mp)
        if src is not None:
            if self._owns(src):
                self._mounted = True
                return self.mountpoint
            _priv(["umount", mp])          # a stale mount of another device
        self._mkdir()
        opts = f"{MOUNT_OPTS},uid={os.getuid()},gid={os.getgid()}{self._mount_extra}"
        _priv(["mount", "-t", "vfat", "-o", opts, self._source(), mp])
        self._mounted = True
        return self.mountpoint

    def _mkdir(self) -> None:
        try:
            self.mountpoint.mkdir(parents=True, exist_ok=True)
        except PermissionError:
            _priv(["mkdir", "-p", str(self.mountpoint)])

    def unmount(self) -> None:
        if str(self.mountpoint) in _mount_sources():
            os.sync()
            _priv(["umount", str(self.mountpoint)])
        self._mounted = False

    def remount(self) -> None:
        """Fresh mount: resets the kernel's next-free-cluster hint so new files start at cluster 2."""
        self.unmount()
        self.mount()

    def listdir(self) -> list[Entry]:
        return _list_root(self.mount())

    def _volume(self) -> fat12.VolumeInfo:
        os.sync()
        try:
            with open(self._raw_path(), "rb") as fh:
                return fat12.read_volume(fh)
        except (OSError, ValueError) as e:
            raise DeviceError(f"cannot read the FAT volume on {self.device}: {e}") from e

    def free_bytes(self) -> int:
        return self._volume().free_bytes

    def free_entries(self) -> int:
        return self._volume().free_entries

    def geometry(self) -> fat12.Geometry:
        return self._volume().geometry

    def fragmented(self) -> list[str]:
        return [f.name for f in self._volume().files if f.runs > 1]

    def wipe(self) -> int:
        n = _wipe_root(self.mount())
        self.remount()
        return n

    def copy(self, src: Path, name: str) -> None:
        fat_name = _destination(self.mountpoint, name)
        self.mount()
        _copy_file(Path(src), fat_name)


class BlockBadge(_Mounted):
    def __init__(self, devnode: str, mount_root: Path = Path("/run/badge-station")):
        super().__init__(mount_root)
        self.device = os.path.realpath(devnode)

    def mount(self) -> Path:
        if _usb_identity(self.device) != USB_ID:
            raise DeviceError("device is not a SYCL badge (USB identity mismatch)")
        volume = self._volume()
        if volume.label != fat12.LABEL or volume.geometry != fat12.geometry():
            raise DeviceError("badge label or geometry does not match the supported SYCL volume")
        return super().mount()

    def _disk(self) -> str:
        """sdX for sdX or sdX1."""
        name = os.path.basename(self.device)
        if os.path.exists(f"/sys/class/block/{name}/partition"):
            return os.path.basename(os.path.realpath(f"/sys/class/block/{name}/.."))
        return name

    def eject(self) -> None:
        self.unmount()
        disk = f"/dev/{self._disk()}"
        try:
            _priv(["udisksctl", "power-off", "-b", disk])
            return
        except DeviceError as first:
            delete = Path(f"/sys/block/{self._disk()}/device/delete")
            try:
                if os.geteuid() == 0:
                    delete.write_text("1\n")
                else:
                    _priv(["sh", "-c", f"echo 1 > {delete}"])
            except (OSError, DeviceError) as e:
                raise DeviceError(f"eject failed: {first}; {e}") from e


class LoopBadge(_Mounted):
    """A tools/make_romfs.py image loop-mounted (needs root/sudo). VM end-to-end tests."""
    fake = True
    _mount_extra = ",loop"

    def __init__(self, image: Path, mount_root: Path):
        super().__init__(mount_root)
        self.image = Path(image).resolve()
        self.device = str(self.image)

    def _owns(self, src: str) -> bool:
        return (os.path.realpath(src) == self.device
                or _loop_backing(src) == self.device)

    def eject(self) -> None:
        self.unmount()


class DirBadge:
    """A plain directory standing in for the mounted drive; fit limits simulated
    from fat12 constants. Unit tests and the web page's demo mode (no root)."""
    fake = True

    def __init__(self, directory: Path, volume_bytes: int | None = None):
        self.directory = Path(directory).resolve()
        self.device = str(self.directory)
        self._geom = fat12.geometry(volume_bytes or fat12.VOLUME_BYTES)
        self.ejected = False

    def mount(self) -> Path:
        if not self.directory.is_dir():
            raise DeviceError(f"{self.directory} is gone")
        return self.directory

    def unmount(self) -> None:
        pass

    def eject(self) -> None:
        os.sync()
        self.ejected = True

    def listdir(self) -> list[Entry]:
        return _list_root(self.mount())

    def geometry(self) -> fat12.Geometry:
        return self._geom

    def _clusters(self) -> int:
        per = self._geom.cluster_bytes
        return sum(1 if e.is_dir else -(-e.size // per) if e.size else 0 for e in self.listdir())

    def free_bytes(self) -> int:
        return max(0, self._geom.clusters - self._clusters()) * self._geom.cluster_bytes

    def free_entries(self) -> int:
        used = 1 + sum(fat12.root_entries_for(e.name) for e in self.listdir())
        return max(0, self._geom.root_entries - used)

    def fragmented(self) -> list[str]:
        return []

    def wipe(self) -> int:
        return _wipe_root(self.mount())

    def copy(self, src: Path, name: str) -> None:
        dst = _destination(self.directory, name)
        _copy_file(Path(src), dst)


class ImageBadge:
    """A FAT12 image written by the station's own FAT code (fat12.Fat12Image), no
    mount and no root. --fake-badge IMG on kernels without vfat, and tests."""
    fake = True

    def __init__(self, image: Path):
        self.image = Path(image).resolve()
        self.device = str(self.image)

    def _open(self) -> fat12.Fat12Image:
        try:
            return fat12.Fat12Image(self.device)
        except (OSError, ValueError) as e:
            raise DeviceError(f"cannot open the image {self.device}: {e}") from e

    def _volume(self) -> fat12.VolumeInfo:
        try:
            with open(self.device, "rb") as fh:
                return fat12.read_volume(fh)
        except (OSError, ValueError) as e:
            raise DeviceError(f"cannot read the FAT volume in {self.device}: {e}") from e

    def mount(self) -> Path:
        self._volume()
        return self.image

    def unmount(self) -> None:
        pass

    def eject(self) -> None:
        os.sync()

    def listdir(self) -> list[Entry]:
        return sorted((Entry(f.name, 0 if f.is_dir else f.size, f.is_dir)
                       for f in self._volume().files), key=lambda e: e.name.lower())

    def free_bytes(self) -> int:
        return self._volume().free_bytes

    def free_entries(self) -> int:
        return self._volume().free_entries

    def geometry(self) -> fat12.Geometry:
        return self._volume().geometry

    def fragmented(self) -> list[str]:
        return [f.name for f in self._volume().files if f.runs > 1]

    def wipe(self) -> int:
        img = self._open()
        n = img.wipe()
        self._save(img)
        return n

    def copy(self, src: Path, name: str) -> None:
        _destination(self.image.parent, name)
        img = self._open()
        try:
            data = Path(src).read_bytes()
            img.add(name, data)
        except (OSError, ValueError) as e:
            raise DeviceError(f"copy of {name} failed: {e}") from e
        self._save(img)
        try:
            if self._open().read_file(name) != data:
                raise DeviceError(f"copy of {name} failed content verification")
        except ValueError as e:
            raise DeviceError(f"copy of {name} failed verification: {e}") from e

    def _save(self, img: fat12.Fat12Image) -> None:
        try:
            img.save()
        except OSError as e:
            raise DeviceError(f"cannot write the image {self.device}: {e}") from e
