# -*- coding: utf-8 -*-
"""Drive the sign-in path the app has TODAY: 设置 → 账户登录 → 内置浏览器 → CAS.

The older `run_e2e.py full` still drives the grade flow, but its front door
(更多 → 正方教务 → 在应用内浏览器查成绩) moved: the single sign-in entry is now
设置 → 账户登录, and every login wall redirects there. This script walks the
current path and then hands the session to the app with 「设为应用会话」.

The slider, if the CAS page asks for one, is the PERSON's step — this script
never moves it. It stops and says so.

Usage (credentials travel through the environment only):
    set E2E_STUDENT_ID=<学号> & set E2E_PASSWORD=<密码>
    python scripts/e2e/run_e2e_account.py
"""
import os
import sys
import time

import uiautomation as uia

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e as e2e  # noqa: E402

SETTINGS_TAB = "\u8bbe\u7f6e"          # 设置
ACCOUNT_ENTRY = "\u8d26\u6237\u767b\u5f55"  # 账户登录
BROWSER_SIGN_IN = "\u5728\u5e94\u7528\u5185\u6d4f\u89c8\u5668\u767b\u5f55"  # 在应用内浏览器登录
SIGNED_IN = "\u5df2\u767b\u5f55"        # 已登录
MORE_TAB = "\u66f4\u591a"              # 更多
TIP_ADOPT = e2e.TIP_ADOPT              # 设为应用会话


def buttons(win, prefix):
    """Buttons whose label starts with `prefix`.

    Flutter merges a button's texts into one UIA name, so a tile reads
    `设置\nCampus Atlas 是独立的第三方开源实现…`.
    """
    return e2e.find_all(
        win,
        lambda c: (c.ControlTypeName == "ButtonControl"
                   and isinstance(c.Name, str)
                   and c.Name.startswith(prefix)),
        50,
    )


def click_button(win, prefix, label=None, last=False):
    hits = buttons(win, prefix)
    if not hits:
        return False
    hits.sort(key=lambda c: c.BoundingRectangle.top)
    target = hits[-1] if last else hits[0]
    e2e.click_center(target, label or prefix)
    return True


def scroll_until(win, prefix, limit=14):
    """Wheel the list under the cursor until a button with `prefix` is
    *visible* (Flutter exposes off-screen items in the tree, so being in the
    tree is not enough — the click would land on the navigation bar).

    The visible band is taken from the app window itself: the runner's frame
    is shorter than the Flutter view, and hard-coded bounds would then be
    measuring the wrong thing.
    """
    pane = e2e.flutter_pane(win)
    r = pane.BoundingRectangle
    top = r.top + 120
    bottom = r.bottom - 90
    x = int(r.left + (r.right - r.left) / 2)
    y = int(r.top + 250)
    for _ in range(limit):
        hits = [b for b in buttons(win, prefix)
                if top < b.BoundingRectangle.top < bottom]
        if hits:
            hits.sort(key=lambda c: c.BoundingRectangle.top)
            return hits[-1]
        e2e.focus_app()
        uia.MoveTo(x, y)
        uia.WheelDown(3)
        time.sleep(0.6)
    return None


