"""Regenerate the screenshots (and the one animation) in assets/.

Every shot is captured from the real thing rather than mocked up. The hero
and picker shots each drive an actual Claude Code session inside a pty. The
wizard shot runs the real setup script through a pty too, since it needs a
TTY. The doctor, stats and markers shots run real code directly and capture
its output. The session shot drives the real hooks with planted state, the
way the test suite does. Nothing here fabricates output -- the hero shot is
an animated WebP built from a real recording, timed to real seconds, not a
sped up or looped approximation of one.

Producing a shot of the end-of-session summary by exiting the TUI under
automation does not go quietly: typing /exit opens the command autocomplete
and the newline picks from the menu, while Ctrl-D is ignored whenever a
history suggestion is sitting in the input. shot_session sidesteps that
entirely by calling session-end.sh directly with state planted the way a real
session would have left it, the same approach the test suite uses.

pyte is a terminal emulator, so what gets rendered is whatever was actually
painted, escape codes and all. It models bold and italics but has no notion of
SGR 2 (dim), which is exactly what this plugin uses by default, so Screen is
subclassed below to track it.

Usage:  python screenshots.py [hero|picker|wizard|doctor|stats|markers|session|all]

Costs: hero and picker each drive a real Claude Code session (tokens, and
however long the model takes to answer). wizard, doctor, stats, markers and
session run local scripts only and are free and offline. Plain `all`
therefore spends two real sessions every time it runs -- pass a single name
if that is not what you want.

The hero shot starts a real session and therefore spends tokens. It also
depends on how fast the model answers, so the durations differ every run;
that is the point, they are real measurements rather than props. Its
animation's own playback speed is likewise real: frame durations are read off
the recording's true timestamps, never compressed, so a viewer watching it
experiences the same seconds the session actually took.

Every image is written as lossless WebP, stills and the animation alike.
Terminal captures are flat colour with hard edges, which lossless compression
handles extremely well and a lossy setting would only blur; save_image and
save_animation are the two functions every shot's output passes through, so a
future shot cannot quietly stay PNG.
"""
import fcntl, json, os, pty, select, struct, stat, subprocess, sys, termios, time
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
SCRIPTS = ROOT / "hooks" / "scripts"
WORK = Path(os.environ.get("TMPDIR", "/tmp")) / "claude-timestamp-shots"


def _secure_work():
    """Make WORK exist, be ours, and be private, or refuse to run.

    The path is predictable and sits in a directory anyone can write to, and
    the shots stage a HOME, a config and a state tree underneath it. Somebody
    who gets there first can plant a symlink and have a shot write through it.

    Not mkdtemp(): the path is deliberately stable across runs. `claude`
    trusts a working directory once it has seen it, and the picker shot
    depends on that trust surviving, so a fresh directory every run would
    reintroduce the workspace-trust dialog its docstring warns about.

    So: create it privately if it is not there, and if it is, insist it is a
    real directory that we own before writing anything into it. lstat, not
    stat, because a symlink is the case being refused.
    """
    try:
        st = os.lstat(WORK)
    except FileNotFoundError:
        WORK.parent.mkdir(parents=True, exist_ok=True)
        WORK.mkdir(mode=0o700)
        return
    if stat.S_ISLNK(st.st_mode):
        raise SystemExit(f"{WORK} is a symlink; refusing to write through it.")
    if not stat.S_ISDIR(st.st_mode):
        raise SystemExit(f"{WORK} exists and is not a directory.")
    if st.st_uid != os.geteuid():
        raise SystemExit(f"{WORK} is owned by uid {st.st_uid}, not by you.")
    if st.st_mode & 0o077:
        os.chmod(WORK, 0o700)

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


