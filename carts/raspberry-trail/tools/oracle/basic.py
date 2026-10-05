#!/usr/bin/env python3
"""A small BASIC interpreter that runs reference/oregon.bas unmodified.

It implements exactly the CDC Cyber BASIC 3.1 subset the 1978 MECC listing
uses (SPEC.md section 6) and prints the oracle transcript (README.md):

    basic.py run <script>

The listing is parsed once and each line is compiled to a small Python
function. Expressions keep the listing's operator order (left to right,
normal precedence, nothing simplified), numbers are Python floats (IEEE
f64), and RND(-1) is the cart's rng.zig bit for bit, so a faithful engine
produces the same transcript byte for byte.

Python 3 standard library only.
"""
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LISTING = os.path.normpath(os.path.join(HERE, "..", "..", "reference", "oregon.bas"))
PATCHES = os.path.join(HERE, "patches.txt")

MASK = 0xFFFFFFFFFFFFFFFF
TWO_M53 = 2.0 ** -53


class Rng:
    """cart/src/game/rng.zig: splitmix64(seed) seeds xorshift64*."""

    __slots__ = ("state",)

    def __init__(self, seed):
        z = (seed + 0x9E3779B97F4A7C15) & MASK
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        z ^= z >> 31
        self.state = z if z != 0 else 1

    def next(self):
        x = self.state
        x ^= x >> 12
        x ^= (x << 25) & MASK
        x ^= x >> 27
        self.state = x
        return (x * 0x2545F4914F6CDD1D) & MASK

    def rnd(self):
        """One RND(-1): (next >> 11) * 2^-53, in [0, 1)."""
        return float(self.next() >> 11) * TWO_M53


# ---------------------------------------------------------------- prompts

# The INPUT statements by line number and the kind of answer each takes.
KINDS = {
    190: "yes_no", 5220: "yes_no", 5240: "yes_no", 5260: "yes_no",
    860: "number", 940: "number", 990: "number", 1040: "number",
    1090: "number", 2330: "number",
    760: "choice", 2100: "choice", 2180: "choice", 2770: "choice",
    3000: "choice",
    6220: "shoot",
}

# The variables of game.zig's Vars, in declaration order (the V line).
VARS = ("A B B1 B3 C C1 D D1 D3 D9 E F F1 F2 F9 K8 L1 M M1 M2 M9 P R1 "
        "S4 S5 S6 T T1 X X1").split()

# Outcome by the first of these lines executed (5120 decides by K8 when
# none of them ran first).
OUTCOME_LINES = {
    5470: "arrived", 5060: "starved", 5080: "no_doctor_money",
    5110: "no_medicine", 1690: "winter", 3520: "massacred",
    4260: "snakebite",
}

OUTCOMES = ("arrived", "starved", "no_doctor_money", "no_medicine",
            "pneumonia", "injuries", "winter", "massacred", "snakebite")

WRONG_WORD = "XXXX"
INT_RE = re.compile(r"-?[0-9]+$")


def fmt_var(x):
    """A V-line value: integral |x| < 2^53 as a decimal, else h + IEEE bits."""
    if math.isfinite(x) and x == math.floor(x) and abs(x) < 9007199254740992.0:
        return str(int(x))
    return "h" + struct.pack(">d", x).hex()


def collapse(s):
    return " ".join(s.split())


# ---------------------------------------------------------------- parsing

TOKEN_RE = re.compile(
    r'\s*(?:(?P<str>"(?:[^"]|"")*")'
    r"|(?P<num>[0-9]+\.?[0-9]*|\.[0-9]+)"
    r"|(?P<op>\*\*|<>|<=|>=|[-+*/(),;=<>])"
    r"|(?P<word>[A-Z][A-Z0-9]*\$?))")

FUNCS = ("RND", "INT", "CLK", "TAB")
KEYWORDS = ("THEN", "GOTO", "GOSUB")
REL_OPS = {"=": "==", "<>": "!=", "<": "<", ">": ">", "<=": "<=", ">=": ">="}


class BasicSyntaxError(Exception):
    pass


def tokenize(text, lineno):
    toks = []
    pos = 0
    text = text.rstrip()
    while pos < len(text):
        m = TOKEN_RE.match(text, pos)
        if not m or m.end() == pos:
            if text[pos:].strip() == "":
                break
            raise BasicSyntaxError("line %d: cannot tokenize at %r" % (lineno, text[pos:]))
        pos = m.end()
        if m.group("str") is not None:
            toks.append(("str", m.group("str")[1:-1].replace('""', '"')))
        elif m.group("num") is not None:
            toks.append(("num", m.group("num")))
        elif m.group("op") is not None:
            toks.append(("op", m.group("op")))
        else:
            toks.append(("word", m.group("word")))
    return toks


