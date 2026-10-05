#!/usr/bin/env python3
"""Writes the named answer scripts in scripts/ from the scenarios below.

Each scenario gives answers queued per INPUT line (consumed first, in
order, whenever that INPUT comes up), a steady policy for everything
else, and a goal (the outcome and listing lines the game must reach). The
seed search tries seeds from 1 up until the goal holds, then writes the
script with each answer annotated by its prompt.

    mkscripts.py            # (re)write every scripts/*.txt it defines
    mkscripts.py --check    # verify the committed scripts still reach their goals
    mkscripts.py NAME ...   # only these scenarios
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import basic  # noqa: E402

SCRIPTS = os.path.join(HERE, "scripts")

LABELS = {
    190: "need instructions?", 760: "marksman (1-5)", 860: "oxen $",
    940: "food $", 990: "ammunition $", 1040: "clothing $",
    1090: "misc. supplies $", 2100: "(1) fort (2) hunt (3) continue",
    2180: "(1) hunt (2) continue", 2330: "fort purchase $",
    2770: "eat (1) poorly (2) moderately (3) well",
    3000: "riders: (1) run (2) attack (3) continue (4) circle",
    5220: "minister?", 5240: "fancy funeral?", 5260: "inform next of kin?",
}
SHOT_REASON = {2590: "hunt", 3130: "riders attack", 3300: "riders circle",
               3980: "bandits", 4360: "wild animals"}
SAFE = {2100: "3", 2180: "2", 2770: "1", 3000: "3"}
FORT_ITEM = {2320: "food", 2440: "ammunition", 2470: "clothing", 2500: "misc. supplies"}


class Steady:
    """A plain player for the rest of a scenario's game."""

    def __init__(self, rnd, eat=(2,), hunt=0.3, fort=0.3, tactic=None,
                 shot=(1, 0.4, 1.5), fort_spend=0.5, never_hunt=False):
        self.r = rnd
        self.eat = eat
        self.hunt = hunt
        self.fort = fort
        self.tactic = tactic
        self.shot = shot
        self.fort_spend = fort_spend
        self.never_hunt = never_hunt

    def __call__(self, it, line):
        r = self.r
        v = it.v
        if line in (190, 5220, 5240, 5260):
            return r.choice(["YES", "NO"])
        if line == 760:
            return "3"
        if line == 860:
            return "250"
        if line in (940, 990, 1040, 1090):
            return {940: "150", 990: "60", 1040: "90", 1090: "100"}[line]
        if line == 2100:
            if not self.never_hunt and v["F"] < 50 and v["B"] > 39:
                return "2"
            if r.random() < self.fort and v["T"] > 0:
                return "1"
            if not self.never_hunt and r.random() < self.hunt and v["B"] > 39:
                return "2"
            return "3"
        if line == 2180:
            if not self.never_hunt and v["B"] > 39 and (v["F"] < 50 or r.random() < self.hunt):
                return "1"
            return "2"
        if line == 2330:
            return str(int(max(0, v["T"]) * self.fort_spend / 4))
        if line == 2770:
            return str(r.choice(self.eat))
        if line == 3000:
            return str(self.tactic or r.randint(1, 4))
        if line == 6220:
            ok, lo, hi = self.shot
            return "SHOOT %d %.2f" % (ok, r.uniform(lo, hi))
        raise AssertionError(line)


class Scenario:
    def __init__(self, name, doc, queues=None, outcome=None, lines=(),
                 steady=None, stop_after=None, max_seed=200000, first_seed=1):
        self.name = name
        self.doc = doc
        self.queues = queues or {}
        self.outcome = outcome
        self.lines = tuple(lines)
        self.steady = steady or {}
        self.stop_after = stop_after  # answers; the script ends early (X eof)
        self.max_seed = max_seed
        self.first_seed = first_seed

    def play(self, seed):
        queues = {k: list(v) for k, v in self.queues.items()}
        steady = Steady(random.Random("%s:%d" % (self.name, seed)), **self.steady)
        notes = []
        run = [None, 0]  # the last INPUT line and how often in a row

        def answer(it, line, kind):
            if self.stop_after is not None and len(notes) >= self.stop_after:
                return None
            run[1] = run[1] + 1 if run[0] == line else 0
            run[0] = line
            q = queues.get(line)
            if q:
                tok = q.pop(0)
            elif run[1] >= 3 and line in SAFE:
                tok = SAFE[line]  # out of a re-ask loop
            else:
                tok = steady(it, line)
            notes.append((line, kind, tok, note(it, line)))
            return tok

        it = basic.Interp(seed, answer, warn=lambda m: None)
        it.run()
        return it, notes, queues

    def ok(self, it, queues):
        if any(queues.values()):
            return False  # every queued answer must have been used
        if self.stop_after is None and it.ended != "E":
            return False
        if self.outcome and it.outcome != self.outcome:
            return False
        return all(ln in it.hits for ln in self.lines)

    def search(self):
        for seed in range(self.first_seed, self.first_seed + self.max_seed):
            it, notes, queues = self.play(seed)
            if self.ok(it, queues):
                return seed, it, notes
        raise SystemExit("%s: no seed reaches the goal in %d tries" % (self.name, self.max_seed))


