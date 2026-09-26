#!/usr/bin/env python3
"""Render animation packs: python3 tools/build.py [run|jump|all]"""
import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from snoutyart.export import write_pack  # noqa: E402
from snoutyart.rig import Rig  # noqa: E402

ALL = ["run", "jump"]

def main(names):
    rig = Rig()
    for n in names:
        try:
            mod = importlib.import_module(f"snoutyart.anim.{n}")
        except ModuleNotFoundError as e:
            if e.name == f"snoutyart.anim.{n}":
                print(f"skip {n}: no snoutyart/anim/{n}.py yet")
                continue
            raise
        write_pack(mod.build(rig))

if __name__ == "__main__":
    args = sys.argv[1:] or ["all"]
    main(ALL if args == ["all"] else args)
