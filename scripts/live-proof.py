#!/usr/bin/env python3
"""Drive a running Zed and capture what a patch actually renders.

`verify.sh` and `check-sync.sh` answer mechanically -- the series applies, the
three relations agree. What they cannot answer is whether a patch renders what it
claims once a person is looking at it. This is that half, automated, so a live
proof stops being human-at-the-keyboard work.

Input goes through `xdg-desktop-portal-kde`, NOT ydotool: the portal needs no
root, only a one-time consent dialog whose restore token is kept. (zeo's
`scripts/shot.sh` drove the same desktop with ydotool and had to ask for
`sudo ydotoold`.)

Two interfaces, ONE session handle. That pairing is not optional here: the KDE
portal logs `xdp-kde-remotedesktop: Only stream input` and refuses to act on input
notifications unless a ScreenCast stream is bound to the same session. A
RemoteDesktop-only session starts cleanly, accepts every Notify* call and does
nothing at all -- the failure is silent, which is why it is named here.

Usage:
    live-proof.py probe                 open the session, report the stream
    live-proof.py type   <text>         type a string into the focused window
    live-proof.py key    <keysym>...    press/release keysyms in order
    live-proof.py script <file.json>    run a list of steps

Steps: {"focus": "<project>"} | {"type": "..."} | {"key": [...]} |
{"chord": [...]} | {"click": [x, y]} | {"move": [x, y]} | {"drag": [...]} |
{"sleep": 0.5} | {"shot": "path.png", "window": true}

COORDINATES ARE SCREEN COORDINATES, and two corrections compose on the way there.
A window capture is 2560x1044 while the stream is 2560x1080, so screen_y =
capture_y + 36; and any coordinate read off a *displayed* image must be scaled to
the PNG first. Applying one without the other silently misses, and a miss types
into whatever is behind.

Two guards are borrowed from `zeo`'s shot.sh, which learned both the hard way:
the session-lock check (a locked session yields well-formed pictures of nothing)
and verifying every capture decodes at a sane size. Evidence nobody interrogated
is an argument, not an observation.

Exit: 0 ok - 1 refused/failed - 2 environment problem.
"""

import json
import os
import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

TOKEN_PATH = os.path.expanduser("~/.cache/zed-live-proof-restore-token.json")

KEYBOARD, POINTER = 1, 2
MONITOR = 1
CURSOR_EMBEDDED = 2
PERSIST_UNTIL_REVOKED = 2

# X11 keysyms for the names used in scripts. Printable ASCII is handled by
# codepoint, so only the non-printing keys need naming.
NAMED_KEYSYMS = {
    "Return": 0xFF0D, "Escape": 0xFF1B, "BackSpace": 0xFF08, "Tab": 0xFF09,
    "Up": 0xFF52, "Down": 0xFF54, "Left": 0xFF51, "Right": 0xFF53,
    "Home": 0xFF50, "End": 0xFF57, "Delete": 0xFFFF, "space": 0x0020,
    "Control_L": 0xFFE3, "Shift_L": 0xFFE1, "Alt_L": 0xFFE9, "Super_L": 0xFFEB,
}


