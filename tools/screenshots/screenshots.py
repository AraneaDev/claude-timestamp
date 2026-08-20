"""Regenerate the screenshots in assets/.

Every shot is captured from the real thing rather than mocked up. The hero and
picker shots each drive an actual Claude Code session inside a pty. The wizard
shot runs the real setup script through a pty too, since it needs a TTY. The
doctor and stats shots run the real setup script directly and capture its
output. Nothing here fabricates output.

pyte is a terminal emulator, so what gets rendered is whatever was actually
painted, escape codes and all. It models bold and italics but has no notion of
SGR 2 (dim), which is exactly what this plugin uses by default, so Screen is
subclassed below to track it.

Usage:  python screenshots.py [hero|picker|wizard|doctor|stats|all]

There is deliberately no shot of the end-of-session summary. Producing one
means exiting the TUI under automation, and it does not go quietly: typing
/exit opens the command autocomplete and the newline picks from the menu,
while Ctrl-D is ignored whenever a history suggestion is sitting in the input.
The README shows that output as text instead.

The hero shot starts a real session and therefore spends tokens. It also
depends on how fast the model answers, so the durations differ every run; that
is the point, they are real measurements rather than props.
"""
import fcntl, json, os, pty, select, struct, subprocess, sys, termios, time
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
SCRIPTS = ROOT / "hooks" / "scripts"
WORK = Path(os.environ.get("TMPDIR", "/tmp")) / "claude-timestamp-shots"

# GitHub's dark canvas, so the images sit naturally in a README.
PALETTE = {
    "default": "#c9d1d9", "black": "#484f58", "red": "#ff7b72",
    "green": "#3fb950", "brown": "#d29922", "yellow": "#d29922",
    "blue": "#58a6ff", "magenta": "#bc8cff", "cyan": "#39c5cf",
    "white": "#b1bac4", "brightblack": "#6e7681",
}
BG = "#0d1117"
FONT_DIRS = [
    "/usr/share/fonts/truetype/dejavu",
    "/usr/local/share/fonts",
    "/Library/Fonts",
    "/System/Library/Fonts",
]


def find_font(name):
    for d in FONT_DIRS:
        p = Path(d) / name
        if p.exists():
            return str(p)
    raise SystemExit(f"font not found: {name}. Install DejaVu Sans Mono.")


class DimScreen(pyte.Screen):
    """A pyte Screen that also remembers which cells were drawn dim."""

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.dim = {}
        self._dim = False

    def select_graphic_rendition(self, *attrs, **kwargs):
        for a in attrs:
            if a == 2:
                self._dim = True
            elif a in (0, 22):
                self._dim = False
        super().select_graphic_rendition(*attrs, **kwargs)

    def draw(self, data):
        y, x = self.cursor.y, self.cursor.x
        super().draw(data)
        for i in range(len(data)):
            self.dim[(y, x + i)] = self._dim

    def reset(self):
        super().reset()
        self._dim = False


def capture_pty(argv, keys, cols, rows, settle=12, total=150, env=None):
    """Run argv in a pty, type `keys`, return everything it painted.

    keys is a list of (seconds_from_start, text). Text and the newline that
    submits it are sent separately in the shot definitions, because an Enter
    arriving while the TUI is busy gets swallowed.
    """
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env or {})
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
        os.execvp(argv[0], argv)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    start = last = time.time()
    pending = [(d, t.encode()) for d, t in keys]
    raw = bytearray()
    while time.time() - start < total:
        while pending and time.time() - start >= pending[0][0]:
            os.write(fd, pending.pop(0)[1])
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            raw += data
            last = time.time()
        elif not pending and time.time() - last > settle:
            break
    try:
        os.write(fd, b"\x03")
        time.sleep(0.2)
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    return bytes(raw)


def to_rgb(spec):
    spec = PALETTE.get(spec, spec)
    if not spec.startswith("#"):
        spec = "#" + spec
    return tuple(int(spec[i:i + 2], 16) for i in (1, 3, 5))


