# -*- coding: utf-8 -*-
"""End-to-end drive of campus_atlas: one browser sign-in unlocks the app.

Chain measured live on 2026-10-18 (docs/grades-and-reviews.md §5.6):

  更多 → 正方教务 → 在应用内浏览器查成绩
  → CAS page inside WebView2 (person may need the slider here)
  → 设为应用会话 (adopt handshake: "9 cookies harvested…")
  → 直达成绩查询 → (optionally pick a 学年) → page 查询
  → [slider: the PERSON's step — the script only detects it and stops]
  → after it is cleared: `read` parses the sheet and verifies rows.

The script NEVER moves the slider. No drag, no replay, no CAPTCHA bypass —
the app's contract is read-only toward the challenge; the person answers it.

Usage (from the repo root; release exe must be running or it is started):
  pip install uiautomation pillow
  set E2E_STUDENT_ID=<学号> & set E2E_PASSWORD=<密码>
  python scripts/e2e/run_e2e.py full 2025-2026   # drive up to the slider
  python scripts/e2e/run_e2e.py read             # after the person clears it

Credentials travel ONLY through environment variables; nothing is written into
this file or the logs. Screenshots/logs land in %TEMP%\campus_atlas_e2e.
uiautomation note: use direct attributes (c.Name), never c.Current.*.
"""
import ctypes
import os
import re
import subprocess
import sys
import time

import uiautomation as uia
from PIL import ImageGrab

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(_REPO, "build", "windows", "x64", "runner", "Release",
                   "campus_atlas.exe")
WINDOW_CLASS = "FLUTTER_RUNNER_WIN32_WINDOW"
WINDOW_NAME = "campus_atlas"

DUMP_ROOT = os.environ.get(
    "CAMPUS_ATLAS_E2E_DUMP",
    os.path.join(os.environ.get("TEMP", os.getcwd()), "campus_atlas_e2e"))
SHOTS = DUMP_ROOT
LOG_PATH = os.path.join(SHOTS, "e2e_log.txt")

STUDENT_ID = os.environ.get("E2E_STUDENT_ID", "")
PASSWORD = os.environ.get("E2E_PASSWORD", "")

MORE_TAB = "更多"
JW_TILE = "正方教务"
WALL_CTA = "登录统一认证"
MENU_CTA = "读取学生菜单"
BROWSER_CTA = "在应用内浏览器查成绩"
TIP_ADOPT = "设为应用会话"
TIP_DIRECT = "直达成绩查询"
TIP_READ = "读取成绩"
SLIDER_TEXT = "请拖动左侧滑块还原图片"


def log(msg):
    line = "[e2e] %s" % msg
    try:
        os.makedirs(SHOTS, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name + ".png")
    try:
        ImageGrab.grab(all_screens=True).save(path)
        log("shot %s" % name)
        return path
    except Exception as e:
        log("shot %s FAILED %r" % (name, e))
        return None


_user32 = ctypes.windll.user32


_kernel32 = ctypes.windll.kernel32
_user32.GetClipboardData.restype = ctypes.c_void_p
_kernel32.GlobalLock.restype = ctypes.c_void_p
_kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
_kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]


def clipboard_text():
    _user32.OpenClipboard(None)
    try:
        h = _user32.GetClipboardData(13)  # CF_UNICODETEXT
        p = _kernel32.GlobalLock(h)
        try:
            return ctypes.wstring_at(p) if p else ""
        finally:
            _kernel32.GlobalUnlock(h)
    finally:
        _user32.CloseClipboard()


def get_window(timeout=30):
    w = uia.WindowControl(searchDepth=1, ClassName=WINDOW_CLASS,
                          Name=WINDOW_NAME)
    return w if w.Exists(timeout, 0.3) else None


def start_app(reuse=True):
    proc = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq campus_atlas.exe", "/FO", "CSV"],
        capture_output=True, text=True, encoding="gbk", errors="replace")
    if reuse and "campus_atlas.exe" in proc.stdout:
        log("app already running, reusing")
        win = get_window()
        return place_window(win)
    log("starting %s" % EXE)
    subprocess.Popen([EXE], close_fds=True)
    time.sleep(3)
    return place_window(get_window(45))