def main():
    e2e._WIN = e2e.start_app(reuse=True)
    win = e2e._WIN
    if win is None:
        raise RuntimeError("campus_atlas window not found")
    win.SetActive()
    time.sleep(1)
    e2e.focus_app()
    time.sleep(1.5)

    on_account = bool(buttons(win, BROWSER_SIGN_IN))
    if not on_account:
        # leave any pushed screen (a browser page from an earlier run, the
        # settings page, …) — the tab bar only exists on the shell
        for _ in range(6):
            if buttons(win, MORE_TAB):
                break
            cancel = e2e.find_exact(win, "\u53d6\u6d88")  # 取消
            if cancel and cancel.BoundingRectangle.top < 140:
                e2e.click_center(cancel, "\u53d6\u6d88")
                time.sleep(1.2)
                win = e2e.get_window()
                e2e._WIN = win
                continue
            back = e2e.find_exact(win, "\u8fd4\u56de")  # 返回
            if not back:
                break
            e2e.click_center(back, "\u8fd4\u56de")
            time.sleep(1.2)
            win = e2e.get_window()
            e2e._WIN = win
        on_account = bool(buttons(win, BROWSER_SIGN_IN))
    if not on_account:
        # 更多 tab
        if not click_button(win, MORE_TAB, MORE_TAB, last=True):
            raise RuntimeError("更多 tab not found")
        time.sleep(1.5)
        e2e.shot("20_more")
        # 设置 tile lives below the fold on the 更多 page
        tile = scroll_until(win, SETTINGS_TAB)
        if tile is None:
            e2e.save_texts("no_settings_tile", win)
            e2e.shot("no_settings_tile")
            raise RuntimeError("设置 tile not found on the 更多 page")
        e2e.click_center(tile, SETTINGS_TAB)
        time.sleep(1.5)
        e2e.shot("20_settings")

        # the account row: the section header carries the same words, the row
        # is the button
        if not click_button(win, ACCOUNT_ENTRY, ACCOUNT_ENTRY):
            e2e.save_texts("no_account_entry", win)
            e2e.shot("no_account_entry")
            raise RuntimeError("账户登录 entry not found on the settings page")
        time.sleep(1.5)
        e2e.shot("21_account")

    if not click_button(win, BROWSER_SIGN_IN, BROWSER_SIGN_IN):
        e2e.save_texts("no_browser_signin", win)
        e2e.shot("no_browser_signin")
        raise RuntimeError("在应用内浏览器登录 button not found")
    time.sleep(10)
    e2e.shot("22_browser")

    page = []
    deadline = time.time() + 25
    while time.time() < deadline and not page:
        page = e2e.find_webview(win)
        if not page:
            time.sleep(1.5)
    if not page:
        raise RuntimeError("no WebView2 pane")
    page = page[-1]

    # the CAS form has to surface in the a11y tree before it can be filled.
    # A profile that still holds the central grant lands on the academic
    # system instead — that is a signed-in browser, not a failure.
    tgt = None
    deadline = time.time() + 20
    while time.time() < deadline and tgt is None:
        tgt = e2e.find_web_input(
            page, ["username", "\u5b66\u5de5\u53f7/\u7528\u6237\u540d/\u624b\u673a"])
        if tgt is None:
            time.sleep(1.5)

    if tgt is None:
        texts = e2e.save_texts("browser_no_inputs_texts", win)
        signed_in = any(
            any(k in t for k in ("\u6559\u5b66\u7ba1\u7406\u4fe1\u606f\u670d\u52a1\u5e73\u53f0",
                                 "\u7cfb\u7edf\u9996\u9875", "\u529f\u80fd\u83dc\u5355",
                                 "\u5b66\u4e1a\u4e2d\u5fc3", "\u9009\u8bfe"))
            for t in texts)
        e2e.log("no CAS inputs; academic system already open: %s" % signed_in)
        e2e.shot("22_browser_already")
        if not signed_in:
            raise RuntimeError("CAS inputs never surfaced")
    else:
        res = e2e.browser_sign_in(page)
        if res != "ok":
            e2e.log("STOP FOR PERSON: %s" % res)
            e2e.shot("23_signin_%s" % res)
            return

    # adopt the browser's cookies as the app's session
    time.sleep(3)
    ok = e2e.adopt_and_check(expect_held=True)
    e2e.log("adopt ok=%s" % ok)
    e2e.shot("24_adopted")

    # back to the account page: the session must show as signed in
    if e2e.find_exact(win, "\u53d6\u6d88"):  # 取消
        e2e.click_center(e2e.find_exact(win, "\u53d6\u6d88"), "close browser")
        time.sleep(2)
    texts = e2e.save_texts("account_after_login", win)
    e2e.log("signed in shown: %s" % any(SIGNED_IN in t for t in texts))
    e2e.shot("25_signed_in")


if __name__ == "__main__":
    main()
