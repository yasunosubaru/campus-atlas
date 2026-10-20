# -*- coding: utf-8 -*-
"""Capture the app's own screens for the README and the release page.

Everything is the running release build, cropped to the app's window, in the
app's own dark theme. No student name or number appears in any of these
screens — the timetable shows course blocks, the archive shows courses and
grades, and the session line shows a remaining-minutes count.

Usage:
    python scripts/e2e/capture_screens.py [outdir]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e as e2e  # noqa: E402
import window_capture  # noqa: E402

HOME = "\u9996\u9875"        # 首页
TIMETABLE = "\u8bfe\u8868"  # 课表
MORE = "\u66f4\u591a"      # 更多
BACK = "\u8fd4\u56de"      # 返回
CANCEL = "\u53d6\u6d88"    # 取消 (the browser screen's close button)
STATUS = "\u5b66\u4e1a\u72b6\u6001"   # 学业状态
MAP = "\u6821\u56ed\u5730\u56fe"      # 校园地图
EVAL = "\u8bc4\u6559"      # 评教
SETTINGS = "\u8bbe\u7f6e"  # 设置
ARCHIVE = "\u67e5\u770b\u6210\u7ee9\u6863\u6848"  # 查看成绩档案

OUT = sys.argv[1] if len(sys.argv) > 1 else "docs/images"


def buttons(win, prefix):
    return e2e.find_all(
        win,
        lambda c: (c.ControlTypeName == "ButtonControl"
                   and isinstance(c.Name, str)
                   and c.Name.startswith(prefix)),
        50,
    )


def click(win, prefix, last=False, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        hits = buttons(win, prefix)
        if hits:
            hits.sort(key=lambda c: c.BoundingRectangle.top)
            target = hits[-1] if last else hits[0]
            e2e.click_center(target, prefix)
            time.sleep(1.2)
            return True
        time.sleep(0.6)
    return False


def close_browser(win):
    """Leave the in-app browser if it is open.

    The browser is a native child window stacked over the app's client area,
    so a screenshot taken while it is open shows the **school's** page — with
    the person's name and photo on it — instead of the app. That is both the
    wrong picture and the wrong privacy.
    """
    for _ in range(3):
        cancel = e2e.find_exact(win, CANCEL)
        if not cancel:
            return
        r = cancel.BoundingRectangle
        if r.top > 140:
            return
        e2e.click_center(cancel, CANCEL)
        time.sleep(1.2)
        win = e2e.get_window()
        e2e._WIN = win


def back_to_shell(win):
    """Back to the tab bar, whatever screen is on top."""
    for _ in range(8):
        if buttons(win, MORE):
            return win
        close_browser(win)
        win = e2e.get_window()
        e2e._WIN = win
        b = e2e.find_exact(win, BACK)
        if not b:
            return win
        e2e.click_center(b, BACK)
        time.sleep(1.0)
        win = e2e.get_window()
        e2e._WIN = win
    return win


def grab(win, name):
    """The app's own pixels — not the desktop's.

    A screen grab would show whatever else is on top of the window, and on a
    busy desktop that is somebody else's chat window. PrintWindow asks the
    app to paint itself, so the picture is always the app.
    """
    path = os.path.join(OUT, name)
    img, ok = window_capture.capture(win.NativeWindowHandle, path)
    e2e.log("shot %s -> %s (%dx%d, printed=%s)" % (name, path, img.width,
                                                  img.height, ok))
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    win = e2e.start_app(reuse=True)
    e2e._WIN = win
    win = e2e.place_window(win)
    if win is None:
        raise SystemExit("no app window")
    win.SetActive()
    time.sleep(0.6)
    e2e.focus_app()
    time.sleep(0.8)

    # home
    back_to_shell(win)
    click(win, HOME, last=True)
    time.sleep(1.5)
    grab(win, "home.png")

    # timetable
    back_to_shell(win)
    click(win, TIMETABLE, last=True)
    time.sleep(1.5)
    grab(win, "timetable.png")

    # academic standing + grade archive
    back_to_shell(win)
    click(win, MORE, last=True)
    time.sleep(1.2)
    click(win, STATUS)
    time.sleep(1.8)
    grab(win, "academic.png")
    if click(win, ARCHIVE):
        time.sleep(1.8)
        grab(win, "grades.png")
        b = e2e.find_exact(win, BACK)
        if b:
            e2e.click_center(b, BACK)
            time.sleep(1.2)

    # campus map
    back_to_shell(win)
    click(win, MORE, last=True)
    time.sleep(1.2)
    click(win, MAP)
    time.sleep(2.5)
    grab(win, "map.png")
    b = e2e.find_exact(win, BACK)
    if b:
        e2e.click_center(b, BACK)
        time.sleep(1.2)

    # teaching evaluation
    back_to_shell(win)
    click(win, MORE, last=True)
    time.sleep(1.2)
    click(win, EVAL)
    time.sleep(1.8)
    grab(win, "evaluation.png")
    b = e2e.find_exact(win, BACK)
    if b:
        e2e.click_center(b, BACK)
        time.sleep(1.2)

    # settings
    back_to_shell(win)
    click(win, MORE, last=True)
    time.sleep(1.2)
    click(win, SETTINGS)
    time.sleep(1.5)
    grab(win, "settings.png")
    e2e.log("done")


if __name__ == "__main__":
    main()