def place_window(win):
    """Put the app window at a known position and size.

    Two traps, both measured:

    * The window keeps whatever position the last run left it in, and every
      click in this script is an absolute screen coordinate taken from the
      accessibility tree. A window that moved between the tree dump and the
      click sends the click to whatever is underneath it — which is how a
      click meant for the app's own button ends up in another program.
    * The Flutter view is taller than the window frame the runner starts with
      (1600×1207 against a 1600×900 frame). The accessibility tree reports
      positions in **view** coordinates, so with a shorter frame the tree
      points below the screen and the click lands on another window. The
      window is therefore sized to the view.
    """
    if win is None:
        return None
    r = win.BoundingRectangle
    if (r.left, r.top) == (12, 12) and (r.right - r.left) >= 1200 \
            and (r.bottom - r.top) >= 1200:
        return win
    hwnd = win.NativeWindowHandle
    if hwnd:
        ctypes.windll.user32.MoveWindow(hwnd, 12, 12, 1600, 1207, True)
        time.sleep(1.2)
        win = get_window()
    return win


def force_foreground(hwnd):
    """SetForegroundWindow is refused for non-foreground processes; go in
    through AttachThreadInput (the classic desktop-entry trick)."""
    fg = _user32.GetForegroundWindow()
    cur = _kernel32.GetCurrentThreadId()
    fg_thread = _user32.GetWindowThreadProcessId(fg, None)
    tgt_thread = _user32.GetWindowThreadProcessId(hwnd, None)
    _user32.AttachThreadInput(cur, fg_thread, True)
    _user32.AttachThreadInput(cur, tgt_thread, True)
    try:
        _user32.ShowWindow(hwnd, 9)  # SW_RESTORE
        _user32.BringWindowToTop(hwnd)
        ok = _user32.SetForegroundWindow(hwnd)
    finally:
        _user32.AttachThreadInput(cur, fg_thread, False)
        _user32.AttachThreadInput(cur, tgt_thread, False)
    return ok


def force_foreground_topmost(hwnd):
    """Bring a window forward by making it topmost for a moment.

    When another application owns the foreground and keeps taking it back,
    AttachThreadInput is refused. A topmost round trip is the reliable way:
    the window is painted above everything, then the flag is taken away again.
    """
    SWP_NOMOVE = 0x0002
    SWP_NOSIZE = 0x0001
    HWND_TOPMOST = -1
    HWND_NOTOPMOST = -2
    _user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE)
    time.sleep(0.25)
    _user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE)
    time.sleep(0.25)
    return _user32.GetForegroundWindow() == hwnd


_WIN = None


def focus_app(tries=5):
    """Bring the app forward, best effort.

    A hung window in another application can hold the foreground in a DWM
    "ghost" window that Windows will not release (measured: a ghost of an
    unresponsive workbuddy process). The click itself still goes to the window
    under the pointer, so the *safety* check lives in [click_center] — it
    verifies the point belongs to the app before clicking. Here the goal is
    only that the app is on top and takes the keyboard.
    """
    target = _WIN.NativeWindowHandle if _WIN else None
    for i in range(tries):
        fg = _user32.GetForegroundWindow()
        if target and fg == target:
            return True
        if i == 0:
            try:
                _WIN.SetActive()
            except Exception:
                pass
            time.sleep(0.4)
        elif i == 1:
            force_foreground(target)
            time.sleep(0.4)
        elif i == 2:
            force_foreground(target)
            time.sleep(0.6)
        else:
            force_foreground_topmost(target)
            time.sleep(0.5)
    # Windows refuses SetForegroundWindow to a process that is not already
    # allowed to take the focus. A real click on the window's own title bar
    # is what a person would do, and it is what actually works.
    activate_by_title_bar()
    fg = _user32.GetForegroundWindow()
    if target and fg == target:
        return True
    log("foreground is held by another window (hwnd=%s) — continuing, the "
        "click check decides where the click lands" % fg)
    return False


def _process_of(hwnd):
    pid = ctypes.c_ulong()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def _window_at(x, y):
    class _POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
    return _user32.WindowFromPoint(_POINT(x, y))