class Parser:
    """Compiles one statement's tokens to Python source."""

    def __init__(self, toks, lineno):
        self.t = toks
        self.i = 0
        self.ln = lineno

    def err(self, msg):
        raise BasicSyntaxError("line %d: %s (tokens %r)" % (self.ln, msg, self.t[self.i:]))

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else (None, None)

    def at(self, kind, val=None):
        tk, tv = self.peek()
        return tk == kind and (val is None or tv == val)

    def take(self, kind=None, val=None):
        tk, tv = self.peek()
        if tk is None or (kind is not None and tk != kind) or (val is not None and tv != val):
            self.err("expected %s %s" % (kind, val))
        self.i += 1
        return tv

    def done(self):
        return self.i >= len(self.t)

    # expressions return (python_source, type) with type "num", "str", "bool"
    def expr(self):
        a, ta = self.additive()
        tk, tv = self.peek()
        if tk == "op" and tv in REL_OPS:
            self.i += 1
            b, tb = self.additive()
            if (ta == "str") != (tb == "str"):
                self.err("type mismatch in comparison")
            return "(%s %s %s)" % (a, REL_OPS[tv], b), "bool"
        return a, ta

    def additive(self):
        a, ta = self.term()
        while self.at("op", "+") or self.at("op", "-"):
            op = self.take()
            b, tb = self.term()
            self.num(ta, tb)
            a = "(%s %s %s)" % (a, op, b)
        return a, ta

    def term(self):
        a, ta = self.unary()
        while self.at("op", "*") or self.at("op", "/"):
            op = self.take()
            b, tb = self.unary()
            self.num(ta, tb)
            a = "(%s %s %s)" % (a, op, b)
        return a, ta

    def unary(self):
        if self.at("op", "-"):
            self.take()
            a, ta = self.unary()
            self.num(ta)
            return "(-%s)" % a, "num"
        if self.at("op", "+"):
            self.take()
            return self.unary()
        return self.power()

    def power(self):
        a, ta = self.primary()
        while self.at("op", "**"):
            self.take()
            b, tb = self.primary()
            self.num(ta, tb)
            a = "_pow(%s, %s)" % (a, b)
        return a, ta

    def num(self, *types):
        for t in types:
            if t != "num":
                self.err("numeric operand expected")

    def primary(self):
        tk, tv = self.peek()
        if tk == "num":
            self.i += 1
            return repr(float(tv)), "num"
        if tk == "str":
            self.i += 1
            return repr(tv), "str"
        if tk == "op" and tv == "(":
            self.i += 1
            a, ta = self.expr()
            self.take("op", ")")
            return "(%s)" % a, ta
        if tk == "word":
            if tv in FUNCS:
                self.i += 1
                self.take("op", "(")
                arg, targ = self.expr()
                self.take("op", ")")
                self.num(targ)
                if tv == "RND":
                    return "I.rnd(%s)" % arg, "num"
                if tv == "INT":
                    return "_int(%s)" % arg, "num"
                if tv == "CLK":
                    return "I.clk(%s)" % arg, "num"
                self.err("TAB outside PRINT")
            return self.var_ref()
        self.err("unexpected token")

    def var_ref(self):
        name = self.take("word")
        if name in KEYWORDS or name in FUNCS:
            self.err("keyword used as variable")
        if name.endswith("$"):
            if self.at("op", "("):
                self.take()
                idx, ti = self.expr()
                self.take("op", ")")
                self.num(ti)
                return "I.sa[(%r, int(%s))]" % (name, idx), "str"
            return "I.s[%r]" % name, "str"
        if self.at("op", "("):
            self.err("numeric arrays are not used by the listing")
        self.names.add(name)
        return "v[%r]" % name, "num"

    def lvalue_ahead(self):
        """If the next thing is `NAME =` or `NAME$(expr) =`, returns
        (source, type, index after the =); consumes nothing."""
        save = self.i
        try:
            tk, tv = self.peek()
            if tk != "word" or tv in FUNCS or tv in KEYWORDS:
                return None
            src, ty = self.var_ref()
            if self.at("op", "="):
                return src, ty, self.i + 1
            return None
        except BasicSyntaxError:
            return None
        finally:
            self.i = save


def target_line(p):
    return int(p.take("num"))