def capture_pty(argv, keys, cols, rows, settle=12, total=150, env=None, record=False):
    """Run argv in a pty, type `keys`, return everything it painted.

    keys is a list of (seconds_from_start, text). Text and the newline that
    submits it are sent separately in the shot definitions, because an Enter
    arriving while the TUI is busy gets swallowed.

    With record=True, also return the true arrival time of every chunk read
    from the pty as (seconds_since_start, chunk) pairs, plus the wall-clock
    duration of the whole capture. That is the raw material an animation
    needs to place frames at the moments they actually happened, rather than
    at a compressed or evenly-spaced approximation of them. record=False (the
    default) changes nothing about the existing behaviour or return value --
    the still shots that call this do not pay for what they do not use.
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
    timeline = [] if record else None
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
            if record:
                timeline.append((time.time() - start, data))
            last = time.time()
        elif not pending and time.time() - last > settle:
            break
    elapsed = time.time() - start
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
    if record:
        return bytes(raw), timeline, elapsed
    return bytes(raw)


def capture_pty_until(argv, until, answer, cols, rows, tick=0.35, settle=3, total=40, env=None, cwd=None):
    """Run argv in a pty, pressing Enter on a timer until the transcript so
    far contains `until`, then send `answer` once and let the process finish.

    This exists so a script with a fixed sequence of "accept every default"
    questions followed by one real answer does not need its keystroke count
    hardcoded and bumped by hand every time a question is inserted before the
    one `answer` is meant for -- it was exactly that hardcoded count, sized
    for the wizard before it gained a Marker question, that once made this
    shot capture the wizard rejecting `answer` at the wrong prompt instead of
    reaching the one it was meant for.

    cwd matters as much as env here, for a reason specific to this plugin: its
    project-config search walks upward from the working directory, directory
    by directory, comparing each one to $HOME and stopping the instant they
    match -- see ct_find_project_config in lib/config.sh. A caller that
    overrides HOME to a scratch directory but leaves cwd wherever the Python
    process happens to be sitting breaks that stop condition, because cwd's
    real ancestors no longer include the fake HOME at all. The walk then
    keeps climbing past every directory this repository sits under until it
    reaches one that does have a .claude/claude-timestamp.conf -- the
    generating machine's own account config -- and reads it as a *project*
    layer on top of whatever DOCTOR_CONFIG staged. That is exactly how a
    wizard shot once rendered PROJECTS as [on] although DOCTOR_CONFIG never
    sets it: the repository root is a subdirectory of the real $HOME, so the
    walk from there reached it and picked up whatever the real account has
    turned on that day. Passing a cwd inside the fake HOME (the caller below
    passes the fake HOME itself) makes the very first comparison in that walk
    match, so it stops before looking at any real file. Do not drop this
    parameter as unused-looking plumbing -- the shot is wrong without it.
    """
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env or {})
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
        if cwd is not None:
            os.chdir(cwd)
        os.execvp(argv[0], argv)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    start = last_output = time.time()
    next_key = start + 0.8  # let the first prompt actually draw first
    until_bytes = until.encode()
    raw = bytearray()
    answered = False
    while time.time() - start < total:
        now = time.time()
        if not answered and now >= next_key:
            os.write(fd, b"\r")
            next_key = now + tick
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            raw += data
            last_output = now
            if not answered and until_bytes in raw:
                os.write(fd, answer.encode())
                answered = True
        elif answered and now - last_output > settle:
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


# DejaVu Sans Mono is missing a handful of glyphs the real Claude Code TUI
# paints for tool calls -- notably U+23BF (the "⎿" result marker), which
# renders as a tofu box. Swapped for a box-drawing corner the font does have,
# since the two look the same at this size and swapping preserves the grid
# layout (draw position is cell-indexed, not glyph-measured).
GLYPH_SUBSTITUTIONS = {"⎿": "└"}


def font_metrics(scale):
    font = ImageFont.truetype(find_font("DejaVuSansMono.ttf"), 15 * scale)
    boldf = ImageFont.truetype(find_font("DejaVuSansMono-Bold.ttf"), 15 * scale)
    cw, ch, pad = int(font.getlength("M")), int(15 * scale * 1.45), 14 * scale
    return font, boldf, cw, ch, pad


def compose_frame(screen, cols, top, bot, font, boldf, cw, ch, pad, content_bot=None):
    """Paint one rectangular window of a pyte screen to an RGB image.

    Shared by the still-shot renderer and the animation frame sampler, so a frame
    of the animation is drawn by exactly the same code path -- same font
    metrics, same dim blend, same glyph substitutions -- as a still.

    content_bot, when given, is <= bot and holds the canvas size at (top,bot)
    while leaving every row past it blank. The animation sampler uses this: the
    still shots crop `bot` to land just above the rule-and-input-box chrome
    in the *final* frame, but that chrome sits at a lower row with every line
    the session prints, so at an earlier sampled moment the still shots'
    fixed (top, bot) window can still contain it. Blanking past content_bot
    keeps every frame the same pixel size (required for an animation) without ever
    painting that chrome.
    """
    if content_bot is None:
        content_bot = bot
    img = Image.new("RGB", (cols * cw + pad * 2, (bot - top + 1) * ch + pad * 2), to_rgb(BG))
    d, bg = ImageDraw.Draw(img), to_rgb(BG)
    for y in range(top, min(bot, content_bot) + 1):
        for x in range(cols):
            c = screen.buffer[y][x]
            if not c.data or c.data == " ":
                continue
            fg = to_rgb(c.fg)
            if screen.dim.get((y, x)):
                fg = blend(fg, bg, 0.45)
            glyph = GLYPH_SUBSTITUTIONS.get(c.data, c.data)
            d.text((pad + x * cw, pad + (y - top) * ch), glyph,
                   font=boldf if c.bold else font, fill=fg)
    return img


# Every still image is written through this one function, so a future shot
# cannot quietly stay PNG. Terminal captures are flat colour with hard edges,
# which lossless WebP compresses extremely well and lossy encoding wastes bits
# on -- measured across this repository's own shots, lossless was smaller as
# well as sharper, so there is no lossy path to opt into by accident.
def save_image(img, out):
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "WEBP", lossless=True, quality=100, method=6)
    size = out.stat().st_size
    print(f"wrote {out.relative_to(ROOT)}  ({img.width}x{img.height}, {size / 1024:.1f} KiB)")


def render(raw, out, cols, rows, first=None, last=None, scale=2, crlf=False):
    screen = DimScreen(cols, rows)
    if crlf:
        # Plain command output uses bare newlines. A terminal needs the CR to
        # return to column zero, or every line starts where the last one ended.
        raw = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    pyte.ByteStream(screen).feed(raw)

    font, boldf, cw, ch, pad = font_metrics(scale)

    used = [y for y in range(rows) if screen.display[y].strip()]
    top = first if first is not None else (used[0] if used else 0)
    bot = last if last is not None else (used[-1] if used else rows - 1)

    img = compose_frame(screen, cols, top, bot, font, boldf, cw, ch, pad)
    save_image(img, out)


def _rule_row(screen, top, bot):
    """Find the horizontal rule that opens the footer/input-box chrome.

    Claude Code always draws a full-width run of "-" above the persistent
    input box, at whatever row currently sits right after the transcript so
    far. Its row moves down as the transcript grows, which is exactly why it
    cannot be cropped out with one fixed row picked from the final frame
    alone (see compose_frame's content_bot).
    """
    for y in range(top, bot + 1):
        line = screen.display[y].strip()
        if len(line) >= 10 and set(line) <= set("─-—_"):
            return y
    return None


def _content_bottom(screen, top, bot):
    """Where this moment's real content ends, within a fixed (top, bot) window.

    Prefers the row just above the footer rule (see _rule_row); before that
    chrome has rendered at all (the first instant or two of the recording),
    falls back to the last non-blank row so nothing below whatever has
    actually been printed gets shown.
    """
    rule = _rule_row(screen, top, bot)
    if rule is not None:
        return max(top - 1, rule - 1)
    used = [y for y in range(top, bot + 1) if screen.display[y].strip()]
    return used[-1] if used else top - 1


def _window_snapshot(screen, cols, top, content_bot):
    """A cheap hashable fingerprint of one rectangular window of a screen.

    Used only to tell whether two sampled moments looked different, so
    identical consecutive samples can be merged into one longer-held animation
    frame instead of two identical ones -- real time still elapses either
    way, it is just spent as one frame's duration rather than several. Only
    scans down to content_bot, matching what compose_frame actually paints,
    so a change hidden below the visible content (like the footer's context
    percentage ticking) does not spawn a pointless extra frame.
    """
    parts = [str(content_bot)]
    for y in range(top, content_bot + 1):
        row = screen.buffer[y]
        dim = screen.dim
        for x in range(cols):
            c = row[x]
            parts.append(c.data or " ")
            parts.append(c.fg)
            parts.append("1" if c.bold else "0")
            parts.append("1" if dim.get((y, x)) else "0")
    return "".join(parts)


def sample_frames(timeline, elapsed, cols, rows, top, bot, scale, dt):
    """Replay a timed byte stream into (image, real_seconds_shown) frames.

    The recording is walked in fixed dt buckets covering [0, elapsed] --
    dt chosen well above any delay a WebP player would silently round up to,
    so no bucket is ever faster than what was actually captured. Each
    bucket's displayed content is the screen state after every byte that had
    actually arrived by that bucket's end, so the very last bucket always
    reflects the true final state. Consecutive buckets that look identical
    are merged into one frame whose duration is their combined real time,
    which is what keeps a long idle stretch from costing one animation frame per
    dt: sum(duration for every returned frame) always equals `elapsed`
    exactly, whether that time was spent as one frame or a hundred.

    (top, bot) is the fixed window later frames all share pixel-for-pixel;
    within it, each sample also gets its own content_bot (see
    _content_bottom) so the footer/input-box chrome -- which sits at a
    different row every time the transcript grows -- never gets painted.
    """
    screen = DimScreen(cols, rows)
    stream = pyte.ByteStream(screen)
    font, boldf, cw, ch, pad = font_metrics(scale)

    steps = max(1, round(elapsed / dt))
    bounds = [elapsed * i / steps for i in range(steps + 1)]

    idx = 0
    frames = []
    prev_snap = None
    for i in range(steps):
        t_end = bounds[i + 1]
        while idx < len(timeline) and timeline[idx][0] <= t_end:
            stream.feed(timeline[idx][1])
            idx += 1
        content_bot = _content_bottom(screen, top, bot)
        snap = _window_snapshot(screen, cols, top, content_bot)
        duration = bounds[i + 1] - bounds[i]
        if snap != prev_snap:
            img = compose_frame(screen, cols, top, bot, font, boldf, cw, ch, pad,
                                 content_bot=content_bot)
            frames.append([img, duration])
            prev_snap = snap
        else:
            frames[-1][1] += duration
    return frames


def save_animation(imgs, durations, out):
    """Write frames as a lossless animated WebP, through the one save routine
    every animation uses.

    method=4 rather than the stills' method=6: 6 is very slow across dozens of
    frames for no size gain once the encoding is already lossless. Loops
    forever (loop=0), matching how the README animation has always behaved.
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    imgs[0].save(out, "WEBP", save_all=True, append_images=imgs[1:],
                 duration=durations, loop=0, lossless=True, quality=100, method=4)
    size = out.stat().st_size
    print(f"wrote {out.relative_to(ROOT)}  ({imgs[0].width}x{imgs[0].height}, "
          f"{len(imgs)} frames, {sum(durations) / 1000:.1f}s, {size / 1024:.0f} KiB)")


def save_timed_animation(frames, out, elapsed):
    """Write sample_frames() output as an animated WebP whose playback matches
    real time.

    Unlike GIF, lossless WebP needs no shared palette or quantisation: the
    frames are RGB images saved as-is. Per-frame durations are rounded to
    whole milliseconds with the leftover pushed onto the final frame, so the
    file's total duration matches `elapsed` to the millisecond rather than
    drifting from rounding a few hundred frames independently.
    """
    total_ms = round(elapsed * 1000)
    imgs = []
    durations = []
    remaining_ms = total_ms
    for i, (img, secs) in enumerate(frames):
        if i == len(frames) - 1:
            ms = remaining_ms
        else:
            ms = round(secs * 1000)
            remaining_ms -= ms
        imgs.append(img)
        durations.append(ms)
    save_animation(imgs, durations, out)


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
    """A real session, recorded and played back as a WebP animation at real speed.

    Two quick turns, then one slow enough to name its tool. The third prompt
    has to make Claude actually run something slow, or TOOL_TIMING has
    nothing to attribute. It asks for an exact count that cannot be recalled
    or estimated, only computed, and rules out every interpreter but bash's
    own (slow) integer arithmetic so the trial division can't be handed off
    to something fast. That keeps it a single dominant Bash call rather than
    work split across tools -- and being pure arithmetic with no filesystem
    or network access, it can't touch anything outside this work directory
    even by accident. Prompts are spaced tight (a few seconds apart) rather
    than the leisurely gaps an earlier still version of this shot used, so
    the whole recording -- and the animation's own runtime -- stays under a minute
    without asking a reader to sit through dead air.

    This is the only place the README shows the marker, the duration or the
    tool attribution, so legibility comes first: frames are rendered at the
    same scale as every other shot rather than shrunk to save bytes. If the
    size budget is tight, sample_frames() is called with a larger dt (fewer
    frames per second) instead -- a chunkier animation that is still readable
    beats a smooth one that is not.
    """
    if not subprocess.run(["which", "claude"], capture_output=True).returncode == 0:
        raise SystemExit("claude is not on PATH; cannot capture the hero shot.")
    work = WORK / "hero"
    work.mkdir(parents=True, exist_ok=True)
    conf = work / "config.conf"
    conf.write_text(DEMO_CONFIG)

    cols, rows = 96, 90
    os.chdir(work)
    raw, timeline, elapsed = capture_pty(
        ["claude"],
        keys=[
            (2.0, "What is the capital of Portugal? One word, no punctuation."), (3.0, "\r"),
            (9.0, "Name three Portuguese cities, comma separated, nothing else."), (10.5, "\r"),
            (16.0, "Run one bash command that counts, by trial division using only "
                    "bash's own integer arithmetic (no python, bc, or awk), how many "
                    "integers below 220000 are prime. Actually execute it, don't "
                    "estimate. Reply with just the final count."), (18.0, "\r"),
        ],
        cols=cols, rows=rows, settle=10, total=110,
        env={"CLAUDE_TIMESTAMP_CONFIG": str(conf)}, record=True,
    )
    (work / "hero.raw").write_bytes(raw)

    # Crop past the welcome banner and stop before the status line. The banner
    # carries the account's name, email and organisation, which do not belong
    # in a published animation. The same fixed window is used for every sampled
    # frame, not recomputed per frame -- this rows buffer is generous enough
    # (verified against the captured raw below) that nothing in this session
    # scrolls, so a row position printed to means the same thing at every
    # moment in the recording.
    screen = DimScreen(cols, rows)
    pyte.ByteStream(screen).feed(raw)
    lines = screen.display
    first = next((y for y in range(rows) if lines[y].lstrip().startswith("❯")), 12) - 1
    last = max((y for y in range(rows) if lines[y].strip().startswith("✻")), default=rows - 1)

    frames = sample_frames(timeline, elapsed, cols, rows, first, last, scale=2, dt=0.45)
    save_timed_animation(frames, ASSETS / "timestamps.webp", elapsed)
    print(f"  real session duration: {elapsed:.1f}s")


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
    render(raw, ASSETS / "picker.webp", cols, rows, first=first)


def shot_wizard():
    """The interactive wizard, driven through a pty so it has a real TTY.

    Every prompt is answered by accepting its default, which is what makes the
    shot readable: the defaults are the thing worth showing. Enter is pressed
    on a timer until the transcript shows the write-confirmation prompt, then
    `y` answers that one -- rather than a fixed keystroke count sized for
    today's number of questions, which silently rots the next time a question
    is inserted before it (see capture_pty_until's docstring).
    """
    work = WORK / "wizard"
    home = work / "home" / ".claude"
    home.mkdir(parents=True, exist_ok=True)
    (home / "claude-timestamp.conf").write_text(DOCTOR_CONFIG)

    # rows raised from 58: the flow is now two questions longer (HISTORY, with
    # PROJECTS nested under it) and the full accept-every-default transcript
    # runs 66 rows tall at 84 columns. 58 scrolled the top of it away before
    # the write-confirmation prompt appeared; 72 leaves headroom above that.
    cols, rows = 84, 72
    # cwd pinned to the same directory as the fake HOME above -- see
    # capture_pty_until's docstring for why leaving cwd wherever this process
    # happens to be sitting makes the wizard's project-config walk climb past
    # this repository and read the generating machine's own account config
    # as a project layer.
    raw = capture_pty_until(
        ["bash", str(SCRIPTS / "setup.sh")],
        until="Write this configuration?", answer="y\r",
        cols=cols, rows=rows, settle=3, total=40,
        env={"HOME": str(work / "home"), "CLAUDE_TIMESTAMP_CONFIG": ""},
        cwd=str(work / "home"),
    )
    (work / "wizard.raw").write_bytes(raw)
    render(raw, ASSETS / "wizard.webp", cols, rows)


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
    render(raw, ASSETS / "doctor.webp", cols=84, rows=36, crlf=True)


def shot_stats():
    """The real --stats output over a synthetic history.

    The rows are made up, because a believable screenshot needs more sessions
    than this repository has accumulated. Everything else, the arithmetic and
    the formatting, is the real command.

    Fields 7 (project) and 8 (tool digest) are made up the same way the six
    timing fields always have been, in the same format ct_history_append and
    ct_tool_digest actually write: field 7 a bare project name or "-", field 8
    "Name:seconds:calls" entries, comma separated, worst first, at most 8. Two
    rows keep the "-" sentinel, so the by-project table's (unnamed) row -- what
    anyone with history from before PROJECTS existed will actually see -- is
    part of the picture rather than a hypothetical. Three named projects give
    the by-project table something to rank instead of one lone row. Every
    row's digest seconds sum to less than that row's own waited time (field
    4): the digest is tool execution time, a subset of the turn's total wait,
    and a digest that outran the wait would be visibly impossible to a reader
    who adds the row up. Bash dominates every row, because that is what real
    sessions look like.
    """
    work = WORK / "stats"
    (work / "home" / ".claude").mkdir(parents=True, exist_ok=True)
    (work / "home" / ".claude" / "claude-timestamp.conf").write_text(DOCTOR_CONFIG)

    history = work / "home" / ".claude" / "claude-timestamp-history.tsv"
    rows = [
        ("2026-08-04T09:12:00", 4820, 41, 1180, 900, 0, "claude-timestamp",
         "Bash:640:28,Read:210:54,Edit:95:22,Grep:40:18,WebFetch:35:3,Glob:12:9,Write:8:4,Task:5:1"),
        ("2026-08-05T10:41:00", 2260, 19, 540, 0, 1, "api-gateway",
         "Bash:310:14,Read:85:20,Edit:40:9,Grep:15:6,Write:10:3"),
        ("2026-08-06T08:55:00", 7415, 63, 2210, 3600, 2, "claude-timestamp",
         "Bash:1120:52,Read:340:70,Edit:180:40,Grep:95:25,WebFetch:60:5,Task:45:2,Glob:20:11,Write:15:6"),
        ("2026-08-07T14:02:00", 1180, 9, 260, 0, 0, "-",
         "Bash:140:8,Read:55:12,Edit:20:5,Grep:10:4"),
        ("2026-08-10T09:30:00", 5360, 44, 1490, 1800, 0, "claude-timestamp",
         "Bash:780:35,Read:260:58,Edit:130:28,Grep:70:20,WebFetch:45:4,Write:20:8,Glob:15:10"),
        ("2026-08-11T11:15:00", 3090, 27, 700, 0, 3, "api-gateway",
         "Bash:410:18,Read:110:24,Edit:55:12,WebFetch:35:3,Grep:20:9"),
        ("2026-08-12T09:05:00", 6240, 52, 1810, 2400, 1, "dashboard",
         "Bash:960:44,Read:300:62,Edit:160:33,Grep:85:22,Task:60:3,WebFetch:40:4,Glob:18:12,Write:12:5"),
        ("2026-08-13T16:20:00", 900, 6, 190, 0, 0, "-",
         "Bash:95:5,Read:40:9,Edit:15:4"),
        ("2026-08-17T10:00:00", 4100, 33, 1020, 1200, 0, "claude-timestamp",
         "Bash:540:24,Read:180:40,Edit:90:19,Grep:50:14,Write:25:9,Glob:10:7"),
        ("2026-08-19T09:45:00", 2980, 24, 660, 0, 1, "dashboard",
         "Bash:350:16,Read:120:26,Edit:60:13,WebFetch:30:2,Grep:18:8"),
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
    # rows raised from 22: the by-project and slowest-tools tables this
    # fixture now exercises add roughly a dozen lines to the report, and
    # render() crops to whatever the screen actually holds -- a screen too
    # short loses the top of the report rather than shrinking to fit.
    render(raw, ASSETS / "stats.webp", cols=64, rows=34, crlf=True)


# A bash snippet, not a hand-written table: it sources the library the plugin
# itself uses and calls the exact same ct_paint_part / ct_render_marker every
# hook calls, so what the gallery shows can never drift from what a real
# marker renders. `__LIB__` is substituted for lib/config.sh's real path
# before this runs.
#
# _display_width matches setup.sh's own _ct_display_width (same wc -c minus
# continuation-byte count, same LC_ALL=C) rather than inventing a second way
# to measure it: three of these templates carry a multi-byte character (`·`,
# `→`, `⟨⟩`), and padding by byte count would land their column short.
MARKERS_SCRIPT = r"""
set -euo pipefail
source "__LIB__"

_display_width() {
  local s="$1" bytes cont
  bytes="$(printf '%s' "$s" | wc -c | tr -d ' ')"
  cont="$(printf '%s' "$s" | LC_ALL=C tr -d -c '\200-\277' | wc -c | tr -d ' ')"
  printf '%d' "$((bytes - cont))"
}

templates=(
  '[{%date }%time{ %elapsed}{ · %tool}]'
  '%time'
  '%time{ %elapsed}'
  '%time{ → %elapsed}'
  '%time{ (%elapsed)}'
  '⟨%time⟩'
)

width=0
for tpl in "${templates[@]}"; do
  w="$(_display_width "$tpl")"
  [ "$w" -gt "$width" ] && width="$w"
done

render_row() {
  local tpl="$1" base="$2" time_color="$3" elapsed_color="$4" tool_color="$5" w pad
  ct_paint_part "$time_color"    "13:22:13"   "$base"; wp_time="$_CT_PART"
  ct_paint_part "$elapsed_color" "+2m14s"     "$base"; wp_elapsed="$_CT_PART"
  ct_paint_part "$tool_color"    "Bash 1m58s" "$base"; wp_tool="$_CT_PART"
  ct_render_marker "$tpl" "$wp_time" "$wp_elapsed" "$wp_tool" ""
  w="$(_display_width "$tpl")"
  pad=$(( width - w ))
  printf '  %s%*s  %s%s%s\n' "$tpl" "$pad" "" "$(ct_color_start "$base")" "$CT_MARKER" "$(ct_color_end "$base")"
}

echo "MARKER templates, rendered by the real code"
echo
for tpl in "${templates[@]}"; do
  render_row "$tpl" dim "" "" ""
done
echo
echo "Per-part colour (TIME_COLOR=gray ELAPSED_COLOR=cyan):"
render_row '%time{ %elapsed}' dim gray cyan ""
"""


def shot_markers():
    """A gallery of marker templates beside what each actually renders.

    Every row comes from running ct_paint_part and ct_render_marker, the same
    functions message-display.sh calls on every message, rather than typing
    out what a template "should" produce. FORCE_COLOR=1 makes this
    deterministic regardless of what invokes this script: the plugin only
    emits ANSI when it believes it is in a terminal, and a subprocess under a
    capture harness may not qualify as one on its own.
    """
    script = MARKERS_SCRIPT.replace("__LIB__", str(SCRIPTS / "lib" / "config.sh"))
    env = dict(os.environ)
    env["FORCE_COLOR"] = "1"
    env.pop("NO_COLOR", None)
    proc = subprocess.run(["bash", "-c", script], capture_output=True, env=env)
    raw = proc.stdout + proc.stderr
    work = WORK / "markers"
    work.mkdir(parents=True, exist_ok=True)
    (work / "markers.raw").write_bytes(raw)
    render(raw, ASSETS / "markers.webp", cols=100, rows=20, crlf=True)


SESSION_CONFIG = """\
TZ=Europe/Amsterdam
DISPLAY_FORMAT=24h
COLOR=dim
ELAPSED=on
SLOW_AFTER=60
IDLE_AFTER=3600
DATE_ROLLOVER=off
SUMMARY=on
SUBAGENTS=on
TOOL_TIMING=on
"""


def shot_session():
    """The idle divider and the end-of-session summary, from the real hooks.

    Exiting a live TUI under automation to capture the real end-of-session
    text does not go quietly (typing /exit opens the command autocomplete,
    and Ctrl-D is ignored whenever a history suggestion sits in the input), so
    this drives message-display.sh and session-end.sh directly with state
    planted the way tests/run.sh plants it -- see that file's "turn
    accounting" and "session summary" sections for the same pattern. The
    divider, the marker and the summary line are the hooks' own real output;
    only the state that produces them, and the message text the divider sits
    above, are made up for the shot.

    The planted numbers reproduce the README's own worked example (1h30m
    over 12 turns, 24m18s waiting, 35m00s away, and the three-tool timing
    line with two failures) rather than arbitrary ones, so the shot and the
    prose beside it describe the same session.
    """
    work = WORK / "session"
    home = work / "home" / ".claude"
    home.mkdir(parents=True, exist_ok=True)
    conf = work / "config.conf"
    conf.write_text(SESSION_CONFIG)
    tmp = work / "tmp"
    # Mirrors ct_state_dir_var in hooks/scripts/lib/state.sh, which is per-uid:
    # "${TMPDIR:-/tmp}/claude-timestamp-${UID:-0}". Planting state under the
    # old shared name leaves session-end.sh with nothing to summarise, and it
    # then prints nothing at all rather than failing loudly.
    state_dir = tmp / f"claude-timestamp-{os.getuid()}"
    state_dir.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    env["HOME"] = str(work / "home")
    env["CLAUDE_TIMESTAMP_CONFIG"] = str(conf)
    env["TMPDIR"] = str(tmp)

    sid = "demo-session"
    base = state_dir / sid
    now = int(time.time())

    # The away figure is measured and staged by user-prompt-submit.sh, which is
    # the only hook that sees both ends of the gap; message-display.sh draws it
    # and clears it so a break is marked exactly once. Planting ".last" alone
    # no longer produces a divider -- that was the pre-remediation mechanism,
    # where the display hook derived the gap itself and double-counted the
    # model's own latency into it. Plant ".away" the way the prompt hook does.
    #
    # No turn is left open (base itself is never written), so the marker on
    # this message carries a time and nothing else -- exactly what
    # message-display.sh draws for a message with no turn in progress.
    (state_dir / f"{sid}.last").write_text(str(now - 7200))
    (state_dir / f"{sid}.away").write_text("7200")
    proc = subprocess.run(
        ["bash", str(SCRIPTS / "message-display.sh")],
        input=json.dumps({
            "session_id": sid, "index": 0,
            "delta": "Sounds good, picking this up where we left off.",
        }),
        capture_output=True, env=env, text=True,
    )
    display = json.loads(proc.stdout)["hookSpecificOutput"]["displayContent"]

    # The end-of-session summary: state planted directly, the same way
    # tests/run.sh's "session summary" cases plant .start/.turns/.wait/.idle
    # and a .tools log before calling session-end.sh.
    (state_dir / f"{sid}.start").write_text(str(now - 5400))
    (state_dir / f"{sid}.turns").write_text("12")
    (state_dir / f"{sid}.wait").write_text("1458")
    (state_dir / f"{sid}.idle").write_text("2100")
    tools = (
        "Bash 2.000 ok\n" * 17 + "Bash 7.200 fail\n"
        "WebFetch 8.100 fail\n"
        + "Read 0.054 ok\n" * 36 + "Read 0.056 ok\n"
    )
    (state_dir / f"{sid}.tools").write_text(tools)
    proc = subprocess.run(
        ["bash", str(SCRIPTS / "session-end.sh")],
        input=json.dumps({"session_id": sid}),
        capture_output=True, env=env, text=True,
    )
    summary = json.loads(proc.stdout)["systemMessage"]

    raw = (display + "\n\n" + summary + "\n").encode()
    (work / "session.raw").write_bytes(raw)
    render(raw, ASSETS / "session.webp", cols=100, rows=20, crlf=True)


SHOTS = {"hero": shot_hero, "picker": shot_picker, "wizard": shot_wizard,
         "doctor": shot_doctor, "stats": shot_stats,
         "markers": shot_markers, "session": shot_session}

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = list(SHOTS) if which == "all" else [which]
    # Before any shot stages a HOME, a config or a state tree under WORK.
    _secure_work()
    for n in names:
        if n not in SHOTS:
            raise SystemExit(f"unknown shot: {n}. Pick from: {', '.join(SHOTS)}, all")
        print(f"--- {n}")
        SHOTS[n]()