def point_belongs_to_app(x, y):
    """Is the point over the app's own window?

    This is the check that protects other programs. The foreground can be
    held by an unrelated window; what matters is whether the pixel under the
    pointer belongs to the app, and a click is delivered to the window under
    the pointer anyway.

    The in-app browser is a **child** of the app's window (the WebView2
    widget chain ends at the Flutter window), so the parent chain is walked:
    a point over the page counts as the app's own.
    """
    if _WIN is None:
        return False
    app_hwnd = _WIN.NativeWindowHandle
    hwnd = _window_at(x, y)
    for _ in range(8):
        if not hwnd:
            return False
        if hwnd == app_hwnd:
            return True
        parent = _user32.GetParent(hwnd)
        if not parent or parent == hwnd:
            break
        hwnd = parent
    return _process_of(hwnd) == _process_of(app_hwnd)


def activate_by_title_bar():
    """Click the app's title bar to bring the window forward.

    The click lands on the window caption, never on a control: the bar's
    left half is empty space, and the buttons on the right are the window's
    own (minimise / maximise / close) — the middle is the safe spot.

    The point is checked first: if another window is on top at that
    coordinate, the click would land on *its* title bar and bring it
    forward instead — the opposite of what this is for.
    """
    if _WIN is None:
        return
    try:
        r = _WIN.BoundingRectangle
        x = int(r.left + (r.right - r.left) / 2)
        y = int(r.top + 18)
        if not point_belongs_to_app(x, y):
            return
        uia.Click(x, y, waitTime=0.3)
        time.sleep(0.6)
    except Exception as e:
        log("title bar activation failed: %r" % e)


def flutter_pane(w):
    for k in w.GetChildren():
        if k.ClassName == "FLUTTERVIEW":
            return k
    return w


def walk(root, depth, fn, _d=0):
    if _d > depth:
        return False
    try:
        if fn(root):
            return True
    except Exception:
        pass
    try:
        kids = root.GetChildren()
    except Exception:
        return False
    for k in kids:
        if walk(k, depth, fn, _d + 1):
            return True
    return False


def find_all(w, pred, depth=50):
    found = []

    def hit(c):
        try:
            if pred(c):
                found.append(c)
        except Exception:
            pass
        return False

    walk(w, depth, hit)
    return found


def find_exact(w, name, depth=50):
    f = find_all(w, lambda c: c.Name == name, depth)
    return f[0] if f else None


def find_contains(w, needle, depth=50):
    f = find_all(
        w, lambda c: isinstance(c.Name, str) and needle in c.Name, depth)
    return f[0] if f else None


def set_topmost(on):
    """Put the app window above everything else (or take that back)."""
    if _WIN is None:
        return
    SWP_NOMOVE = 0x0002
    SWP_NOSIZE = 0x0001
    HWND_TOPMOST = -1
    HWND_NOTOPMOST = -2
    _user32.SetWindowPos(_WIN.NativeWindowHandle,
                         HWND_TOPMOST if on else HWND_NOTOPMOST,
                         0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE)


def click_center(el, label=""):
    # The window can be dragged between the moment a control was found and
    # the moment it is clicked, and a stale rectangle sends the click to
    # whatever is at that pixel. Put the window back first, then read the
    # rectangle.
    if _WIN is not None:
        place_window(_WIN)
    r = el.BoundingRectangle
    cx, cy = int((r.left + r.right) / 2), int((r.top + r.bottom) / 2)
    focus_app()
    raised = False
    if not point_belongs_to_app(cx, cy):
        # Another window is on top there — a chat client with a Chromium
        # view, a browser, a hung ghost. Raising the app above it is worth
        # one try: a click that lands on somebody else's window is not a
        # click at all.
        set_topmost(True)
        raised = True
        time.sleep(0.5)
        if not point_belongs_to_app(cx, cy):
            set_topmost(False)
            raise RuntimeError("(%d,%d) is not over the app window; refusing "
                               "the click on %s (protecting other windows)"
                               % (cx, cy, label))
    log("click %s at (%d,%d)" % (label, cx, cy))
    uia.Click(cx, cy, waitTime=0.25)
    if raised:
        time.sleep(0.3)
        set_topmost(False)
    return cx, cy