def note(it, line):
    if line == 6220:
        word = it.sa.get(("S$", int(it.v["S6"])), "?")
        ret = it.stack[-1] if it.stack else 0
        return "shot: TYPE %s (%s)" % (word, SHOT_REASON.get(ret, "?"))
    if line == 2330:
        ret = it.stack[-1] if it.stack else 0
        return "fort: %s $ (cash %s)" % (FORT_ITEM.get(ret, "?"), basic.fmt_var(it.v["T"]))
    return LABELS[line]


def render(sc, seed, it, notes):
    out = ["seed %d" % seed]
    for d in sc.doc.strip().splitlines():
        out.append("# " + d if d.strip() else "#")
    goal = []
    if sc.outcome:
        goal.append("outcome %s" % sc.outcome)
    if sc.lines:
        goal.append("lines " + " ".join(map(str, sc.lines)))
    out.append("# goal: %s; ends: %s" % ("; ".join(goal) or "-", it.out[-1]))
    out.append("# written by mkscripts.py (scenario %r)" % sc.name)
    for line, kind, tok, why in notes:
        out.append("# %d %s" % (line, why))
        out.append(tok)
    return "\n".join(out) + "\n"


Q = Scenario
SCENARIOS = [
    Q("instructions-invalid-purchases",
      """Instructions, a marksman claim above 5 (line 790 makes it 0), and
every invalid opening purchase: NOT ENOUGH and TOO MUCH for the oxen,
IMPOSSIBLE for each item, then YOU OVERSPENT and buying again.""",
      queues={190: ["YES"], 760: ["7"],
              860: ["150", "-20", "301", "1000", "250", "260"],
              940: ["-1", "200", "120"], 990: ["-5", "100", "80"],
              1040: ["-100", "100", "80"], 1090: ["-1", "150", "100"]},
      lines=(790, 880, 910, 960, 1010, 1060, 1110, 1150)),
    Q("hunt-without-bullets",
      """No ammunition: TOUGH---YOU NEED MORE BULLETS from the hunt-or-continue
menu (line 2240, which asks again) and from the fort menu (line 2550, which
goes back to line 2080 and asks the fort question again without flipping
the fort flag X1).""",
      queues={190: ["NO"], 760: ["2"], 860: ["220"], 940: ["300"], 990: ["0"],
              1040: ["100"], 1090: ["80"], 2180: ["1", "1", "2"], 2100: ["2", "2", "3"]},
      lines=(2240, 2550), steady={"never_hunt": True}),
    Q("fort-overspend",
      """Fort stops: spending more than the cash left (YOU DON'T HAVE THAT
MUCH, YOU MISS YOUR CHANCE), a negative amount (skips the cash check but
still adds 2/3 of it to the item), and normal purchases.""",
      queues={190: ["NO"], 760: ["3"], 860: ["240"], 940: ["120"], 990: ["50"],
              1040: ["60"], 1090: ["80"], 2100: ["1", "1"],
              2330: ["500", "-30", "40", "10", "20", "20", "999", "5"]},
      lines=(2290, 2370, 2375)),
    Q("eat-too-well",
      """Little food: eating well is refused (YOU CAN'T EAT THAT WELL, asks
again), the low food warning, and then starving (never hunting).""",
      queues={190: ["NO"], 760: ["3"], 860: ["300"], 940: ["20"], 990: ["50"],
              1040: ["100"], 1090: ["100"], 2770: ["3", "9", "0", "2"]},
      outcome="starved", lines=(2840, 1840),
      steady={"never_hunt": True, "eat": (3,)}),
    Q("hunting-loop",
      """Hunting every turn with fast, slow and wrong-word shots: the big
one (B1 <= 1), a nice shot, and missing.""",
      queues={190: ["NO"], 760: ["1"], 860: ["250"], 940: ["60"], 990: ["200"],
              1040: ["90"], 1090: ["100"]},
      lines=(2660, 2620, 2710),
      steady={"hunt": 1.0, "fort": 0.0, "shot": (1, 0.2, 4.0)}),
    Q("fort-loop",
      """Stopping at every fort that comes up (every other turn) and
spending there.""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["150"], 990: ["40"],
              1040: ["60"], 1090: ["50"]},
      lines=(2290,), outcome="arrived",
      steady={"fort": 1.0, "hunt": 0.0, "fort_spend": 0.6}),
    Q("riders-run",
      """Riders: (1) RUN, both against hostile riders (M+20, oxen A-40,
supplies and bullets lost) and friendly ones (M+15, A-10).""",
      lines=(3060, 3340), steady={"tactic": 1}),
    Q("riders-attack",
      """Riders: (2) ATTACK, hostile (a shot: drove them off, kinda slow
or knifed) and friendly (M-5, B-100).""",
      lines=(3120, 3380), steady={"tactic": 2}),
    Q("riders-continue",
      """Riders: (3) CONTINUE, hostile (may not attack: THEY DID NOT
ATTACK) and friendly.""",
      lines=(3260, 3420, 3450), steady={"tactic": 3}),
    Q("riders-circle",
      """Riders: (4) CIRCLE WAGONS, hostile (a shot, M-25) and friendly
(M-20).""",
      lines=(3290, 3430), steady={"tactic": 4}),
    Q("riders-knifed",
      """Attacking hostile riders with a slow shot: LOUSY SHOT---YOU GOT
KNIFED, then the doctor's bill.""",
      lines=(3180, 1970), steady={"tactic": 2, "shot": (1, 6.0, 9.0)}),
    Q("riders-invalid-tactic",
      """Out-of-range tactics (0, 5, 9) make the riders menu ask again.""",
      queues={3000: ["0", "5", "9", "3"]}, lines=(2900,)),
    Q("bandits-out-of-bullets",
      """Bandits with almost no bullets: THEY GET LOTS OF CASH (T=T/3),
shot in the leg, an ox taken.""",
      queues={190: ["NO"], 760: ["5"], 860: ["250"], 940: ["150"], 990: ["1"],
              1040: ["90"], 1090: ["100"]},
      lines=(4000, 4040), steady={"never_hunt": True, "shot": (0, 1.0, 2.0)}),
    Q("death-starved",
      """Death: YOU RAN OUT OF FOOD AND STARVED TO DEATH.""",
      queues={190: ["NO"], 760: ["3"], 860: ["300"], 940: ["40"], 990: ["50"],
              1040: ["100"], 1090: ["100"]},
      outcome="starved", steady={"never_hunt": True, "eat": (3,)}),
    Q("death-no-doctor-money",
      """Death: no cash left, then an injury or serious illness:
YOU CAN'T AFFORD A DOCTOR, YOU DIED OF ...""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["200"], 990: ["50"],
              1040: ["100"], 1090: ["100"]},
      outcome="no_doctor_money", lines=(5090,)),
    Q("death-no-medicine",
      """Death: almost no miscellaneous supplies, then illness:
YOU RAN OUT OF MEDICAL SUPPLIES, YOU DIED OF PNEUMONIA.""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["200"], 990: ["50"],
              1040: ["100"], 1090: ["2"]},
      outcome="no_medicine", lines=(5140,), steady={"eat": (1,)}),
    Q("death-no-medicine-injured",
      """Death by no medicine after an injury (K8=1): YOU DIED OF INJURIES
(line 5160).""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["150"], 990: ["50"],
              1040: ["100"], 1090: ["6"]},
      outcome="no_medicine", lines=(5160,), steady={"shot": (0, 1, 2)}),
    Q("death-winter",
      """Death: still on the trail at turn 20 (MONDAY YOU HAVE BEEN ON THE
TRAIL TOO LONG, the blizzard of winter). Cheap oxen, hunting or a fort
every turn.""",
      queues={190: ["NO"], 760: ["1"], 860: ["200"], 940: ["120"], 990: ["150"],
              1040: ["80"], 1090: ["110"]},
      outcome="winter", lines=(1650, 1670),
      steady={"hunt": 1.0, "fort": 0.5, "eat": (2, 3), "tactic": 1,
              "shot": (1, 0.1, 1.0), "fort_spend": 0.3}),
    Q("death-massacred",
      """Death: few bullets and hostile riders: YOU RAN OUT OF BULLETS AND
GOT MASSACRED BY THE RIDERS.""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["200"], 990: ["2"],
              1040: ["100"], 1090: ["100"]},
      outcome="massacred", steady={"tactic": 1, "never_hunt": True}),
    Q("death-snakebite",
      """Death: bitten with too few supplies: YOU DIE OF SNAKEBITE SINCE
YOU HAVE NO MEDICINE.""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["200"], 990: ["50"],
              1040: ["100"], 1090: ["3"]},
      outcome="snakebite", steady={"eat": (3,)}),
    Q("death-wolves",
      """Death: wild animals with fewer than 40 bullets: THE WOLVES
OVERPOWERED YOU, YOU DIED OF INJURIES.""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["200"], 990: ["0"],
              1040: ["100"], 1090: ["100"]},
      outcome="injuries", lines=(4370, 5160), steady={"never_hunt": True, "tactic": 3}),
    Q("arrival",
      """A full trip: buying well, hunting when food runs low, and arriving
at Oregon City (the final-turn fraction, the weekday and the date, the
closing table and President Polk's letter).""",
      queues={190: ["YES"], 760: ["2"], 860: ["300"], 940: ["200"], 990: ["60"],
              1040: ["100"], 1090: ["40"]},
      outcome="arrived", lines=(4970, 2020), steady={"eat": (2, 3)}),
    Q("arrival-mountain-quirks",
      """Arrival through the mountains with the South Pass safe (no snow),
getting lost and the TOTAL MILEAGE IS 950 display quirk (M9).""",
      outcome="arrived", lines=(4890, 4750, 2020)),
    Q("arrival-cold",
      """Arrival after cold weather without enough clothing (DON'T HAVE
ENOUGH CLOTHING, then the illness subroutine).""",
      queues={190: ["NO"], 760: ["3"], 860: ["280"], 940: ["200"], 990: ["60"],
              1040: ["10"], 1090: ["120"]},
      outcome="arrived", lines=(4510,)),
    Q("edge-numbers",
      """Numbers the badge UI cannot enter but the listing takes: a negative
marksman claim (D9=-3 makes every shot 4 s slower), an oxen amount beyond
32 bits, a leading plus sign, negative and large menu choices (2180: not 1
means continue; 2100: out of range means continue; eating and riders ask
again).""",
      queues={190: ["NO"], 760: ["-3"], 860: ["99999999999", "+260"],
              940: ["150"], 990: ["80"], 1040: ["90"], 1090: ["100"],
              2180: ["-1", "200"], 2100: ["-5", "300"], 2770: ["-1", "255", "2"],
              3000: ["-2", "3"]},
      lines=(910, 2900)),
    Q("format-eof",
      """Transcript format: the script ends before the game does (X eof).""",
      queues={190: ["NO"], 760: ["3"], 860: ["250"], 940: ["150"]}, stop_after=4),
]