def compile_statement(lineno, text, next_line, names):
    """Returns Python source lines (the body of the line's function)."""
    if text.split(None, 1)[:1] == ["REM"]:
        return ["pass"]
    toks = tokenize(text, lineno)
    p = Parser(toks, lineno)
    p.names = names
    if not toks:
        return ["pass"]
    kw = toks[0][1] if toks[0][0] == "word" else None
    body = []
    if kw == "REM":
        return ["pass"]
    if kw in ("DATA",):
        return ["pass"]
    if kw in ("STOP", "END"):
        return ["return I.stop()"]
    if kw == "DIM":
        return ["pass"]  # re-DIM is allowed and changes nothing here
    if kw == "RESTORE":
        return ["I.dp = 0"]
    if kw == "RETURN":
        return ["return I.ret()"]
    if kw == "GOTO":
        p.take()
        return ["return %d" % target_line(p)]
    if kw == "GOSUB":
        p.take()
        return ["return I.gosub(%d, %d)" % (next_line, target_line(p))]
    if kw == "READ":
        p.take()
        src, ty = p.var_ref()
        if ty != "num" or not p.done():
            p.err("READ of one numeric variable expected")
        return ["%s = I.read()" % src]
    if kw == "INPUT":
        p.take()
        name = p.take("word")
        if not p.done():
            p.err("INPUT of one variable expected")
        if lineno not in KINDS:
            p.err("INPUT line without a prompt kind")
        if not name.endswith("$"):
            names.add(name)
        return ["I.input(%d, %r)" % (lineno, name)]
    if kw == "IF":
        p.take()
        cond, ty = p.expr()
        if ty != "bool":
            p.err("IF needs a comparison")
        p.take("word", "THEN")
        tgt = target_line(p)
        if not p.done():
            p.err("junk after THEN line")
        return ["if %s: return %d" % (cond, tgt)]
    if kw == "ON":
        p.take()
        e, ty = p.expr()
        p.num(ty)
        p.take("word", "GOTO")
        tgts = [target_line(p)]
        while p.at("op", ","):
            p.take()
            tgts.append(target_line(p))
        if not p.done():
            p.err("junk after ON GOTO")
        return ["k = math.floor(%s)" % e,
                "if 1 <= k <= %d: return %r[k - 1]" % (len(tgts), tuple(tgts))]
    if kw == "PRINT":
        p.take()
        last_sep = None
        while not p.done():
            if p.at("op", ";"):
                p.take()
                last_sep = ";"
                continue
            if p.at("op", ","):
                p.take()
                body.append("I.zone()")
                last_sep = ","
                continue
            last_sep = None
            if p.at("word", "TAB"):
                p.take()
                p.take("op", "(")
                e, ty = p.expr()
                p.take("op", ")")
                p.num(ty)
                body.append("I.tab(%s)" % e)
                continue
            e, ty = p.expr()
            if ty == "str":
                body.append("I.ps(%s)" % e)
            elif ty == "num":
                body.append("I.pn(%s)" % e)
            else:
                p.err("cannot PRINT a comparison")
        if last_sep is None:
            body.append("I.nl()")
        return body
    # LET or implicit LET; multiple assignment A=B=...=expr assigns every name.
    if kw == "LET":
        p.take()
    targets = []
    while True:
        r = p.lvalue_ahead()
        if r is None:
            break
        targets.append(r[:2])
        p.i = r[2]
    if not targets:
        p.err("unknown statement")
    e, ty = p.expr()
    if not p.done():
        p.err("junk after assignment")
    for src, tty in targets:
        if tty != ty:
            p.err("type mismatch in assignment")
    body.append("val = %s" % e)
    for src, _ in targets:
        body.append("%s = val" % src)
    return body


def load_program(listing=LISTING, patches=PATCHES):
    lines = {}
    with open(listing) as f:
        for raw in f:
            raw = raw.rstrip("\r\n")
            if not raw.strip():
                continue
            m = re.match(r"\s*([0-9]+)\s?(.*)$", raw)
            if not m:
                raise BasicSyntaxError("no line number: %r" % raw)
            lines[int(m.group(1))] = m.group(2)
    n_patches = 0
    if patches:
        with open(patches) as f:
            for raw in f:
                raw = raw.rstrip("\r\n")
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                m = re.match(r"\s*([0-9]+)\s?(.*)$", raw)
                ln = int(m.group(1))
                if ln not in lines:
                    raise BasicSyntaxError("patch for missing line %d" % ln)
                lines[ln] = m.group(2)
                n_patches += 1
    return lines, n_patches