def tree_texts(w, depth=50):
    names = []

    def collect(c):
        try:
            n = c.Name
        except Exception:
            return False
        if isinstance(n, str) and n and n not in names:
            names.append(n)
        return False

    walk(w, depth, collect)
    return names


def save_texts(name, w):
    texts = tree_texts(w)
    os.makedirs(SHOTS, exist_ok=True)
    with open(os.path.join(SHOTS, name + ".txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(texts))
    log("%s: %d controls" % (name, len(texts)))
    return texts


def find_webview(w):
    f = find_all(w, lambda c: isinstance(c.ClassName, str)
                 and c.ClassName.startswith("Chrome"), 14)
    # the deepest Chrome pane is the document root
    return f


def has_slider():
    return find_contains(_WIN, SLIDER_TEXT) is not None


# ---------------------------------------------------------------- flow

def goto_jwgl(w):
    pane = flutter_pane(w)
    more = wait_for_name(w, MORE_TAB)
    if more:
        click_center(more, "更多 tab")
    else:
        r = pane.BoundingRectangle
        uia.Click(int(r.right - 160), int((r.top + r.bottom) / 2 + 380),
                  waitTime=0.25)
        log("clicked 更多 by frac")
    time.sleep(1.5)
    shot("01_more")
    tile = wait_for_name(w, JW_TILE)
    if tile is None:
        raise RuntimeError("正方教务 tile not found")
    click_center(tile, "教务 tile")
    time.sleep(2)
    shot("02_jwgl_screen")


def wait_for_name(w, needle, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c = find_contains(w, needle)
        if c:
            return c
        time.sleep(0.8)
    return None


def close_cas_form_if_open(w):
    if find_exact(w, "学号或工号"):
        log("CAS form open -> 取消")
        cancel = find_exact(w, "取消")
        if cancel:
            click_center(cancel, "取消")
            time.sleep(2)
        if find_exact(w, "学号或工号"):
            raise RuntimeError("CAS form did not close")


def web_fill_input(el, text, expect_readback=True):
    """Fill a web input: click, VERIFY the focused element is this one
    (by AutomationId), then type. Focus verification is essential — a
    miss typed the password into the username box (measured)."""
    r = el.BoundingRectangle
    w = r.right - r.left
    for attempt, fx in enumerate((0.45, 0.65, 0.30)):
        focus_app()
        cx = int(r.left + w * fx)
        cy = int((r.top + r.bottom) / 2)
        uia.Click(cx, cy, waitTime=0.25)
        time.sleep(0.4)
        f = uia.GetFocusedControl()
        fid = ""
        try:
            fid = f.AutomationId
        except Exception:
            pass
        want = el.AutomationId
        log("fill %r: clicked (fx=%.2f) focused id=%r (want %r)" %
            (text[:3], fx, fid, want))
        if want and fid == want:
            uia.SendKeys("{Ctrl}a{Del}", waitTime=0.1)
            uia.SendKeys(text, waitTime=0.02)
            time.sleep(0.3)
            if expect_readback:
                val = ""
                try:
                    val = el.GetValuePattern().Value
                except Exception:
                    pass
                ok = val == text
                log("fill %r verified readback=%s" % (
                    text[:3], "OK(%d chars)" % len(val) if val
                    else "EMPTY"))
                if ok:
                    return True
                continue
            return True
        time.sleep(0.4)
    log("fill %r FAILED after retries" % text[:3])
    return False


def find_web_input(page, keys):
    """Find a web edit by AutomationId (DOM id) first, then by Name."""
    for key in keys:
        for c in find_all(page, lambda c: c.AutomationId == key
                          and c.ControlTypeName == "EditControl", 40):
            return c
    for key in keys:
        for c in find_all(page, lambda c: c.Name == key
                          and c.ControlTypeName == "EditControl", 40):
            return c
    return None


def browser_sign_in(page):
    """Fill the CAS form that the in-app browser is showing and submit."""
    user = find_web_input(page, ["username", "学工号/用户名/手机"])
    pwd = find_web_input(page, ["password", "请输入密码"])
    if user is None or pwd is None:
        save_texts("browser_no_inputs", _WIN)
        shot("browser_no_inputs")
        raise RuntimeError("CAS web inputs not found")
    log("web inputs: user=%r pwd=%r" % (
        user.AutomationId or user.Name, pwd.AutomationId or pwd.Name))
    if not web_fill_input(user, STUDENT_ID):
        raise RuntimeError("username fill failed")
    # The password input does not take mouse focus at any point of its
    # exposed rect (measured: every click returned focus to username or
    # RootWebArea) — walk there by Tab from the verified username focus.
    filled = False
    for i in range(4):
        uia.SendKeys("{Tab}", waitTime=0.15)
        time.sleep(0.3)
        f = uia.GetFocusedControl()
        fid = ""
        try:
            fid = f.AutomationId
        except Exception:
            pass
        log("tab %d -> focused id=%r name=%r" % (i, fid, f.Name))
        if fid == user.AutomationId:
            continue
        if fid == "password":
            uia.SendKeys("{Ctrl}a{Del}", waitTime=0.1)
            uia.SendKeys(PASSWORD, waitTime=0.02)
            filled = True
            break
    if not filled:
        raise RuntimeError("password focus unreachable via tab (4 tabs)")
    shot("04_cas_filled")

    if has_slider():
        log("SLIDER already on the page before login")
        return "slider-before-submit"

    btn = None
    for cand in find_all(page, lambda c: True, 40):
        n = cand.Name
        if isinstance(n, str) and (n == "登录" or n == "登 录"):
            btn = cand
            break
    if btn is None:
        save_texts("browser_no_submit", _WIN)
        raise RuntimeError("CAS submit button not found")
    try:
        click_center(btn, "CAS 登录 (web)")
    except RuntimeError as e:
        # Another window may be sitting on top of the page's button. The
        # keyboard is not affected by z-order: the password field has the
        # focus, and Enter submits the form.
        log("submit by keyboard (%s)" % e)
        uia.SendKeys("{Enter}", waitTime=0.2)
    time.sleep(6)
    shot("05_cas_web_post_login")

    if has_slider():
        log("SLIDER appeared on login")
        return "slider"
    return "ok"


def focus_by_keyboard(name, tries=10):
    """Move the keyboard focus onto the control whose name starts with `name`.

    Z-order does not apply to the keyboard: when another window covers the
    app's button, Tab still walks the app's own focus chain — as long as the
    app is the foreground window.
    """
    for _ in range(tries):
        focused = uia.GetFocusedControl()
        got = ""
        if focused is not None:
            try:
                got = focused.Name or ""
            except Exception:
                got = ""
        if got.startswith(name):
            return True
        uia.SendKeys("{Tab}", waitTime=0.15)
        time.sleep(0.25)
    return False


def press_enter():
    uia.SendKeys("{Enter}", waitTime=0.2)
    time.sleep(0.4)


def adopt_and_check(expect_held=True):
    btn = find_contains(_WIN, TIP_ADOPT)
    if btn is None:
        raise RuntimeError("设为应用会话 button not found")
    # dismiss any dialog left open by a previous attempt first
    stale = find_exact(_WIN, "提醒")
    if stale and find_exact(_WIN, "确定"):
        click_center(find_exact(_WIN, "确定"), "关闭旧弹窗")
        time.sleep(1.2)
    click_center(btn, TIP_ADOPT)
    time.sleep(4)
    shot("08_adopt_dialog")
    dialog = find_exact(_WIN, "提醒") is not None
    ok_line, bad_line, body = [], [], ""
    if dialog and find_exact(_WIN, "复制"):
        # the body is a SelectableText with no Name — use its own 复制
        # button to fetch the full text via the clipboard
        try:
            click_center(find_exact(_WIN, "复制"), "复制 dialog")
        except RuntimeError:
            log("复制 covered by another window — using the keyboard")
            if focus_by_keyboard("复制"):
                press_enter()
        time.sleep(1)
        body = clipboard_text()
        log("adopt body: %r" % body[:200])
        if "已接管" in body:
            ok_line.append(body)
        elif body:
            bad_line.append(body)
    texts = save_texts("adopt_texts", _WIN)
    ok_line += [t for t in texts if "已接管" in t]
    bad_line += [t for t in texts
                 if "接管失败" in t or ("CASTGC" not in body and "no CASTGC" in t)]
    held = [t for t in texts if t.startswith("held: ")]
    log("adopt dialog=%s held=%d" % (dialog, len(held)))
    ok_btn = find_exact(_WIN, "确定") or find_exact(_WIN, "OK")
    if ok_btn:
        try:
            click_center(ok_btn, "确定")
        except RuntimeError:
            log("确定 covered by another window — using the keyboard")
            if focus_by_keyboard("确定"):
                press_enter()
        time.sleep(1.5)
    if bad_line:
        return False
    if expect_held and not ok_line:
        raise RuntimeError("adopt verdict unreadable (see adopt body)")
    return not bad_line


def read_grades(w):
    btn = find_contains(w, TIP_READ)
    if btn is None:
        raise RuntimeError("读取成绩 button not found")
    click_center(btn, TIP_READ)
    time.sleep(5)
    shot("11_grades_sheet")
    texts = tree_texts(w)
    os.makedirs(SHOTS, exist_ok=True)
    with open(os.path.join(SHOTS, "grades_texts.txt"), "w",
              encoding="utf-8") as f:
        f.write("\n".join(texts))
    summary = [t for t in texts if "行 · 列：" in t]
    log("SHEET summaries:")
    for s in summary:
        log("  %s" % s)
    good = 0
    for t in texts:
        if re.search(r"^第\d+行|成绩 \d|绩点 [0-9.]+", t):
            good += 1
            log("row-ish: %s" % t[:70])
    log("row-ish lines: %d" % good)
    return summary, good > 0


def classify_screen(retries=10):
    for _ in range(retries):
        if find_exact(_WIN, "学号或工号"):
            return "cas-native"
        if find_contains(_WIN, TIP_ADOPT):
            return "browser"
        if find_contains(_WIN, WALL_CTA):
            return "jwgl-wall"
        if find_contains(_WIN, MENU_CTA):
            return "jwgl"
        if find_contains(_WIN, MORE_TAB):
            return "home"
        time.sleep(1)
    save_texts("state_unknown", _WIN)
    shot("state_unknown")
    return "unknown"


def wait_slider(timeout=12):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if find_contains(_WIN, SLIDER_TEXT):
            return True
        time.sleep(1)
    return False


def set_year(year):
    """Open the 学年 dropdown and pick `year` (custom dropdown; the option
    list is exposed as ListItemControls once opened)."""
    label = find_exact(_WIN, "学年")
    if label is None:
        log("学年 label not found")
        return False
    r = label.BoundingRectangle
    focus_app()
    # the value widget sits to the right of the label on the same row
    uia.Click(int(r.right + 70), int((r.top + r.bottom) / 2), waitTime=0.3)
    time.sleep(2)
    item = find_exact(_WIN, year)
    if item is None:
        uia.SendKeys("{Esc}")
        time.sleep(1)
        log("option %r not in the opened list" % year)
        return False
    click_center(item, "year option %s" % year)
    time.sleep(1.5)
    return find_exact(_WIN, year) is not None


def main():
    global _WIN
    _WIN = start_app(reuse=True)
    if _WIN is None:
        raise RuntimeError("campus_atlas window not found")
    log("window ok")
    _WIN.SetActive()
    time.sleep(0.8)
    focus_app()

    # The semantics tree can be (re)built lazily after this process's own
    # UIA session attaches; poll until something recognizable surfaces.
    time.sleep(2)
    state = classify_screen()
    log("screen state: %s" % state)

    if state == "cas-native":
        close_cas_form_if_open(_WIN)
    elif state == "home":
        goto_jwgl(_WIN)
    elif state == "jwgl-wall":
        pass  # front door click below
    elif state == "browser":
        pass  # reuse the open browser
    else:
        raise RuntimeError("unrecognized screen state: %s" % state)

    if state != "browser":
        door = find_contains(_WIN, BROWSER_CTA)
        if door is None:
            door = wait_for_name(_WIN, BROWSER_CTA)
        if door is None:
            raise RuntimeError("browser front door not found")
        click_center(door, BROWSER_CTA)
        time.sleep(12)
    else:
        time.sleep(1)
    shot("07_browser")
    page = find_webview(_WIN)
    log("web panes: %d" % len(page))
    if not page:
        raise RuntimeError("no WebView2 pane")
    page = page[-1]
    btexts = save_texts("browser_texts", _WIN)
    # classify the browser page (appbar tooltips also say 成绩, so don't
    # match on that word alone)
    state = "cas"
    for t in btexts:
        if "教学管理信息服务平台" in t or t in ("报名申请", "信息维护", "选课",
                                              "信息查询", "学生评教"):
            state = "jwgl"
            break
        if "统一身份认证" in t and "Web 内容" not in t:
            continue
        if "统一身份认证" in t:
            state = "cas"
            break
        if any(k in t for k in ("功能菜单", "系统首页")):
            state = "jwgl"
            break

    if state == "cas":
        # wait for the CAS inputs to surface in the Chrome a11y tree
        tgt = None
        deadline = time.time() + 15
        while time.time() < deadline and tgt is None:
            tgt = find_web_input(page, ["username", "学工号/用户名/手机"])
            if tgt is None:
                time.sleep(1.5)
        if tgt is None:
            log("CAS inputs never surfaced; tree saved")
            save_texts("browser_no_inputs", _WIN)
            shot("browser_no_inputs")
            return
        res = browser_sign_in(page)
        if res != "ok":
            notify_slider(res)
            return
        page = find_webview(_WIN)[-1]
        btexts = save_texts("browser_texts2", _WIN)
        if not any((k in t) for t in btexts for k in ("菜单", "首页")):
            log("after login browser still not on jwgl? continuing anyway")

    # adopt the browser session into the app
    adopt_and_check(expect_held=True)
    time.sleep(2)
    shot("09_after_adopt")

    # direct to the grade page in the SAME browser
    direct = find_contains(_WIN, TIP_DIRECT)
    if direct is None:
        raise RuntimeError("直达成绩查询 tip not found")
    click_center(direct, TIP_DIRECT)
    time.sleep(10)
    shot("09_grade_page")
    save_texts("grade_page_texts", _WIN)

    # every query draws a fresh challenge (measured); press 查询 once —
    # scoped to the WebView subtree because the AppBar tooltip
    # '直达成绩查询' also contains the word
    page2 = find_webview(_WIN)
    q = None
    if page2:
        tgt = page2[-1]
        for n in ("查 询", "查询"):
            q = find_contains(tgt, n, 40)
            if q:
                break
    if q is None:
        save_texts("no_query_btn", _WIN)
        shot("no_query_btn")
        raise RuntimeError("page 查询 button not found")

    # optional: pick a 学年 before querying (default current semester has
    # no published rows; 2025-2026-1 is where this account's grades live)
    year = sys.argv[2] if len(sys.argv) > 2 else ""
    if year:
        if not set_year(year):
            raise RuntimeError("could not set 学年=%r" % year)
        log("学年 set -> %s" % year)

    click_center(q, "page 查询")

    if wait_slider(12):
        notify_slider("after query")
        return
    log("no slider after query; run: python run_e2e.py read")


def notify_slider(where):
    r = find_contains(_WIN, SLIDER_TEXT)
    rect = None
    if r:
        b = r.BoundingRectangle
        rect = (int(b.left), int(b.top), int(b.right), int(b.bottom))
    log("STOP FOR PERSON: slider %s, rect=%s" % (
        "visible" if r else "NOT FOUND", rect))
    shot("slider_%s" % where)
    save_texts("slider_texts", _WIN)
    log("person clears the slider now; then: python run_e2e.py read")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    if mode == "read":
        _WIN = get_window()
        if _WIN is None:
            raise RuntimeError("app window gone")
        _WIN.SetActive()
        focus_app()
        read_grades(_WIN)
    else:
        main()