class Portal:
    def __init__(self):
        DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SessionBus()
        obj = self.bus.get_object(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"
        )
        self.remote = dbus.Interface(obj, "org.freedesktop.portal.RemoteDesktop")
        self.cast = dbus.Interface(obj, "org.freedesktop.portal.ScreenCast")
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")
        self.loop = GLib.MainLoop()
        self.counter = 0
        self.result = None
        self.session = None
        self.stream = None

    def _request(self, call, *args, options=None):
        self.counter += 1
        token = f"zedproof{self.counter}"
        path = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"
        self.result = None

        def on_response(code, results):
            self.result = (int(code), results)
            self.loop.quit()

        match = self.bus.add_signal_receiver(
            on_response, signal_name="Response",
            dbus_interface="org.freedesktop.portal.Request", path=path,
        )
        opts = dict(options or {})
        opts["handle_token"] = token
        call(*args, opts)

        timeout = GLib.timeout_add_seconds(120, self.loop.quit)
        self.loop.run()
        GLib.source_remove(timeout)
        match.remove()

        if self.result is None:
            raise TimeoutError("the portal never answered (dialog left open?)")
        return self.result

    def open(self):
        code, res = self._request(
            self.remote.CreateSession, options={"session_handle_token": "zedproof"}
        )
        if code != 0:
            raise RuntimeError(f"CreateSession refused ({code})")
        self.session = res["session_handle"]

        restore = None
        if os.path.exists(TOKEN_PATH):
            with open(TOKEN_PATH) as fh:
                restore = json.load(fh).get("restore_token")

        dev_opts = {
            "types": dbus.UInt32(KEYBOARD | POINTER),
            "persist_mode": dbus.UInt32(PERSIST_UNTIL_REVOKED),
        }
        if restore:
            dev_opts["restore_token"] = restore
        code, _ = self._request(self.remote.SelectDevices, self.session,
                                options=dev_opts)
        if code != 0:
            raise RuntimeError(f"SelectDevices refused ({code})")

        # The half a RemoteDesktop-only session silently lacks.
        code, _ = self._request(
            self.cast.SelectSources, self.session,
            options={
                "types": dbus.UInt32(MONITOR),
                "multiple": False,
                "cursor_mode": dbus.UInt32(CURSOR_EMBEDDED),
            },
        )
        if code != 0:
            raise RuntimeError(f"SelectSources refused ({code})")

        code, res = self._request(self.remote.Start, self.session, "")
        if code != 0:
            raise RuntimeError(f"Start refused ({code}; 1 = cancelled)")

        streams = res.get("streams") or []
        if not streams:
            raise RuntimeError("started with no stream — input would be ignored")
        node_id, props = streams[0]
        self.stream = int(node_id)

        if "restore_token" in res:
            os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
            with open(TOKEN_PATH, "w") as fh:
                json.dump({"restore_token": str(res["restore_token"])}, fh)
            os.chmod(TOKEN_PATH, 0o600)

        size = tuple(props.get("size", (0, 0)))
        print(f"session {self.session}\nstream node {self.stream} size {size}")
        return self.stream

    # --- injection ----------------------------------------------------------

    def _keysym(self, sym, pressed):
        self.remote.NotifyKeyboardKeysym(
            self.session, {}, dbus.Int32(sym), dbus.UInt32(1 if pressed else 0)
        )

    def key(self, name, hold=0.012):
        sym = NAMED_KEYSYMS.get(name)
        if sym is None:
            if len(name) != 1:
                raise ValueError(f"unknown key name: {name!r}")
            sym = ord(name)
        self._keysym(sym, True)
        time.sleep(hold)
        self._keysym(sym, False)
        time.sleep(hold)

    def type(self, text):
        for ch in text:
            self.key("space" if ch == " " else ch)

    # Absolute motion is what needs the stream: the coordinates are expressed
    # inside that stream's space, which is why a RemoteDesktop-only session has
    # nowhere to put them.
    def move(self, x, y):
        self.remote.NotifyPointerMotionAbsolute(
            self.session, {}, dbus.UInt32(self.stream),
            dbus.Double(float(x)), dbus.Double(float(y)),
        )
        time.sleep(0.05)

    def click(self, x=None, y=None, button=0x110):  # 0x110 = BTN_LEFT
        if x is not None:
            self.move(x, y)
        self.remote.NotifyPointerButton(
            self.session, {}, dbus.Int32(button), dbus.UInt32(1)
        )
        time.sleep(0.05)
        self.remote.NotifyPointerButton(
            self.session, {}, dbus.Int32(button), dbus.UInt32(0)
        )
        time.sleep(0.1)

    def drag(self, x1, y1, x2, y2, steps=18, button=0x110):
        """Press at one point, glide, release at another.

        The glide is not decoration: a press followed by a single jump to the
        destination is read by most drag handlers as a click, because they need
        motion events between the two to recognise a drag at all.
        """
        self.move(x1, y1)
        self.remote.NotifyPointerButton(
            self.session, {}, dbus.Int32(button), dbus.UInt32(1)
        )
        time.sleep(0.12)
        for i in range(1, steps + 1):
            self.move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
        time.sleep(0.12)
        self.remote.NotifyPointerButton(
            self.session, {}, dbus.Int32(button), dbus.UInt32(0)
        )
        time.sleep(0.2)

    def chord(self, mods, key):
        syms = [NAMED_KEYSYMS[m] for m in mods]
        for s in syms:
            self._keysym(s, True)
        time.sleep(0.02)
        self.key(key)
        for s in reversed(syms):
            self._keysym(s, False)
        time.sleep(0.02)


