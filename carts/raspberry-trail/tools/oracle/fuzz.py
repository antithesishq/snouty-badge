#!/usr/bin/env python3
"""Seeded random games: the oracle plays each game itself, answering every
INPUT (by its line number) from a seeded random policy, records the answer
script, then runs that script through the engine runner and compares the
transcripts. It also reports coverage over the whole set.

    fuzz.py --games 2000 --seed 1            # the fixed gate set
    fuzz.py --games 2000 --seed 1 --no-engine   # oracle + coverage only
    fuzz.py --games 1 --seed 1 --index 17 --print-script   # one game's script

Exit status: 0 when every game matches and every PRINT line of the listing
was reached (unreachable.txt lists the exceptions, each with its reason);
1 otherwise; 3 when the runner is missing.
"""
import argparse
import collections
import multiprocessing
import os
import random
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import basic  # noqa: E402
import compare  # noqa: E402

UNREACHABLE = os.path.join(HERE, "unreachable.txt")

# Line where each event or situation starts (coverage report names).
EVENTS = collections.OrderedDict([
    (3660, "wagon breaks down"), (3700, "ox injures leg"),
    (3740, "daughter broke arm"), (3790, "ox wanders off"),
    (3820, "son gets lost"), (3850, "unsafe water"),
    (3890, "heavy rains"), (4490, "cold weather"),
    (4510, "cold: not enough clothing"), (3960, "bandits attack"),
    (4000, "bandits: out of bullets"), (4100, "bandits: quickest draw"),
    (4130, "fire in the wagon"), (4190, "heavy fog"), (4220, "snakebite"),
    (4290, "wagon swamped"), (4340, "wild animals"),
    (4370, "wolves: too low on bullets"), (4420, "wolves: nice shootin'"),
    (4440, "wolves: slow on the draw"), (4560, "hail storm"),
    (4610, "illness event (eating)"), (4670, "helpful indians"),
    (2900, "riders"), (2930, "riders: don't look hostile"),
    (2990, "riders: hostility flips"), (3060, "riders: run (hostile)"),
    (3120, "riders: attack (hostile)"), (3260, "riders: continue (hostile)"),
    (3290, "riders: circle wagons (hostile)"), (3340, "riders: run (friendly)"),
    (3380, "riders: attack (friendly)"), (3420, "riders: continue (friendly)"),
    (3430, "riders: circle wagons (friendly)"), (3450, "riders: did not attack"),
    (3150, "riders: nice shooting"), (3180, "riders: knifed"),
    (3220, "riders: kinda slow"), (3480, "riders were friendly"),
    (3500, "riders were hostile"),
    (2290, "fort"), (2370, "fort: overspend"), (2570, "hunt"),
    (2620, "hunt: nice shot"), (2660, "hunt: big one"), (2710, "hunt: missed"),
    (2240, "hunt menu: no bullets"), (2550, "fort menu hunt: no bullets"),
    (2840, "can't eat that well"), (1840, "low food warning"),
    (1970, "doctor's bill"), (4730, "rugged mountains"),
    (4750, "mountains: lost"), (4790, "mountains: wagon damaged"),
    (4840, "mountains: going gets slow"), (4890, "south pass: no snow"),
    (4970, "blizzard"), (4950, "M9 set (950 display)"),
    (2020, "mileage shown as 950"), (6320, "serious illness"),
    (6370, "mild illness"), (6410, "bad illness"),
    (880, "not enough (oxen)"), (910, "too much (oxen)"),
    (960, "impossible (food)"), (1010, "impossible (ammo)"),
    (1060, "impossible (clothing)"), (1110, "impossible (misc)"),
    (1150, "overspent"), (790, "marksman > 5 -> 0"),
    (5280, "aunt sadie"), (5310, "telegraph"),
    (1650, "date DECEMBER 6"), (1670, "date DECEMBER 20"),
    (1690, "winter (turn 20)"), (5440, "arrival"),
    (5550, "arrival: weekday wraps"), (5760, "arrival in AUGUST"),
    (5800, "arrival in SEPTEMBER"), (5840, "arrival in OCTOBER"),
    (5880, "arrival in NOVEMBER"), (5910, "arrival in DECEMBER"),
])


