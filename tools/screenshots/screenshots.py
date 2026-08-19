"""Regenerate the screenshots in assets/.

Both shots are captured from the real thing rather than mocked up. The hero
shot drives an actual Claude Code session inside a pty, and the doctor shot
runs the real setup script. Nothing here fabricates output.

pyte is a terminal emulator, so what gets rendered is whatever was actually
painted, escape codes and all. It models bold and italics but has no notion of
SGR 2 (dim), which is exactly what this plugin uses by default, so Screen is
subclassed below to track it.

Usage:  python screenshots.py [hero|wizard|doctor|all]

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


SHOTS = {"hero": shot_hero, "wizard": shot_wizard, "doctor": shot_doctor}

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = list(SHOTS) if which == "all" else [which]
    for n in names:
        if n not in SHOTS:
            raise SystemExit(f"unknown shot: {n}. Pick from: {', '.join(SHOTS)}, all")
        print(f"--- {n}")
        SHOTS[n]()
