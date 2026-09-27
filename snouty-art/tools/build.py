#!/usr/bin/env python3
"""Render animation packs.

    python3 tools/build.py [--style NAME] [run|jump|all]     (default: all styles)

Animations come from styles/<style>/anim/<cycle>.py when that file exists,
otherwise from the shared snoutyart/anim/<cycle>.py. Output: out/<style>/<cycle>/.
"""
import importlib
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from snoutyart.export import write_pack  # noqa: E402
from snoutyart.rig import Rig  # noqa: E402

ALL = ["run", "jump"]


def load_anim(style: str, cycle: str):
    override = ROOT / "styles" / style / "anim" / f"{cycle}.py"
    if override.exists():
        spec = importlib.util.spec_from_file_location(f"style_{style}_{cycle}", override)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, str(override.relative_to(ROOT))
    try:
        return importlib.import_module(f"snoutyart.anim.{cycle}"), f"snoutyart/anim/{cycle}.py"
    except ModuleNotFoundError as e:
        if e.name == f"snoutyart.anim.{cycle}":
            return None, None
        raise


def styles():
    return sorted(p.name for p in (ROOT / "styles").iterdir() if (p / "rig.json").exists())


def main(argv):
    chosen = None
    if "--style" in argv:
        i = argv.index("--style")
        chosen = [argv[i + 1]]
        del argv[i:i + 2]
    names = ALL if (not argv or argv == ["all"]) else argv
    for style in chosen or styles():
        rig = Rig(style)
        for n in names:
            mod, src = load_anim(style, n)
            if mod is None:
                print(f"skip {style}/{n}: no animation file")
                continue
            print(f"[{style}/{n}] from {src}")
            write_pack(mod.build(rig), rig)


if __name__ == "__main__":
    main(sys.argv[1:])