def blend(fg, bg, amount):
    return tuple(int(b + (f - b) * amount) for f, b in zip(fg, bg))


def render(raw, out, cols, rows, first=None, last=None, scale=2, crlf=False):
    screen = DimScreen(cols, rows)
    if crlf:
        # Plain command output uses bare newlines. A terminal needs the CR to
        # return to column zero, or every line starts where the last one ended.
        raw = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    pyte.ByteStream(screen).feed(raw)

    font = ImageFont.truetype(find_font("DejaVuSansMono.ttf"), 15 * scale)
    boldf = ImageFont.truetype(find_font("DejaVuSansMono-Bold.ttf"), 15 * scale)
    cw, ch, pad = int(font.getlength("M")), int(15 * scale * 1.45), 14 * scale

    used = [y for y in range(rows) if screen.display[y].strip()]
    top = first if first is not None else (used[0] if used else 0)
    bot = last if last is not None else (used[-1] if used else rows - 1)

    img = Image.new("RGB", (cols * cw + pad * 2, (bot - top + 1) * ch + pad * 2), to_rgb(BG))
    d, bg = ImageDraw.Draw(img), to_rgb(BG)
    for y in range(top, bot + 1):
        for x in range(cols):
            c = screen.buffer[y][x]
            if not c.data or c.data == " ":
                continue
            fg = to_rgb(c.fg)
            if screen.dim.get((y, x)):
                fg = blend(fg, bg, 0.45)
            d.text((pad + x * cw, pad + (y - top) * ch), c.data,
                   font=boldf if c.bold else font, fill=fg)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(f"wrote {out.relative_to(ROOT)}  ({img.width}x{img.height})")


DEMO_CONFIG = """\
TZ=Europe/Amsterdam
DISPLAY_FORMAT=24h
COLOR=dim
ELAPSED=on
SLOW_AFTER=5
SLOW_COLOR=yellow
IDLE_AFTER=0
SUMMARY=on
TOOL_TIMING=on
"""

DOCTOR_CONFIG = """\
TZ=Europe/Amsterdam
DISPLAY_FORMAT=24h
CONTEXT_FORMAT=24h
COLOR=dim
ELAPSED=on
SLOW_AFTER=60
SLOW_COLOR=yellow
IDLE_AFTER=3600
DATE_ROLLOVER=on
SUMMARY=on
SUBAGENTS=on
TOOL_TIMING=on
"""


def shot_hero():
    """A real session: two quick turns and one slow enough to colour."""
    if not subprocess.run(["which", "claude"], capture_output=True).returncode == 0:
        raise SystemExit("claude is not on PATH; cannot capture the hero shot.")
    work = WORK / "hero"
    work.mkdir(parents=True, exist_ok=True)
    conf = work / "config.conf"
    conf.write_text(DEMO_CONFIG)

    cols, rows = 96, 46
    os.chdir(work)
    raw = capture_pty(
        ["claude"],
        keys=[
            (6.0, "What is the capital of Portugal? One word, no punctuation."), (7.0, "\r"),
            (24.0, "Name three Portuguese cities, comma separated, nothing else."), (26.0, "\r"),
            (44.0, "In about 90 words, explain why bash has no decimal arithmetic."), (46.0, "\r"),
        ],
        cols=cols, rows=rows, settle=14, total=140,
        env={"CLAUDE_TIMESTAMP_CONFIG": str(conf)},
    )
    (work / "hero.raw").write_bytes(raw)

    # Crop past the welcome banner and stop before the status line. The banner
    # carries the account's name, email and organisation, which do not belong
    # in a published screenshot.
    screen = DimScreen(cols, rows)
    pyte.ByteStream(screen).feed(raw)
    lines = screen.display
    first = next((y for y in range(rows) if lines[y].lstrip().startswith("❯")), 12) - 1
    last = max((y for y in range(rows) if lines[y].strip().startswith("✻")), default=rows - 1)
    render(raw, ASSETS / "timestamps.png", cols, rows, first=first, last=last)