# ---------------------------------------------------------------- policy

PROFILES = {
    # name: weight
    "arrive": 30,
    "careful": 15,
    "random": 15,
    "slow": 10,
    "starve": 6,
    "broke": 7,
    "nomisc": 7,
    "noammo": 7,
    "invalid": 3,
    "crawl": 20,
}


# Answers that always leave a re-ask loop.
SAFE = {760: "3", 860: "250", 940: "0", 990: "0", 1040: "0", 1090: "0",
        2100: "3", 2180: "2", 2330: "0", 2770: "1", 3000: "3"}


class Policy:
    """Answers INPUTs for one game from a seeded random.Random."""

    def __init__(self, rnd):
        self.r = rnd
        names = sorted(PROFILES)
        self.profile = rnd.choices(names, weights=[PROFILES[n] for n in names])[0]
        p = self.profile
        r = self.r
        self.inv = {"invalid": 0.35, "random": 0.15}.get(p, r.choice([0.0, 0.02, 0.05, 0.1]))
        self.last_line = None
        self.same = 0
        self.spent = 0
        # Shooting skill: probability of the right word, typical seconds.
        self.hit = r.choice([0.6, 0.85, 0.95, 1.0])
        self.speed = r.choice([0.3, 0.8, 1.5, 3.0, 5.0])
        self.claim = r.choices([1, 2, 3, 4, 5, 0, 6, 7, 8, 9], weights=[20, 20, 20, 15, 15, 2, 2, 2, 2, 2])[0]
        self.eat = r.choice([(1, 2, 3), (2, 3), (3,), (2,), (1,), (1, 2)])
        self.fort_p = {"slow": 0.8, "careful": 0.4}.get(p, r.choice([0.0, 0.1, 0.3]))
        self.hunt_p = {"slow": 0.8, "careful": 0.3, "starve": 0.0}.get(p, r.choice([0.0, 0.1, 0.4]))
        self.tactic = r.choice([None, 1, 2, 3, 4])

    def invalid(self):
        return self.r.random() < self.inv

    def __call__(self, it, line, kind):
        if line == self.last_line:
            self.same += 1
        else:
            self.last_line = line
            self.same = 0
        if self.same >= 3 and line in SAFE:
            # A re-ask loop (an invalid answer, eating too well, hunting
            # without bullets): answer something that always gets out.
            return SAFE[line]
        return self.answer(it, line, kind, force_valid=False)

    def big(self):
        return self.r.choice([-1, -50, -9999, 0, 701, 1000, 9999])

    def answer(self, it, line, kind, force_valid):
        r = self.r
        v = it.v
        p = self.profile
        bad = (not force_valid) and self.invalid()
        if p == "crawl" and not bad:
            tok = self.crawl(it, line)
            if tok is not None:
                return tok
        if kind == "yes_no":
            return r.choice(["YES", "NO"])
        if line == 760:
            if bad:
                return str(r.choice([0, 6, 7, 8, 9]))
            return str(self.claim)
        if line == 860:
            self.spent = 0
            if bad:
                return str(r.choice([199, 301, 0, -5, 150, 350, 1000, -9999]))
            if p in ("arrive", "careful"):
                a = r.randint(250, 300)
            elif p == "slow":
                a = r.randint(200, 220)
            else:
                a = r.randint(200, 300)
            self.spent = a
            return str(a)
        if line in (940, 990, 1040, 1090):
            left = 700 - self.spent
            if bad:
                x = r.choice([-1, -5, -100, left + 1, left + r.randint(1, 500), 700])
            else:
                x = self.purchase(line, left)
            if x >= 0:
                self.spent += x
            return str(x)
        if line == 2100:
            if bad:
                return str(r.choice([0, 4, 5, 9]))
            if v["F"] < 40 and v["B"] > 39 and p not in ("starve",) and r.random() < 0.7:
                return "2"
            if r.random() < self.fort_p:
                return "1"
            if r.random() < self.hunt_p:
                return "2"
            return "3"
        if line == 2180:
            if bad:
                return str(r.choice([0, 3, 4, 9]))
            if v["F"] < 40 and v["B"] > 39 and p != "starve" and r.random() < 0.7:
                return "1"
            if r.random() < self.hunt_p:
                return "1"
            return "2"
        if line == 2330:
            t = int(v["T"])
            if bad:
                return str(r.choice([-1, -20, t + 1, t + r.randint(1, 300), 9999]))
            if t <= 0:
                return "0"
            return str(r.choice([0, r.randint(0, t), r.randint(0, max(0, t // 3))]))
        if line == 2770:
            if bad:
                return str(r.choice([0, 4, 5, 9]))
            return str(r.choice(self.eat))
        if line == 3000:
            if bad:
                return str(r.choice([0, 5, 6, 9]))
            if self.tactic is not None and r.random() < 0.7:
                return str(self.tactic)
            return str(r.randint(1, 4))
        if line == 6220:
            ok = 1 if r.random() < self.hit else 0
            if r.random() < 0.15:
                secs = r.uniform(0, 12)
            else:
                secs = min(12.0, r.expovariate(1.0 / self.speed))
            return "SHOOT %d %s" % (ok, "%.3f" % secs)
        raise AssertionError("no policy for INPUT line %d" % line)

    def crawl(self, it, line):
        """Go slowly and survive: the winter, December dates and late
        arrivals. Cheap oxen, every fort and hunt (45 miles each), run
        from hostile riders early (A-40), miss the bandits (they take an
        ox), keep cash for the doctor."""
        r = self.r
        v = it.v
        if line == 860:
            self.spent = 200
            return "200"
        if line in (940, 990, 1040, 1090):
            want = {940: r.randint(80, 140), 990: r.randint(60, 150),
                    1040: r.randint(40, 80), 1090: r.randint(60, 120)}[line]
            x = max(0, min(want, 700 - self.spent))
            self.spent += x
            return str(x)
        if line == 2100:
            return "1" if v["T"] > 0 and r.random() < 0.7 else ("2" if v["B"] > 39 else "1")
        if line == 2180:
            return "1" if v["B"] > 39 else "2"
        if line == 2330:
            t = int(v["T"])
            keep = 40  # the doctor
            return str(max(0, min(t - keep, r.randint(0, 40))))
        if line == 2770:
            return str(r.choice((2, 3)))
        if line == 3000:
            if v["S5"] == 0 and v["D3"] < 12:
                return "1"
            return str(r.choice((3, 4)))
        if line == 6220:
            ret = it.stack[-1] if it.stack else 0
            if ret == 3980:  # bandits: miss on purpose
                return "SHOOT 0 %.3f" % r.uniform(0, 3)
            return "SHOOT 1 %.3f" % r.uniform(0.1, 1.2)
        return None

    def purchase(self, line, left):
        r = self.r
        p = self.profile
        if p == "random":
            return r.randint(0, max(0, left))
        # target split of the 700 - A budget
        if line == 940:
            if p == "starve":
                want = r.randint(0, 30)
            elif p == "broke":
                want = r.randint(50, 200)
            else:
                want = r.randint(80, 250)
        elif line == 990:
            if p == "noammo":
                want = r.randint(0, 3)
            elif p == "starve":
                want = r.randint(0, 20)
            else:
                want = r.randint(10, 150)
        elif line == 1040:
            want = r.randint(0, 40) if p in ("broke", "starve", "random") else r.randint(30, 130)
        else:
            if p == "nomisc":
                want = r.randint(0, 6)
            elif p == "broke":
                want = left  # spend it all: no cash for the doctor
            else:
                want = r.randint(10, 120)
        return max(0, min(want, left))


# ---------------------------------------------------------------- games

def game_params(base_seed, index):
    r = random.Random("trail-fuzz:%d:%d" % (base_seed, index))
    return r.getrandbits(64), random.Random(r.getrandbits(64))


def play(base_seed, index):
    """Plays one fuzz game with the oracle. Returns (script text, interp)."""
    seed, prng = game_params(base_seed, index)
    pol = Policy(prng)
    it = basic.Interp(seed, pol, warn=lambda m: None)
    it.run()
    lines = ["seed %d" % seed, "# fuzz --seed %d game %d, profile %s" % (base_seed, index, pol.profile)]
    lines += it.answers
    return "\n".join(lines) + "\n", it, pol.profile


def _job(args):
    base_seed, index, runner, tmpdir = args
    text, it, profile = play(base_seed, index)
    res = {
        "index": index, "outcome": it.outcome, "ended": it.ended,
        "hits": it.hits, "profile": profile, "turns": int(it.v["D3"]),
        "nonint": it.nonint, "text": text, "ok": True, "report": None,
    }
    if runner:
        e_text_path = None
        try:
            fd, e_text_path = tempfile.mkstemp(suffix=".txt", dir=tmpdir)
            with os.fdopen(fd, "w") as f:
                f.write(text)
            e_out, e_code, e_err = compare.engine_transcript(runner, e_text_path)
        finally:
            if e_text_path:
                os.unlink(e_text_path)
        rep = compare.diff_report(it.out, e_out)
        if rep is None and basic.exit_code(it) != e_code:
            rep = "transcripts match but exit codes differ: oracle %d, engine %d" % (basic.exit_code(it), e_code)
        if rep is not None:
            if e_err.strip():
                rep += "\n  engine stderr: " + e_err.strip()[:2000]
            res["ok"] = False
            res["report"] = rep
    if res["ok"]:
        res["text"] = None
    return res


def load_unreachable(path=UNREACHABLE):
    lines, outcomes = {}, {}
    if not os.path.exists(path):
        return lines, outcomes
    with open(path) as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            key, _, reason = s.partition(" ")
            if not reason.strip():
                raise SystemExit("unreachable.txt: entry without a reason: %r" % s)
            if key.startswith("outcome:"):
                outcomes[key[len("outcome:"):]] = reason.strip()
            else:
                lines[int(key)] = reason.strip()
    return lines, outcomes


def short(reason, n=110):
    return reason if len(reason) <= n else reason[:n - 3] + "... (unreachable.txt)"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--games", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--runner", default=compare.DEFAULT_RUNNER)
    ap.add_argument("--no-engine", action="store_true", help="oracle and coverage only")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    ap.add_argument("--index", type=int, help="only this game index")
    ap.add_argument("--print-script", action="store_true", help="print the game's script (with --index)")
    ap.add_argument("--fail-dir", help="write the scripts of differing games here")
    ap.add_argument("--max-reports", type=int, default=5)
    a = ap.parse_args(argv)

    if a.index is not None and a.print_script:
        text, it, _ = play(a.seed, a.index)
        sys.stdout.write(text)
        return 0
    runner = None if a.no_engine else a.runner
    if runner:
        compare.check_runner(runner)
    indices = [a.index] if a.index is not None else list(range(a.games))
    t0 = time.time()
    tmpdir = tempfile.mkdtemp(prefix="trail-fuzz-")
    results = []
    try:
        with multiprocessing.Pool(a.jobs) as pool:
            for res in pool.imap_unordered(_job, [(a.seed, i, runner, tmpdir) for i in indices], chunksize=8):
                results.append(res)
    finally:
        os.rmdir(tmpdir)
    elapsed = time.time() - t0
    results.sort(key=lambda r: r["index"])

    prog = basic.program()
    hits = set()
    outcomes = collections.Counter()
    events = collections.Counter()
    profiles = collections.Counter()
    turns = collections.Counter()
    nonint = []
    for res in results:
        hits |= res["hits"]
        outcomes[res["outcome"] or res["ended"]] += 1
        profiles[res["profile"]] += 1
        turns[res["turns"]] += 1
        for ln in EVENTS:
            if ln in res["hits"]:
                events[ln] += 1
        nonint += res["nonint"]

    # mismatches
    bad = [r for r in results if not r["ok"]]
    print("fuzz: %d games, seed %d, %.1f s, engine %s" % (len(results), a.seed, elapsed, runner or "skipped"))
    if runner:
        print("engine comparison: %d match, %d differ" % (len(results) - len(bad), len(bad)))
        fail_dir = a.fail_dir
        if bad and not fail_dir:
            fail_dir = tempfile.mkdtemp(prefix="trail-fuzz-fail-")
        for r in bad:
            path = os.path.join(fail_dir, "fuzz-s%d-g%d.txt" % (a.seed, r["index"]))
            os.makedirs(fail_dir, exist_ok=True)
            with open(path, "w") as f:
                f.write(r["text"])
            r["path"] = path
        for r in bad[:a.max_reports]:
            print("DIFF game %d (%s): %s\n%s" % (r["index"], r["profile"], r["path"], r["report"]))
        if len(bad) > a.max_reports:
            print("... %d more differing games, scripts in %s" % (len(bad) - a.max_reports, fail_dir))

    print("\noutcomes:")
    for name in basic.OUTCOMES + ("eof", "mismatch", "none"):
        if outcomes.get(name):
            print("  %-16s %5d" % (name, outcomes[name]))
    missing_outcomes = [o for o in basic.OUTCOMES if not outcomes.get(o)]
    print("profiles: " + ", ".join("%s %d" % kv for kv in sorted(profiles.items())))
    print("D3 at the end (the turn; the day of the month after an arrival): " + ", ".join("%d:%d" % kv for kv in sorted(turns.items())))
    print("\nevents (games reaching the line):")
    for ln, name in EVENTS.items():
        print("  %5d %-36s %5d" % (ln, name, events[ln]))

    un_lines, un_outcomes = load_unreachable()
    printed = prog.print_lines
    reached = [ln for ln in printed if ln in hits]
    unreached = [ln for ln in printed if ln not in hits]
    print("\nPRINT lines: %d of %d reached" % (len(reached), len(printed)))
    print("reached: " + " ".join(str(ln) for ln in reached))
    fail = False
    for ln in unreached:
        if ln in un_lines:
            print("UNREACHED %d allowlisted: %s" % (ln, short(un_lines[ln])))
        else:
            print("UNREACHED %d NOT ALLOWLISTED: %s" % (ln, prog.text[ln]))
            fail = True
    for ln in un_lines:
        if ln in hits:
            print("NOTE: allowlisted line %d was reached; drop it from unreachable.txt" % ln)
            fail = True
    for o in missing_outcomes:
        if o in un_outcomes:
            print("OUTCOME %s never reached, allowlisted: %s" % (o, short(un_outcomes[o])))
        else:
            print("OUTCOME %s never reached, NOT ALLOWLISTED" % o)
            fail = True
    all_lines = set(prog.numbers)
    non_rem = [ln for ln in prog.numbers if prog.text[ln].split(None, 1)[:1] not in (["REM"], ["DATA"])]
    print("statement lines executed: %d of %d (non-REM)" % (len([ln for ln in non_rem if ln in hits]), len(non_rem)))
    never = [ln for ln in non_rem if ln not in hits]
    if never:
        print("statements never executed: " + " ".join(map(str, never)))
    del all_lines
    if nonint:
        print("FINDING: non-integral values printed: %r" % nonint[:10])
        fail = True
    if bad:
        fail = True
    print("\nRESULT: %s" % ("PASS" if not fail else "FAIL"))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
