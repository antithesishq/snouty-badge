#!/usr/bin/env python3
"""Runs the oracle (basic.py, in process) and the engine runner on answer
scripts and reports the first diverging transcript line.

    compare.py [--runner PATH] [--jobs N] [script ...]

With no scripts it runs every scripts/*.txt. Exit 0 iff every transcript
(and exit status) matches. fuzz.py uses the same machinery for its games.
"""
import argparse
import glob
import multiprocessing
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import basic  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
DEFAULT_RUNNER = os.path.join(REPO, "zig-out", "bin", "raspberry-trail-oracle")
CONTEXT = 5


def oracle_transcript(text):
    """(transcript lines, exit code) from basic.py for a script's text."""
    it = basic.run_script_text(text, warn=lambda m: None)
    return it.out, basic.exit_code(it), it


def engine_transcript(runner, script_path, timeout=60):
    try:
        p = subprocess.run([runner, script_path], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ["<engine timed out after %d s>" % timeout], -1, ""
    out = p.stdout.decode("utf-8", "replace").split("\n")
    if out and out[-1] == "":
        out.pop()
    return out, p.returncode, p.stderr.decode("utf-8", "replace")


def diff_report(oracle, engine, ctx=CONTEXT):
    """None if equal, else a report of the first diverging line."""
    n = min(len(oracle), len(engine))
    i = 0
    while i < n and oracle[i] == engine[i]:
        i += 1
    if i == n and len(oracle) == len(engine):
        return None
    lo = max(0, i - ctx)
    rep = ["first difference at transcript line %d" % (i + 1)]
    for name, side in (("oracle", oracle), ("engine", engine)):
        rep.append("  %s:" % name)
        for j in range(lo, min(len(side), i + ctx + 1)):
            mark = ">>" if j == i else "  "
            rep.append("  %s %5d %s" % (mark, j + 1, side[j]))
        if i >= len(side):
            rep.append("  >> %5d <end of transcript>" % (i + 1))
    return "\n".join(rep)


def compare_text(runner, text, tmpdir, name="script"):
    """Compares one script. Returns (ok, report, interp)."""
    o_out, o_code, it = oracle_transcript(text)
    fd, path = tempfile.mkstemp(suffix=".txt", dir=tmpdir)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    try:
        e_out, e_code, e_err = engine_transcript(runner, path)
    finally:
        os.unlink(path)
    rep = diff_report(o_out, e_out)
    if rep is None and o_code != e_code:
        rep = "transcripts match but exit codes differ: oracle %d, engine %d" % (o_code, e_code)
    if rep is not None and e_err.strip():
        rep += "\n  engine stderr: " + e_err.strip().replace("\n", "\n    ")
    return rep is None, rep, it


def _worker(args):
    runner, path, tmpdir = args
    with open(path) as f:
        text = f.read()
    try:
        ok, rep, it = compare_text(runner, text, tmpdir, path)
        return path, ok, rep, it.outcome, it.ended
    except Exception as e:  # report and keep going
        return path, False, "error: %r" % (e,), None, None


def check_runner(runner):
    if not (os.path.isfile(runner) and os.access(runner, os.X_OK)):
        sys.stderr.write("engine runner not found: %s\n"
                         "build it: zig build raspberry-trail-oracle -Dcart=raspberry-trail\n" % runner)
        sys.exit(3)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runner", default=DEFAULT_RUNNER)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    ap.add_argument("scripts", nargs="*")
    a = ap.parse_args(argv)
    check_runner(a.runner)
    paths = a.scripts or sorted(glob.glob(os.path.join(HERE, "scripts", "*.txt")))
    if not paths:
        sys.stderr.write("no scripts\n")
        return 3
    tmpdir = tempfile.mkdtemp(prefix="trail-compare-")
    bad = 0
    try:
        with multiprocessing.Pool(a.jobs) as pool:
            for path, ok, rep, outcome, ended in pool.imap(_worker, [(a.runner, p, tmpdir) for p in paths]):
                rel = os.path.relpath(path)
                if ok:
                    print("ok   %-60s %s" % (rel, outcome or ended))
                else:
                    bad += 1
                    print("FAIL %s\n%s" % (rel, rep))
    finally:
        os.rmdir(tmpdir)
    print("%d scripts, %d match, %d differ" % (len(paths), len(paths) - bad, bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
