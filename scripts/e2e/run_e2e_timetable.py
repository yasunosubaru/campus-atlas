# -*- coding: utf-8 -*-
"""Drive the timetable import through the browser fallback.

The academic system's timetable endpoint answers an empty list unless the
person has just cleared the page's slider challenge, so the app can no longer
read the timetable by posting to the data endpoint alone. The fallback opens
the real page, lets the person clear the challenge, and then reads the rows the
page has already drawn.

This script opens that page and — once the person has cleared the challenge —
presses the app's read button and reports what came back.

Usage:
    python scripts/e2e/run_e2e_timetable.py open   # navigate to the page
    python scripts/e2e/run_e2e_timetable.py read   # read the drawn rows
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e as e2e  # noqa: E402

TIMETABLE = "\u8bfe\u8868"      # 课表
IMPORT = "\u4ece\u6559\u52a1\u5bfc\u5165"        # 从教务导入
BROWSER_IMPORT = "\u5728\u6d4f\u89c8\u5668\u4e2d\u5b8c\u6210\u9a8c\u8bc1\u5e76\u8bfb\u53d6"  # 在浏览器中完成验证并读取
READ = "\u8bfb\u53d6\u5f53\u524d\u8bfe\u8868"    # 读取当前课表
CLOSE = "\u53d6\u6d88"          # 取消
APPLY = "\u8986\u76d6\u5f53\u524d\u8bfe\u8868"  # 覆盖当前课表
SLIDER = "\u8bf7\u62d6\u52a8\u5de6\u4fa7\u6ed1\u5757\u8fd8\u539f\u56fe\u7247"


def buttons(win, prefix):
    return e2e.find_all(
        win,
        lambda c: (c.ControlTypeName == "ButtonControl"
                   and isinstance(c.Name, str)
                   and c.Name.startswith(prefix)),
        50,
    )


def click_button(win, prefix, last=False, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        hits = buttons(win, prefix)
        if hits:
            hits.sort(key=lambda c: c.BoundingRectangle.top)
            target = hits[-1] if last else hits[0]
            e2e.click_center(target, prefix)
            return True
        time.sleep(0.7)
    return False


def texts(win):
    names = []

    def hit(c):
        try:
            n = c.Name
            if isinstance(n, str) and n:
                names.append(n)
        except Exception:
            pass
        return False

    e2e.walk(win, 50, hit)
    return names


def open_page():
    e2e._WIN = e2e.start_app(reuse=True)
    win = e2e._WIN
    if win is None:
        raise RuntimeError("campus_atlas window not found")
    win.SetActive()
    time.sleep(0.8)
    e2e.focus_app()
    time.sleep(0.8)

    # leave any pushed screen first — the tab bar only exists on the shell
    for _ in range(5):
        if buttons(win, TIMETABLE):
            break
        back = e2e.find_exact(win, "\u8fd4\u56de")  # 返回
        if not back:
            break
        e2e.click_center(back, "\u8fd4\u56de")
        time.sleep(1.2)
        win = e2e.get_window()
        e2e._WIN = win

    if not click_button(win, TIMETABLE):
        raise RuntimeError("课表 tab not found")
    time.sleep(1.5)
    e2e.shot("40_timetable")

    if not click_button(win, IMPORT):
        raise RuntimeError("从教务导入 button not found")
    time.sleep(2)
    e2e.shot("41_import_sheet")

    if not click_button(win, BROWSER_IMPORT):
        e2e.save_texts("no_browser_import", win)
        e2e.shot("no_browser_import")
        raise RuntimeError("在浏览器中完成验证并读取 not found")
    time.sleep(12)
    e2e.shot("42_timetable_page")

    page = e2e.find_webview(win)
    e2e.log("web panes: %d" % len(page))
    if page:
        e2e.save_texts("timetable_page_texts", win)
    slider = e2e.find_contains(win, SLIDER)
    e2e.log("slider on the page: %s" % (slider is not None))
    e2e.log("STOP FOR PERSON: clear the slider in the page, then run "
            "run_e2e_timetable.py read")


def apply_button(win):
    """The 「覆盖当前课表」 button, once the sheet has settled.

    The sheet slides back in after the browser closes, and while it is moving
    the accessibility tree still reports the position it is about to have —
    a click taken then lands on whatever is at that pixel.
    """
    window = win.BoundingRectangle
    deadline = time.time() + 20
    while time.time() < deadline:
        hits = e2e.find_all(
            win,
            lambda c: (c.ControlTypeName == "ButtonControl"
                       and isinstance(c.Name, str)
                       and c.Name.startswith(APPLY)),
            50,
        )
        for hit in hits:
            r = hit.BoundingRectangle
            if window.top < r.top and r.bottom < window.bottom:
                return hit
        time.sleep(0.7)
    return None


def read_rows():
    e2e._WIN = e2e.get_window()
    win = e2e._WIN
    if win is None:
        raise RuntimeError("app window gone")
    win.SetActive()
    time.sleep(0.6)
    e2e.focus_app()
    time.sleep(0.6)

    if not click_button(win, READ):
        e2e.save_texts("no_read_button", win)
        e2e.shot("no_read_button")
        raise RuntimeError("读取当前课表 button not found")
    time.sleep(8)
    e2e.shot("43_after_read")

    names = texts(win)
    for n in names:
        if any(k in n for k in ("\u8bfe\u8868", "\u95e8\u8bfe", "\u6ed1\u5757",
                                "\u8bfb\u5230", "\u5bfc\u5165")):
            e2e.log("  %s" % n.encode("unicode_escape").decode("ascii")[:200])

    button = apply_button(win)
    if button is None:
        e2e.save_texts("no_apply_button", win)
        e2e.shot("no_apply_button")
        raise RuntimeError("覆盖当前课表 button not reachable")
    e2e.click_center(button, APPLY)
    time.sleep(2)

    # the sheet asks before it replaces anything — that is the point of the
    # confirmation, so the driver has to answer it
    confirm = apply_button(win)
    if confirm is not None:
        e2e.click_center(confirm, "confirm apply")
    time.sleep(4)
    e2e.shot("44_applied")
    e2e.log("applied the imported timetable")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "open"
    if mode == "read":
        read_rows()
    else:
        open_page()