class Program:
    """The listing, parsed and compiled once."""

    def __init__(self, listing=LISTING, patches=PATCHES):
        src_lines, self.n_patches = load_program(listing, patches)
        self.numbers = sorted(src_lines)
        self.index = {ln: i for i, ln in enumerate(self.numbers)}
        self.text = src_lines
        self.data = []
        self.print_lines = []
        names = set()
        out = ["def _build(math, _int, _pow):", "    fns = []"]
        for i, ln in enumerate(self.numbers):
            text = src_lines[ln]
            nxt = self.numbers[i + 1] if i + 1 < len(self.numbers) else -1
            word = text.split(None, 1)[0] if text.strip() else ""
            if word == "DATA":
                for tk, tv in tokenize(text, ln)[1:]:
                    if tk == "num":
                        self.data.append(float(tv))
                    elif not (tk == "op" and tv == ","):
                        raise BasicSyntaxError("line %d: bad DATA" % ln)
            if word == "PRINT":
                self.print_lines.append(ln)
            body = compile_statement(ln, text, nxt, names)
            pre = []
            if ln in OUTCOME_LINES:
                pre.append("I.mark(%r)" % OUTCOME_LINES[ln])
            if ln == 5120:
                pre.append("I.mark('injuries' if v['K8'] == 1.0 else 'pneumonia')")
            out.append("    def L%d(I, v):" % ln)
            for s in pre + body:
                out.append("        " + s)
            out.append("    fns.append(L%d)" % ln)
        out.append("    return fns")
        self.source = "\n".join(out) + "\n"
        ns = {}
        exec(compile(self.source, "<oregon.bas>", "exec"), ns)
        self.fns = ns["_build"](math, _int, _pow)
        self.var_names = sorted(names)


def _int(x):
    return float(math.floor(x))


def _pow(a, b):
    """`**`. Integral exponents 0..16 multiply out left to right (so X**2
    is exactly X*X, the correctly rounded square); others use pow()."""
    if b == math.floor(b) and 0 <= b <= 16:
        n = int(b)
        if n == 0:
            return 1.0
        r = a
        for _ in range(n - 1):
            r = r * a
        return r
    return math.pow(a, b)


_PROGRAM = None


def program():
    global _PROGRAM
    if _PROGRAM is None:
        _PROGRAM = Program()
    return _PROGRAM


# ---------------------------------------------------------------- running

class Stop(Exception):
    pass


class Eof(Exception):
    pass


class Mismatch(Exception):
    def __init__(self, line):
        Exception.__init__(self, line)
        self.line = line


class StepLimit(Exception):
    pass


_STOP = object()