def shot_picker():
    """The in-chat picker, captured mid-question.

    Driven the same way as the hero shot: a real session, typed into through a
    pty. The picker is an interactive widget rather than program output, so the
    capture deliberately stops while the question is still on screen and never
    answers it.

    Unlike every other shot here, this one does not set CLAUDE_TIMESTAMP_CONFIG.
    That variable is honoured by the hooks that paint the transcript markers,
    but /timestamps is a prompt: it reads the literal path
    ~/.claude/claude-timestamp.conf and cannot be redirected by the
    environment. Pointing the hooks at a demo config while /timestamps read the
    real one produced a frame that visibly disagreed with itself -- the hooks'
    duration was coloured past a demo SLOW_AFTER while the picker's own text
    named the real, much higher, threshold. Leaving the variable unset means
    both halves read the same file, so the picker shows whatever the real
    account is actually configured with. That is a mild, known privacy cost,
    no worse than what the crop below already accepts by publishing the
    account's real settings as text.

    Reproducibility warning: the keys/settle/total below were tuned against a
    work directory `claude` had already been run in before, in a nested child
    session (this repo's own tooling runs inside one), which is exempt from
    the interactive workspace-trust dialog a normal top-level session shows
    the first time it sees a new directory. That exemption made it impossible
    to observe, from here, what a genuinely first-ever run looks like or to
    script an answer to a dialog that never rendered. If this shot is ever run
    against a directory `claude` has never seen -- a clean checkout, a fresh
    CI runner -- from an ordinary (non-nested) terminal, the first invocation
    may show that dialog and swallow the typed keys before anything is ready
    to receive them, producing a capture of nothing but the welcome banner. If
    that happens: it is the trust dialog, not these timings. Run `claude` once
    by hand in the work directory below to accept it, then re-run this shot;
    the directory stays trusted after that.
    """
    if not subprocess.run(["which", "claude"], capture_output=True).returncode == 0:
        raise SystemExit("claude is not on PATH; cannot capture the picker shot.")
    work = WORK / "picker"
    work.mkdir(parents=True, exist_ok=True)

    # Reading schema.json, the facts file and the config, then rendering the
    # question, takes 40-50s in practice, well past what the brief's starting
    # guess assumed. rows is generous (50) so the whole exchange -- the typed
    # command, Claude's reasoning, and the question -- renders without
    # scrolling anything off the top; render() then trims the blank rows left
    # under the picker on its own.
    cols, rows = 96, 50
    os.chdir(work)
    raw = capture_pty(
        ["claude"],
        keys=[(6.0, "/timestamps"), (7.5, "\r")],
        cols=cols, rows=rows, settle=12, total=100,
    )
    (work / "picker.raw").write_bytes(raw)

    # Crop past the welcome banner, which carries the account's name, email and
    # organisation. Those do not belong in a published screenshot.
    screen = DimScreen(cols, rows)
    pyte.ByteStream(screen).feed(raw)
    lines = screen.display
    first = next((y for y in range(rows) if lines[y].lstrip().startswith("❯")), 12) - 1
    render(raw, ASSETS / "picker.png", cols, rows, first=first)


def shot_wizard():
    """The interactive wizard, driven through a pty so it has a real TTY.

    Every prompt is answered by accepting its default, which is what makes the
    shot readable: the defaults are the thing worth showing.
    """
    work = WORK / "wizard"
    home = work / "home" / ".claude"
    home.mkdir(parents=True, exist_ok=True)
    (home / "claude-timestamp.conf").write_text(DOCTOR_CONFIG)

    cols, rows = 84, 58
    # One Enter per question, then y to write. Spaced out because the wizard
    # redraws a colour palette between some of them.
    keys = [(0.8 + i * 0.35, "\r") for i in range(10)]
    keys.append((0.8 + 10 * 0.35, "y\r"))
    raw = capture_pty(
        ["bash", str(SCRIPTS / "setup.sh")],
        keys=keys, cols=cols, rows=rows, settle=3, total=40,
        env={"HOME": str(work / "home"), "CLAUDE_TIMESTAMP_CONFIG": ""},
    )
    (work / "wizard.raw").write_bytes(raw)
    render(raw, ASSETS / "wizard.png", cols, rows)


