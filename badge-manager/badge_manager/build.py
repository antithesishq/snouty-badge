"""Cart builds on disk (PLAN.md 9.2), shared by the server and the `badge` CLI.

A job lives in <library>/builds/<id>/, id = YYYYMMDD-HHMMSS-<slug>:

  job.json     {id, prompt, name, title, where, host, state, started, finished,
                seconds, exit, error, result, no_agent, pid}
  job.log      the build's output, one line per event, appended while it runs
  prompt.txt   the request (passed by file or stdin, never in argv)
  out/         what build-job.sh produced: <name>.uf2, preview.gif, bench.txt,
               summary.json, cart.tar.gz
  cancel       present once someone asked to cancel

<library>/builds/.lock is an flock held for the whole job, so one job runs at a
time whichever process started it. Jobs.create() takes the lock and writes the
queued job; Jobs.run() runs it in the calling thread and releases the lock.
The command, in order: config.build_command (a template), local build-job.sh,
or build-job.sh over ssh on config.build_host followed by a tar of out/ back
and an rm on the host. On exit 0 the UF2 is gated with tools/uf2_info.py,
copied into carts/ and registered in the manifest with build = <id>.
"""
from __future__ import annotations
import contextlib
import fcntl
import json
import os
import pwd
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Callable

from .config import Config

STATES = ("queued", "running", "done", "failed", "cancelled")
ACTIVE = ("queued", "running")
WHERE = ("local", "remote")
MAX_PROMPT = 2000
LOG_LINE_MAX = 300
KILL_GRACE_S = 3.0            # SIGTERM, then SIGKILL this much later
SSH_STEP_S = 120              # timeout for the fetch, cleanup and cancel ssh calls
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new"]
SSH_KEY = Path("/home/badge/.ssh/id_ed25519")
PACKAGE_ROOT = Path(__file__).resolve().parents[1]           # badge-manager/
UF2_INFO = PACKAGE_ROOT.parent / "tools" / "uf2_info.py"     # skipped when missing
REPO_CARTS = PACKAGE_ROOT.parent / "carts"                   # names a new cart must avoid
BUILD_JOB_SH = "badge-manager/build-job.sh"                  # relative to build_repo
OUT_FILES = ("preview.gif", "preview.png", "bench.txt", "summary.json")
ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9][a-z0-9-]{0,30}$")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{2,23}$")
PREFIX = "snouty-"
STOP_WORDS = {"a", "an", "the", "snouty", "cart", "game", "where", "which", "that", "with",
              "of", "in", "on", "and", "or", "is", "it", "its", "to", "for", "make", "me",
              "write", "please", "you", "can", "who", "some", "my", "about", "like"}
EXIT_TEXT = {2: "bad request or cart name", 3: "the cart does not build",
             4: "the agent failed or ran out of turns or budget", 124: "ran out of time",
             127: "the build script is missing", 130: "cancelled",
             255: "could not reach the build host"}


class BuildError(Exception):
    pass


class BuildBusy(BuildError):
    pass


@dataclass
class Job:
    id: str
    prompt: str
    name: str
    where: str                           # "local" | "remote"
    host: str | None = None
    title: str | None = None
    state: str = "queued"
    started: float = 0.0                 # epoch seconds
    finished: float | None = None
    seconds: float | None = None
    exit: int | None = None
    error: str | None = None
    result: dict | None = None           # {cart, uf2, size, preview, bench_ms, branch}
    no_agent: bool = False
    pid: int | None = None               # process group of the running command

    @classmethod
    def from_dict(cls, d: dict) -> "Job":
        names = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in names})

    def elapsed(self) -> float:
        if self.seconds is not None:
            return self.seconds
        return max(0.0, time.time() - self.started) if self.started else 0.0


# -- names ------------------------------------------------------------------