HERE = os.path.dirname(os.path.abspath(__file__))

# The project whose Zed window hosts this very conversation. Injecting while it
# holds focus types into the agent composer that is running the injector — the
# whole reason this guard exists rather than a comment saying "be careful".
HOST_PROJECT = os.environ.get("PORTAL_HOST_PROJECT", "zed")


def active_window():
    """Caption of the focused window, read through KWin — never through input."""
    run = subprocess.run(
        [os.path.join(HERE, "kwin-window.sh"), "active"],
        capture_output=True, text=True, timeout=30,
    )
    if run.returncode != 0:
        raise RuntimeError(f"cannot read the active window: {run.stderr.strip()}")
    parts = run.stdout.strip().split("|", 1)
    return parts[1].strip() if len(parts) == 2 else ""


def guard(expected=None):
    """Refuse to inject into the hosting window, or into an unexpected one."""
    caption = active_window()
    project = caption.split("—")[0].strip()
    if project == HOST_PROJECT:
        raise RuntimeError(
            f"refusing to inject: active window is {caption!r}, whose project "
            f"is {HOST_PROJECT!r} — that is the window running this session"
        )
    # An expected value with no em dash names the project, not the caption:
    # the caption's second half is the open file and changes under us.
    if expected:
        want = expected.strip()
        got = caption if "\u2014" in want else project
        if got != want:
            raise RuntimeError(f"active window is {caption!r}, expected {want!r}")
    return caption


def focus(caption):
    run = subprocess.run(
        [os.path.join(HERE, "kwin-window.sh"), "focus", caption],
        capture_output=True, text=True, timeout=30,
    )
    if run.returncode != 0:
        raise RuntimeError(f"cannot focus {caption!r}: {run.stdout.strip()}")
    time.sleep(0.5)
    return guard(caption)


def session_is_locked():
    """True when the login session is locked.

    Borrowed from `zeo`'s shot.sh, which found it the hard way: KWin does not
    paint windows the lock screen occludes, so `spectacle -a` returns a
    perfectly well-formed PNG of an empty pane, sized right, named right,
    exit 0. That is worse than a crash — a MISSING capture is noticed and a
    blank one is filed as evidence. So the check runs BEFORE anything is
    captured, not after.
    """
    session = os.environ.get("XDG_SESSION_ID", "")
    if not session:
        listed = subprocess.run(
            ["loginctl", "--no-legend", "list-sessions"],
            capture_output=True, text=True, timeout=15,
        )
        user = os.environ.get("USER") or ""
        for line in listed.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] == user:
                session = parts[0]
                break
    if not session:
        return False
    run = subprocess.run(
        ["loginctl", "show-session", session, "--property=LockedHint", "--value"],
        capture_output=True, text=True, timeout=15,
    )
    return run.stdout.strip() == "yes"


# A capture smaller than this in either axis is not a screenshot of anything.
# The number is deliberately low: it is a floor against the degenerate case, not
# an assertion about window size.
MIN_CAPTURE_PX = 200


