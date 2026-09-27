"""carts/<name>.toml: optional per-cart defaults, chosen by ELF basename.

Keys (all optional):
  budget_ms = 16.7            frame budget for the report
  frames    = 600             updates to run
  script    = "carts/snouty-bugs/tools/scripts/m1_play.json"   relative to the repository root
              (the directory above the ELF's zig-out/, see cart_root)
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


def _strip_comment(line):
    """Drop a # comment that is not inside a "string"."""
    q = False
    for i, ch in enumerate(line):
        if ch == '"' and (i == 0 or line[i - 1] != '\\'):
            q = not q
        elif ch == '#' and not q:
            return line[:i]
    return line


def _tiny_toml(text, path):
    """Enough TOML for this file: key = number | "string" | [strings] (arrays
    may span lines), # comments."""
    out = {}
    pending, start = '', 0
    for n, line in enumerate(text.splitlines(), 1):
        s = _strip_comment(line).strip()
        if pending:
            pending += ' ' + s
            if not pending.rstrip().endswith(']'):
                continue
            s, pending = pending, ''
        elif not s:
            continue
        else:
            start = n
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$', s)
        if not m:
            raise BenchError(f"{path}:{start}: cannot parse '{s}' (tiny TOML parser)")
        k, v = m.group(1), m.group(2)
        if v.startswith('[') and not v.endswith(']'):
            pending = s
            continue
        if v.startswith('['):
            out[k] = re.findall(r'"((?:[^"\\]|\\.)*)"', v)
        elif v.startswith('"') and v.endswith('"'):
            out[k] = v[1:-1]
        else:
            try:
                out[k] = int(v, 0)
            except ValueError:
                try:
                    out[k] = float(v)
                except ValueError:
                    raise BenchError(f"{path}:{start}: bad value '{v}'")
    if pending:
        raise BenchError(f"{path}:{start}: unterminated array")
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