def cart_name(prompt: str, name: str | None = None, taken: set[str] = frozenset()) -> str:
    """NAME (prefixed with snouty- when missing) or a name from the prompt's first words.

    Raises BuildError when NAME does not match [a-z][a-z0-9-]{2,23}. A name made from the
    prompt avoids TAKEN by adding -2, -3, ..."""
    if name:
        name = name.strip().lower()
        if not name.startswith(PREFIX):
            name = PREFIX + name
        if not NAME_RE.match(name) or name.endswith("-") or "--" in name:
            raise BuildError(f"bad cart name {name!r}: 3 to 24 of a-z, 0-9 and -, "
                             "starting with a letter")
        return name
    words = [w for w in re.findall(r"[a-z0-9]+", prompt.lower())
             if len(w) > 1 and w not in STOP_WORDS]
    slug = ""
    for w in words[:3]:
        cand = f"{slug}-{w}" if slug else w
        if len(PREFIX) + len(cand) > 20:
            break
        slug = cand
    base = PREFIX + (slug or "cart")[:17].strip("-")
    out, n = base, 2
    while out in taken:
        out, n = f"{base}-{n}", n + 1
    return out


def slug_of(name: str) -> str:
    return name[len(PREFIX):] if name.startswith(PREFIX) and len(name) > len(PREFIX) else name


def repo_carts() -> set[str]:
    """Cart directory names in this checkout, when there is one next to the package."""
    try:
        return {p.name for p in REPO_CARTS.iterdir() if p.is_dir()}
    except OSError:
        return set()


# -- the job store and runner --------------------------------------------------