def write_mismatch():
    """format-mismatch.txt: a SHOOT answer at the oxen prompt (X mismatch)."""
    text = ("seed 5\n# Transcript format: an answer of the wrong kind (SHOOT at the oxen\n"
            "# number prompt) gives X mismatch 860 and exit status 2.\n"
            "NO\n3\nSHOOT 1 0.5\n")
    return text


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args(argv)
    os.makedirs(SCRIPTS, exist_ok=True)
    chosen = [s for s in SCENARIOS if not a.names or s.name in a.names]
    bad = 0
    for sc in chosen:
        path = os.path.join(SCRIPTS, sc.name + ".txt")
        if a.check:
            with open(path) as f:
                seed, answers = basic.parse_script(f.read())
            it = basic.run_answers(seed, answers, warn=lambda m: None)
            ok = (it.ended == ("eof" if sc.stop_after is not None else "E")
                  and (not sc.outcome or it.outcome == sc.outcome)
                  and all(ln in it.hits for ln in sc.lines))
            print("%s %s" % ("ok  " if ok else "FAIL", sc.name))
            bad += not ok
            continue
        seed, it, notes = sc.search()
        with open(path, "w") as f:
            f.write(render(sc, seed, it, notes))
        print("%-34s seed %-6d %3d answers  %s" % (sc.name, seed, len(notes), it.out[-1]))
    if not a.names or "format-mismatch" in a.names:
        path = os.path.join(SCRIPTS, "format-mismatch.txt")
        if a.check:
            it = basic.run_script_text(open(path).read(), warn=lambda m: None)
            ok = it.out[-1] == "X mismatch 860"
            print("%s format-mismatch" % ("ok  " if ok else "FAIL"))
            bad += not ok
        else:
            with open(path, "w") as f:
                f.write(write_mismatch())
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