def verify_capture(path):
    """Prove the file decodes and is not degenerate.

    The failure this exists for is on record: a 1x1, 1-bit greyscale PNG once sat
    among committed proofs looking exactly like evidence — non-zero, decodable,
    correctly named. `magick` is the verifier here for the same reason shot.sh
    keeps it: a capture nobody interrogated is an argument, not an observation.
    """
    run = subprocess.run(
        ["magick", "identify", "-format", "%w %h %m", path],
        capture_output=True, text=True, timeout=30,
    )
    if run.returncode != 0:
        raise RuntimeError(f"{path} does not decode as an image: {run.stderr.strip()}")
    width, height, fmt = run.stdout.split()
    if int(width) < MIN_CAPTURE_PX or int(height) < MIN_CAPTURE_PX:
        raise RuntimeError(
            f"{path} is {width}x{height} {fmt} — too small to be a capture of "
            f"anything (floor {MIN_CAPTURE_PX}px). Not kept."
        )
    return int(width), int(height)


def shot(path, window=True):
    """Capture with spectacle: grim cannot work here (KWin has no wlr-screencopy).

    Window-only by default. A full-screen shot always catches the portal's own
    "remote control session started" notification, which sits over the top-right
    corner for as long as the session lives -- exactly where this sidebar draws
    its search field. Capturing the active window alone excludes it, because the
    notification is a separate window.
    """
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    mode = "-a" if window else "-f"
    run = subprocess.run(
        ["spectacle", "-b", "-n", mode, "-o", path],
        capture_output=True, text=True, timeout=60,
    )
    if run.returncode != 0 or not os.path.exists(path):
        raise RuntimeError(f"spectacle failed: {run.stderr.strip() or run.returncode}")
    try:
        width, height = verify_capture(path)
    except RuntimeError:
        # Refuse to leave a rejected capture on disk: a file that failed
        # verification is exactly the artefact somebody later mistakes for proof.
        os.unlink(path)
        raise
    print(f"captured {path} ({width}x{height}, {os.path.getsize(path)} bytes)")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[1]

    if session_is_locked():
        raise RuntimeError(
            "the session is locked: every capture would be a well-formed picture "
            "of nothing, and injected input would go to the lock screen"
        )

    portal = Portal()
    portal.open()
    # The compositor needs a moment before it routes injected events.
    time.sleep(0.4)

    if mode == "probe":
        print("OK — stream bound, input would be accepted. Nothing injected.")
    elif mode == "type":
        portal.type(argv[2])
    elif mode == "key":
        for name in argv[2:]:
            portal.key(name)
    elif mode == "script":
        with open(argv[2]) as fh:
            steps = json.load(fh)
        target = None
        for step in steps:
            # Every step that injects re-checks focus first. Checking once at the
            # start is not enough: a notification or a stray click between steps
            # moves focus, and the next keystroke would land somewhere else.
            if "focus" in step:
                target = step["focus"]
                print(f"focused: {focus(target)}")
            elif "type" in step:
                guard(target)
                portal.type(step["type"])
            elif "key" in step:
                guard(target)
                for name in step["key"]:
                    portal.key(name)
            elif "chord" in step:
                guard(target)
                portal.chord(step["chord"][:-1], step["chord"][-1])
            elif "click" in step:
                guard(target)
                portal.click(*step["click"])
            elif "move" in step:
                guard(target)
                portal.move(*step["move"])
            elif "drag" in step:
                guard(target)
                portal.drag(*step["drag"])
            elif "sleep" in step:
                time.sleep(float(step["sleep"]))
            elif "shot" in step:
                shot(step["shot"], window=step.get("window", True))
            else:
                raise ValueError(f"unknown step: {step}")
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (TimeoutError, RuntimeError, ValueError) as err:
        print(f"failed: {err}", file=sys.stderr)
        sys.exit(1)
    except dbus.DBusException as err:
        print(f"dbus: {err}", file=sys.stderr)
        sys.exit(2)
