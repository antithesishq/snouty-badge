"""carts/<name>.toml: optional per-cart defaults, chosen by ELF basename.

Keys (all optional):
  budget_ms = 16.7            frame budget for the report
  frames    = 600             updates to run
  script    = "tools/scripts/m1_play.json"   relative to the cart repo root
  pokes     = ["dither.mode=1"]
  press     = ["A:30-31"]
  note      = "free text shown in the report header"

The cart repo root is the directory above zig-out/ when the ELF lives in
<repo>/zig-out/firmware/, else the ELF's own directory. Command-line flags
override every key.
"""
import os
import re

from .elf import BenchError

HERE = os.path.dirname(os.path.abspath(__file__))
CARTS_DIR = os.path.join(os.path.dirname(HERE), 'carts')
KEYS = {'budget_ms': (int, float), 'frames': (int,), 'script': (str,), 'pokes': (list,),
        'press': (list,), 'note': (str,)}


def _tiny_toml(text, path):
    """Enough TOML for this file: key = number | "string" | [strings], comments."""
    out = {}
    for n, line in enumerate(text.splitlines(), 1):
        s = line.split('#', 1)[0].strip() if '"' not in line else line.strip()
        if not s or s.startswith('#'):
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*(#.*)?$', s)
        if not m:
            raise BenchError(f"{path}:{n}: cannot parse '{line}' (tiny TOML parser)")
        k, v = m.group(1), m.group(2)
        if v.startswith('['):
            items = re.findall(r'"((?:[^"\\]|\\.)*)"', v)
            out[k] = items
        elif v.startswith('"'):
            out[k] = v.strip('"')
        else:
            try:
                out[k] = int(v, 0)
            except ValueError:
                try:
                    out[k] = float(v)
                except ValueError:
                    raise BenchError(f"{path}:{n}: bad value '{v}'")
    return out


def _parse(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    try:
        import tomllib  # Python 3.11+
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            tomllib = None
    if tomllib is not None:
        try:
            return tomllib.loads(raw.decode())
        except Exception as e:
            raise BenchError(f"{path}: {e}")
    return _tiny_toml(raw.decode(), path)


def cart_root(elf_path):
    d = os.path.dirname(os.path.abspath(elf_path))
    if os.path.basename(d) == 'firmware' and os.path.basename(os.path.dirname(d)) == 'zig-out':
        return os.path.dirname(os.path.dirname(d))
    return d


def load(elf_path, explicit=None):
    """(config dict, path or None)."""
    if explicit:
        path = explicit
        if not os.path.isfile(path):
            raise BenchError(f"config {path} not found")
    else:
        name = os.path.splitext(os.path.basename(elf_path))[0]
        path = os.path.join(CARTS_DIR, name + '.toml')
        if not os.path.isfile(path):
            return {}, None
    cfg = _parse(path)
    for k, v in cfg.items():
        if k not in KEYS:
            raise BenchError(f"{path}: unknown key '{k}' (known: {', '.join(KEYS)})")
        if not isinstance(v, KEYS[k]) or isinstance(v, bool):
            raise BenchError(f"{path}: '{k}' has the wrong type")
    if 'script' in cfg and not os.path.isabs(cfg['script']):
        cfg['script'] = os.path.join(cart_root(elf_path), cfg['script'])
    return cfg, path