def shot_doctor():
    """The real doctor output, run against a generic home and a project."""
    work = WORK / "doctor"
    (work / "home" / ".claude").mkdir(parents=True, exist_ok=True)
    (work / "home" / ".claude" / "claude-timestamp.conf").write_text(DOCTOR_CONFIG)
    # A project config too, so the shot shows the layering rather than leaving
    # a reader to wonder what the project line means. Deliberately at a short
    # path: the doctor prints it in full, and a long temp path wraps the line.
    project = Path("/tmp/ct-demo-project")
    (project / ".claude").mkdir(parents=True, exist_ok=True)
    (project / ".claude" / "claude-timestamp.conf").write_text("COLOR=cyan\n")

    env = dict(os.environ)
    env.pop("CLAUDE_TIMESTAMP_CONFIG", None)
    env["HOME"] = str(work / "home")
    proc = subprocess.run(
        ["bash", str(SCRIPTS / "setup.sh"), "--doctor"],
        capture_output=True, env=env, cwd=str(project),
    )
    raw = proc.stdout + proc.stderr
    (work / "doctor.raw").write_bytes(raw)
    render(raw, ASSETS / "doctor.png", cols=84, rows=36, crlf=True)


def shot_stats():
    """The real --stats output over a synthetic history.

    The rows are made up, because a believable screenshot needs more sessions
    than this repository has accumulated. Everything else, the arithmetic and
    the formatting, is the real command.
    """
    work = WORK / "stats"
    (work / "home" / ".claude").mkdir(parents=True, exist_ok=True)
    (work / "home" / ".claude" / "claude-timestamp.conf").write_text(DOCTOR_CONFIG)

    history = work / "home" / ".claude" / "claude-timestamp-history.tsv"
    rows = [
        ("2026-08-04T09:12:00", 4820, 41, 1180, 900, 0),
        ("2026-08-05T10:41:00", 2260, 19, 540, 0, 1),
        ("2026-08-06T08:55:00", 7415, 63, 2210, 3600, 2),
        ("2026-08-07T14:02:00", 1180, 9, 260, 0, 0),
        ("2026-08-10T09:30:00", 5360, 44, 1490, 1800, 0),
        ("2026-08-11T11:15:00", 3090, 27, 700, 0, 3),
        ("2026-08-12T09:05:00", 6240, 52, 1810, 2400, 1),
        ("2026-08-13T16:20:00", 900, 6, 190, 0, 0),
        ("2026-08-17T10:00:00", 4100, 33, 1020, 1200, 0),
        ("2026-08-19T09:45:00", 2980, 24, 660, 0, 1),
    ]
    history.write_text("".join("\t".join(str(f) for f in r) + "\n" for r in rows))

    env = dict(os.environ)
    env.pop("CLAUDE_TIMESTAMP_CONFIG", None)
    env.pop("CLAUDE_TIMESTAMP_HISTORY", None)
    env["HOME"] = str(work / "home")
    proc = subprocess.run(
        ["bash", str(SCRIPTS / "setup.sh"), "--stats"],
        capture_output=True, env=env, cwd=str(work),
    )
    raw = proc.stdout + proc.stderr
    (work / "stats.raw").write_bytes(raw)
    render(raw, ASSETS / "stats.png", cols=64, rows=22, crlf=True)


SHOTS = {"hero": shot_hero, "picker": shot_picker, "wizard": shot_wizard,
         "doctor": shot_doctor, "stats": shot_stats}

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = list(SHOTS) if which == "all" else [which]
    for n in names:
        if n not in SHOTS:
            raise SystemExit(f"unknown shot: {n}. Pick from: {', '.join(SHOTS)}, all")
        print(f"--- {n}")
        SHOTS[n]()