class Jobs:
    def __init__(self, library: Path, config: Config,
                 on_change: Callable[[], None] | None = None,
                 register: Callable[[Path, str, str, str], None] | None = None):
        """ON_CHANGE runs after every log line and state change (the station's long poll).
        REGISTER(uf2, name, title, id) puts a finished cart into the library."""
        self.library = Path(library)
        self.root = self.library / "builds"
        self.config = config
        self.on_change = on_change
        self.register = register or self._register
        self._fds: dict[str, int] = {}
        self._procs: dict[str, subprocess.Popen] = {}

    # -- paths and locking ------------------------------------------------

    def dir(self, job_id: str) -> Path:
        return self.root / job_id

    def _lock_path(self) -> Path:
        return self.root / ".lock"

    def _acquire(self) -> int:
        self.root.mkdir(parents=True, exist_ok=True)
        fd = os.open(self._lock_path(), os.O_RDWR | os.O_CREAT, 0o666)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            cur = self.current()
            raise BuildBusy(f"a build is running ({cur.id})" if cur else "a build is running")
        return fd

    def locked(self) -> bool:
        """True while some process (this one included) holds builds/.lock."""
        try:
            fd = os.open(self._lock_path(), os.O_RDONLY)
        except OSError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except OSError:
            return True
        finally:
            os.close(fd)

    def _release(self, job_id: str) -> None:
        fd = self._fds.pop(job_id, None)
        if fd is not None:
            os.close(fd)

    # -- reading ----------------------------------------------------------

    def get(self, job_id: str) -> Job | None:
        if not job_id or not ID_RE.match(job_id):
            return None
        try:
            job = Job.from_dict(json.loads((self.dir(job_id) / "job.json").read_text()))
        except (OSError, ValueError, TypeError):
            return None
        if job.state in ACTIVE and job_id not in self._fds and not self.locked():
            job.state, job.error = "failed", "the station stopped during this build"
        return job

    def ids(self) -> list[str]:
        """Job ids, newest first."""
        try:
            names = [p.name for p in self.root.iterdir() if ID_RE.match(p.name)]
        except OSError:
            return []
        return sorted(names, reverse=True)

    def list(self, n: int = 10) -> list[Job]:
        out = []
        for i in self.ids():
            job = self.get(i)
            if job:
                out.append(job)
                if len(out) >= n:
                    break
        return out

    def current(self) -> Job | None:
        """The job that is queued or running, else None."""
        for i in self.ids()[:1]:
            job = self.get(i)
            if job and job.state in ACTIVE:
                return job
        return None

    def latest(self) -> Job | None:
        jobs = self.list(1)
        return jobs[0] if jobs else None

    def log(self, job_id: str) -> list[str]:
        try:
            return (self.dir(job_id) / "job.log").read_text(errors="replace").splitlines()
        except OSError:
            return []

    def tail(self, job_id: str, n: int = 40) -> list[str]:
        return self.log(job_id)[-n:]

    def file(self, job_id: str, name: str) -> Path | None:
        """out/NAME of a job, for NAME in OUT_FILES only; None otherwise."""
        if name not in OUT_FILES or not ID_RE.match(job_id or ""):
            return None
        p = self.dir(job_id) / "out" / name
        return p if p.is_file() and not p.is_symlink() else None

    # -- writing ----------------------------------------------------------

    def _save(self, job: Job) -> None:
        d = self.dir(job.id)
        tmp = d / "job.json.tmp"
        tmp.write_text(json.dumps(asdict(job), indent=1) + "\n")
        tmp.replace(d / "job.json")
        self._changed()

    def _changed(self) -> None:
        if self.on_change:
            self.on_change()

    def _line(self, job: Job, text: str, on_line: Callable[[str], None] | None) -> None:
        text = text.rstrip()[:LOG_LINE_MAX]
        with open(self.dir(job.id) / "job.log", "a") as fh:
            fh.write(text + "\n")
        if on_line:
            on_line(text)
        self._changed()

    # -- creating and running -----------------------------------------------

    def create(self, prompt: str, where: str, name: str | None = None,
               no_agent: bool = False, taken: set[str] = frozenset()) -> Job:
        """Take the build lock and write a queued job. Raises BuildBusy, BuildError."""
        prompt = (prompt or "").strip()
        if not prompt:
            raise BuildError("the prompt is empty")
        if len(prompt) > MAX_PROMPT:
            raise BuildError(f"the prompt is too long ({len(prompt)} of {MAX_PROMPT} characters)")
        if where not in WHERE:
            raise BuildError(f"where must be local or remote, not {where!r}")
        name = cart_name(prompt, name, set(taken) | repo_carts())
        fd = self._acquire()
        try:
            job_id = self._new_id(name)
            d = self.dir(job_id)
            (d / "out").mkdir(parents=True)
            if where == "local" and os.geteuid() == 0:
                if not self.config.build_user:
                    raise BuildError("local builds need build_user when the station runs as root")
                account = pwd.getpwnam(self.config.build_user)
                os.chown(d / "out", account.pw_uid, account.pw_gid)
                (d / "out").chmod(0o700)
            (d / "prompt.txt").write_text(prompt + "\n")
            (d / "job.log").touch()
            host = self.config.build_host if where == "remote" else None
            job = Job(job_id, prompt, name, where, host, started=time.time(),
                      no_agent=bool(no_agent))
            self._save(job)
        except BaseException:
            os.close(fd)
            raise
        self._fds[job.id] = fd
        return job

    def _new_id(self, name: str) -> str:
        base = time.strftime("%Y%m%d-%H%M%S") + "-" + slug_of(name)
        out, n = base, 2
        while self.dir(out).exists():
            out, n = f"{base}-{n}", n + 1
        return out

    def start(self, prompt: str, where: str, name: str | None = None, no_agent: bool = False,
              on_line: Callable[[str], None] | None = None,
              taken: set[str] = frozenset()) -> Job:
        """create() then run() in the calling thread."""
        return self.run(self.create(prompt, where, name, no_agent, taken), on_line)

    def run(self, job: Job, on_line: Callable[[str], None] | None = None) -> Job:
        """Run a created job to its end; always releases the build lock."""
        try:
            self._run(job, on_line)
        except Exception as e:                     # never leave a job "running"
            job.state, job.error = "failed", f"the station failed: {e}"
            self._finish(job, on_line)
        finally:
            self._procs.pop(job.id, None)
            self._release(job.id)
        return job

    def _run(self, job: Job, on_line) -> None:
        minutes = float(self.config.build_max_minutes)
        deadline = time.monotonic() + minutes * 60
        where = f"on the build VM ({job.host})" if job.where == "remote" else "on the station"
        self._line(job, f"build {job.name} {where}", on_line)
        if self._cancel_asked(job):
            return self._end(job, 130, False, on_line)
        steps = self.commands(job)
        rc, timed_out = self._stream(job, steps[0], deadline, on_line)
        if job.where == "remote" and not self.config.build_command:
            rc = self._remote_after(job, steps, rc, timed_out, on_line)
        self._end(job, rc, timed_out, on_line)

    def _remote_after(self, job: Job, steps: list[str], rc: int, timed_out: bool,
                      on_line) -> int:
        """Fetch a good result; retain remote output until local validation succeeds."""
        if timed_out:
            self._quiet(self.cancel_command(job))
        elif rc == 0 and not self._cancel_asked(job):
            self._line(job, "step: fetching the results", on_line)
            if self._quiet(steps[1]) != 0:
                self._line(job, "could not fetch the results from the build VM", on_line)
                rc = 255
        elif rc != 0:
            self._quiet(self.cancel_command(job))
        if rc != 0:
            self._line(job, f"remote files retained; retry with badge build --retry-fetch {job.id}", on_line)
        return rc

    def retry_fetch(self, job_id: str) -> Job:
        """Recover a completed remote package retained after a transfer failure."""
        job = self.get(job_id)
        if not job or job.where != "remote" or job.state != "failed" or self.config.build_command:
            raise BuildError("no failed remote build with that ID")
        fd = self._acquire()
        try:
            steps = self.commands(job)
            self._line(job, "retrying remote result transfer", None)
            if self._quiet(steps[1]) != 0:
                raise BuildError("remote result transfer failed; files remain on the build VM")
            result, title = self._collect(job)
            job.result, job.title, job.state, job.error, job.exit = result, title, "done", None, 0
            self._quiet(steps[2])
            self._finish(job, None)
            return job
        finally:
            os.close(fd)

    def _stream(self, job: Job, cmd: str, deadline: float, on_line) -> tuple[int, bool]:
        """Run shell command CMD with its output in job.log; kill its group at DEADLINE."""
        try:
            builder = self._builder_options(job)
            p = subprocess.Popen(cmd, shell=True, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 errors="replace", start_new_session=True, cwd=self.dir(job.id),
                                 **builder)
        except OSError as e:
            self._line(job, f"could not start the build: {e}", on_line)
            return 127, False
        self._procs[job.id] = p
        job.state, job.pid = "running", p.pid
        timed_out = threading.Event()

        def expire():
            timed_out.set()
            kill_group(p.pid)

        timer = threading.Timer(max(0.0, deadline - time.monotonic()), expire)
        timer.daemon = True
        completed = False
        try:
            self._save(job)
            timer.start()
            with p.stdout:
                for line in p.stdout:
                    if line.strip():
                        self._line(job, line, on_line)
            rc = p.wait()
            completed = True
            return rc, timed_out.is_set()
        finally:
            timer.cancel()
            if not completed or _group_has_live_members(p.pid):
                kill_group(p.pid, wait=True)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    p.wait(timeout=2)

    @staticmethod
    def _quiet(cmd: str | None) -> int:
        if not cmd:
            return 0
        try:
            p = subprocess.Popen("set -o pipefail; " + cmd, shell=True,
                                 executable="/bin/bash", stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
            try:
                p.communicate(timeout=SSH_STEP_S)
            except subprocess.TimeoutExpired:
                kill_group(p.pid, wait=True)
                try:
                    p.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    return 1
            return p.returncode or 0
        except (OSError, subprocess.SubprocessError):
            return 1

    def _end(self, job: Job, rc: int, timed_out: bool, on_line) -> None:
        job.exit = rc
        if self._cancel_asked(job):
            job.state, job.exit, job.error = "cancelled", 130, "cancelled"
        elif timed_out:
            m = float(self.config.build_max_minutes)
            job.state, job.exit = "failed", 124
            job.error = f"stopped after {m:g} minute{'s' if m != 1 else ''}"
        elif rc != 0:
            job.state, job.error = "failed", EXIT_TEXT.get(rc, f"the build failed (exit {rc})")
        else:
            try:
                job.result, job.title = self._collect(job)
                job.state = "done"
                if job.where == "remote" and not self.config.build_command:
                    self._quiet(self.commands(job)[2])
            except BuildError as e:
                job.state, job.error = "failed", str(e)
        self._finish(job, on_line)

    def _builder_options(self, job: Job) -> dict:
        """Drop root only for local code; SSH itself uses the station account key."""
        if job.where != "local" or os.geteuid() != 0:
            return {}
        if not self.config.build_user:
            raise BuildError("local builds need build_user when the station runs as root")
        account = pwd.getpwnam(self.config.build_user)
        home = str(self.config.build_home or account.pw_dir)
        env = dict(os.environ, HOME=home, USER=account.pw_name, LOGNAME=account.pw_name,
                   PATH=f"{home}/.local/bin:{os.environ.get('PATH', '/usr/bin:/bin')}")
        return {"user": account.pw_uid, "group": account.pw_gid,
                "extra_groups": [], "env": env}

    def _finish(self, job: Job, on_line) -> None:
        job.finished = time.time()
        job.seconds = round(job.finished - job.started, 1)
        job.pid = None
        if job.state == "done":
            r = job.result
            ms = f", {r['bench_ms']:g} ms" if isinstance(r.get("bench_ms"), (int, float)) else ""
            msg = f"done: {job.title}, {-(-r['size'] // 1024)} KB{ms}, in {job.seconds:.0f} s"
        elif job.state == "cancelled":
            msg = f"cancelled after {job.seconds:.0f} s"
        else:
            msg = f"failed: {job.error}"
        with contextlib.suppress(OSError):
            self._line(job, msg, on_line)
        self._save(job)

    # -- the result -----------------------------------------------------------

    def _collect(self, job: Job) -> tuple[dict, str]:
        """Gate and register out/<name>.uf2; returns (result, title)."""
        out = self.dir(job.id) / "out"
        summary_file = out / "summary.json"
        try:
            fd = os.open(summary_file, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as fh:
                info = os.fstat(fh.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 64 * 1024:
                    raise BuildError("invalid build summary")
                summary = json.load(fh)
            summary = summary if isinstance(summary, dict) else {}
        except (OSError, ValueError):
            summary = {}
        uf2 = out / f"{job.name}.uf2"
        if not uf2.is_file():
            raise BuildError(f"the build made no {uf2.name}")
        # The builder owns out/. Pin the exact bytes in the root-owned job
        # directory before validating and registering them.
        snap_fd, snap_name = tempfile.mkstemp(prefix=".verified-", suffix=".uf2",
                                              dir=self.dir(job.id))
        snapshot = Path(snap_name)
        try:
            with os.fdopen(snap_fd, "wb") as dst:
                src_fd = os.open(uf2, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(src_fd, "rb") as src:
                    if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
                        raise BuildError("the UF2 is not a regular file")
                    shutil.copyfileobj(src, dst)
                    dst.flush()
                    os.fsync(dst.fileno())
            try:
                uf2_gate(snapshot)
            except BuildError as e:
                raise BuildError(str(e).replace(snapshot.name, uf2.name)) from e
            title = str(summary.get("title") or job.name).strip()[:40] or job.name
            try:
                self.register(snapshot, job.name, title, job.id)
            except Exception as e:
                raise BuildError(f"could not add the cart to the library: {e}") from e
            size = snapshot.stat().st_size
        finally:
            snapshot.unlink(missing_ok=True)
        preview = next((f"/builds/{job.id}/{n}" for n in ("preview.gif", "preview.png")
                        if (out / n).is_file() and not (out / n).is_symlink()), None)
        bench = summary.get("bench_ms")
        result = {"cart": job.name, "uf2": f"carts/{job.name}.uf2", "size": size,
                  "preview": preview,
                  "bench_ms": bench if isinstance(bench, (int, float)) else None,
                  "branch": summary.get("branch") or None}
        return result, title

    def _register(self, uf2: Path, name: str, title: str, job_id: str) -> None:
        from .library import Library
        Library(self.library).add_uf2(uf2, key=name, title=title, build=job_id)

    # -- commands -------------------------------------------------------------

    def flags(self, job: Job) -> list[str]:
        """--name, --no-agent and the agent limits, as build-job.sh takes them."""
        minutes = max(1, int(float(self.config.build_max_minutes)) - 1)
        out = ["--name", job.name]
        if job.no_agent:
            out.append("--no-agent")
        return out + ["--max-turns", str(self.config.build_max_turns),
                      "--max-usd", f"{float(self.config.build_max_usd):g}",
                      "--minutes", str(minutes)]

    def commands(self, job: Job) -> list[str]:
        """The steps for JOB: [run] for a template or local build, [run, fetch, clean] remote."""
        d = self.dir(job.id)
        prompt = d / "prompt.txt"
        if self.config.build_command:
            fill = {"id": job.id, "out": str(d / "out"), "prompt_file": str(prompt),
                    "name": job.name}
            cmd = self.config.build_command.format(
                **{k: shlex.quote(v) for k, v in fill.items()}, flags=_join(self.flags(job)))
            return [cmd]
        local_repo = self.config.build_local_repo or self.config.build_repo
        script = f"{local_repo if job.where == 'local' else self.config.build_repo}/{BUILD_JOB_SH}"
        if job.where == "local":
            return [_join(["bash", script, "--id", job.id, "--out", str(d / "out"),
                           "--prompt-file", str(prompt), *self.flags(job)])]
        work = self._remote_dir(job)
        run = _join(["bash", script, "--id", job.id, "--out", f"{work}/out",
                     "--prompt-file", "-", *self.flags(job)])
        return [f"{self._ssh(job.host, run)} < {shlex.quote(str(prompt))}",
                f"{self._ssh(job.host, _join(['tar', '-C', work, '-cf', '-', 'out']))}"
                f" | tar -x -C {shlex.quote(str(d))}",
                self._ssh(job.host, _join(["rm", "-rf", work]))]

    def cancel_command(self, job: Job) -> str | None:
        """What stops JOB on the build host (remote jobs without a build_command)."""
        if job.where != "remote" or self.config.build_command or not job.host:
            return None
        script = f"{self.config.build_repo}/{BUILD_JOB_SH}"
        return self._ssh(job.host, _join(["bash", script, "--cancel", job.id]))

    def _remote_dir(self, job: Job) -> str:
        return f"{self.config.build_repo}/build-jobs/{job.id}"

    def _ssh(self, host: str | None, remote: str) -> str:
        """ssh HOST REMOTE, REMOTE quoted once more for the remote shell."""
        if not host:
            raise BuildError("no build_host in station.toml")
        ssh_key = self.config.build_home / ".ssh/id_ed25519" if self.config.build_home else SSH_KEY
        key = ["-i", str(ssh_key)] if ssh_key.is_file() else []
        return _join(["ssh", *SSH_OPTS, *key, host, remote])

    # -- cancel ---------------------------------------------------------------

    def _cancel_asked(self, job: Job) -> bool:
        return (self.dir(job.id) / "cancel").exists()

    def cancel(self) -> bool:
        """Stop the running job (from any process); False when nothing runs."""
        job = self.current()
        if job is None:
            return False
        (self.dir(job.id) / "cancel").touch()
        self._changed()
        p = self._procs.get(job.id)
        if p is not None:
            kill_group(p.pid)
        elif job.pid:
            kill_group(job.pid, wait=True)
        self._quiet(self.cancel_command(job))
        return True


def _join(argv: list[str]) -> str:
    return " ".join(shlex.quote(a) for a in argv)


def _alive(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except OSError:
        return False


def _group_has_live_members(pgid: int) -> bool:
    for stat in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = stat.read_text().rsplit(") ", 1)[1].split()
            if int(fields[2]) == pgid and fields[0] != "Z":
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def kill_group(pgid: int, alive: Callable[[], bool] | None = None, wait: bool = False) -> None:
    """Signal the whole group even when its original leader already exited."""
    with contextlib.suppress(OSError):
        os.killpg(pgid, signal.SIGTERM)

    def hard():
        if _group_has_live_members(pgid):
            with contextlib.suppress(OSError):
                os.killpg(pgid, signal.SIGKILL)

    if not wait:
        t = threading.Timer(KILL_GRACE_S, hard)
        t.daemon = True
        t.start()
        return
    end = time.monotonic() + KILL_GRACE_S
    while time.monotonic() < end and _group_has_live_members(pgid):
        time.sleep(0.05)
    hard()
    # Delivery of SIGKILL is asynchronous. Do not release the job lock while
    # runnable descendants from this group are still being torn down.
    end = time.monotonic() + 1
    while time.monotonic() < end and _group_has_live_members(pgid):
        time.sleep(0.01)


def uf2_gate(uf2: Path) -> None:
    """tools/uf2_info.py on UF2 (skipped when the tool is not installed); BuildError if bad."""
    if not UF2_INFO.is_file():
        return
    try:
        r = subprocess.run([sys.executable, str(UF2_INFO), str(uf2)], capture_output=True,
                           text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        raise BuildError(f"could not check {uf2.name}: {e}") from e
    if r.returncode != 0:
        last = (r.stdout.strip().splitlines() or [r.stderr.strip() or "bad UF2"])[-1].strip()
        raise BuildError(f"{uf2.name} failed the UF2 check: {last}")