class Interp:
    """One run of the program. `answer_fn(interp, line, kind)` returns the
    answer token string for each INPUT (script or fuzz policy)."""

    MAX_STEPS = 5_000_000

    def __init__(self, seed, answer_fn, prog=None, warn=None):
        self.prog = prog or program()
        self.rng = Rng(seed)
        self.answer_fn = answer_fn
        self.v = {name: 0.0 for name in set(VARS) | set(self.prog.var_names)}
        self.s = {}
        self.sa = {}
        self.dp = 0
        self.stack = []
        self.buf = []
        self.col = 0
        self.out = []
        self.answers = []
        self.outcome = None
        self.ended = None  # "E", "eof", "mismatch"
        self.clk_val = 0.0
        self.hits = set()
        self.n_rnd = 0
        self.warn = warn or (lambda msg: sys.stderr.write(msg + "\n"))
        self.nonint = []

    # --- builtins used by compiled lines
    def rnd(self, _arg):
        self.n_rnd += 1
        return self.rng.rnd()

    def clk(self, _arg):
        # 0 at the shot's first call (6210); secs/3600 at the second (6230),
        # set by the INPUT at 6220 from the script's SHOOT answer.
        val = self.clk_val
        self.clk_val = 0.0
        return val

    def read(self):
        if self.dp >= len(self.prog.data):
            raise BasicSyntaxError("out of DATA")
        x = self.prog.data[self.dp]
        self.dp += 1
        return x

    def gosub(self, ret_line, target):
        self.stack.append(ret_line)
        return target

    def ret(self):
        return self.stack.pop()

    def mark(self, outcome):
        if self.outcome is None:
            self.outcome = outcome

    def stop(self):
        self.flush()
        self.out.append("E %s" % (self.outcome or "none"))
        self.ended = "E"
        return _STOP

    # --- PRINT
    def ps(self, s):
        self.buf.append(s)
        self.col += len(s)

    def pn(self, x):
        # BASIC 3.1: a sign position (blank or -), the digits, a blank.
        if math.isfinite(x) and x == math.floor(x):
            digits = str(abs(int(x)))
            s = ("-" if x < 0 else " ") + digits + " "
        else:
            s = " " + repr(x) + " "
            self.nonint.append((self.cur_line, x))
            self.warn("FINDING: line %d printed a non-integral value %r" % (self.cur_line, x))
        self.ps(s)

    def zone(self):
        nxt = (self.col // 15 + 1) * 15
        self.ps(" " * (nxt - self.col))

    def tab(self, n):
        n = int(math.floor(n))
        if n > self.col:
            self.ps(" " * (n - self.col))

    def nl(self):
        text = collapse("".join(self.buf))
        if text:
            self.out.append("T " + text)
        self.buf = []
        self.col = 0

    def flush(self):
        if self.buf:
            self.nl()

    # --- INPUT
    def vars_line(self):
        v = self.v
        return "V " + " ".join("%s=%s" % (n, fmt_var(v[n])) for n in VARS)

    def input(self, line, name):
        self.flush()
        kind = KINDS[line]
        self.out.append("P %d %s" % (line, kind))
        self.out.append(self.vars_line())
        tok = self.answer_fn(self, line, kind)
        if tok is None:
            raise Eof()
        tok = " ".join(tok.split())
        if kind == "yes_no":
            if tok not in ("YES", "NO"):
                raise Mismatch(line)
            self.s[name] = tok
        elif kind in ("number", "choice"):
            if not INT_RE.match(tok):
                raise Mismatch(line)
            self.v[name] = float(int(tok))
        else:  # shoot
            parts = tok.split(" ")
            if len(parts) != 3 or parts[0] != "SHOOT" or parts[1] not in ("0", "1"):
                raise Mismatch(line)
            try:
                secs = float(parts[2])
            except ValueError:
                raise Mismatch(line)
            word = self.sa.get(("S$", int(self.v["S6"])), "")
            self.s[name] = word if parts[1] == "1" else WRONG_WORD
            self.clk_val = secs / 3600
        self.answers.append(tok)
        self.out.append("I " + tok)

    # --- main loop
    def run(self):
        prog = self.prog
        fns = prog.fns
        numbers = prog.numbers
        index = prog.index
        hits = self.hits
        v = self.v
        pc = 0
        n = len(fns)
        steps = 0
        try:
            while pc < n:
                ln = numbers[pc]
                self.cur_line = ln
                hits.add(ln)
                r = fns[pc](self, v)
                steps += 1
                if r is None:
                    pc += 1
                elif r is _STOP:
                    return self
                else:
                    pc = index[r]
                if steps > self.MAX_STEPS:
                    raise StepLimit()
            self.stop()  # ran off the end: END
        except Eof:
            self.out.append("X eof")
            self.ended = "eof"
        except Mismatch as e:
            self.out.append("X mismatch %d" % e.line)
            self.ended = "mismatch"
        return self


# ---------------------------------------------------------------- scripts

class ScriptError(Exception):
    pass


def parse_script(text):
    """Returns (seed, [answer tokens])."""
    seed = None
    answers = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if seed is None:
            parts = line.split()
            if len(parts) != 2 or parts[0] != "seed":
                raise ScriptError("first line must be `seed <u64>`: %r" % line)
            seed = int(parts[1])
            if not 0 <= seed <= MASK:
                raise ScriptError("seed out of u64 range")
            continue
        answers.append(" ".join(line.split()))
    if seed is None:
        raise ScriptError("no seed line")
    return seed, answers


def run_answers(seed, answers, prog=None, warn=None):
    it = iter(answers)

    def answer_fn(_interp, _line, _kind):
        return next(it, None)

    return Interp(seed, answer_fn, prog=prog, warn=warn).run()


def run_script_text(text, prog=None, warn=None):
    seed, answers = parse_script(text)
    return run_answers(seed, answers, prog=prog, warn=warn)


def exit_code(interp):
    return 2 if interp.ended == "mismatch" else 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "run":
        with open(argv[1]) as f:
            text = f.read()
        it = run_script_text(text)
        sys.stdout.write("\n".join(it.out) + "\n")
        return exit_code(it)
    if len(argv) == 3 and argv[0] == "rng":
        r = Rng(int(argv[1]))
        for _ in range(int(argv[2])):
            x = r.rnd()
            print(struct.pack(">d", x).hex(), repr(x))
        return 0
    if argv and argv[0] == "source":
        sys.stdout.write(program().source)
        return 0
    sys.stderr.write("usage: basic.py run <script>\n"
                     "       basic.py rng <seed> <n>   (first RND draws, IEEE bits)\n"
                     "       basic.py source          (the compiled listing)\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
