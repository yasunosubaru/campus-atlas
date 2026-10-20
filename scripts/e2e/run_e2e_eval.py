# -*- coding: utf-8 -*-
"""Drive the teaching-evaluation entry hand-off and report what it answered.

The screen posts the student id to `/loginSSO` on the evaluation host. The
service session has to exist first, so the repository warms it by walking the
same CAS hop the landing page walks and then posts with the cookies that hop
set. This script exercises exactly that path in the running app and prints the
answer, so a change to the handshake can be seen rather than assumed.

Usage (student id through the environment only):
    set E2E_STUDENT_ID=<学号>
    python scripts/e2e/run_e2e_eval.py
"""
import os
import sys
import time

import uiautomation as uia

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e as e2e  # noqa: E402

MORE = "\u66f4\u591a"      # 更多
EVAL = "\u8bc4\u6559"      # 评教
RESOLVE = "\u89e3\u6790\u8bc4\u6559\u5165\u53e3"  # 解析评教入口
FETCH = "\u6293\u53d6\u54cd\u5e94"  # 抓取响应
RESOLVED = "\u5df2\u89e3\u6790\u5230\u5165\u53e3"  # 已解析到入口
BACK = "\u8fd4\u56de"      # 返回

STUDENT_ID = os.environ.get("E2E_STUDENT_ID", "")


def buttons(win, prefix):
    return e2e.find_all(
        win,
        lambda c: (c.ControlTypeName == "ButtonControl"
                   and isinstance(c.Name, str)
                   and c.Name.startswith(prefix)),
        50,
    )


def click_button(win, prefix, last=False):
    hits = buttons(win, prefix)
    if not hits:
        return False
    hits.sort(key=lambda c: c.BoundingRectangle.top)
    target = hits[-1] if last else hits[0]
    e2e.click_center(target, prefix)
    return True


def fill_id(win):
    """Type the student id into the entry field and read it back.

    Flutter merges the entry panel's texts into one UIA node, so the field's
    own rectangle is not exposed; the offsets below walk the panel from the
    top until the typed value reads back.
    """
    fields = e2e.find_all(
        win,
        lambda c: (c.ControlTypeName == "EditControl"
                   and isinstance(c.Name, str)
                   and "loginSSO" in c.Name),
        40,
    )
    if not fields:
        return False
    field = fields[0]
    r = field.BoundingRectangle
    for offset in (100, 115, 85, 130, 70):
        e2e.focus_app()
        uia.Click(int(r.left + 120), int(r.top + offset), waitTime=0.25)
        time.sleep(0.35)
        uia.SendKeys("{Ctrl}a{Del}", waitTime=0.1)
        uia.SendKeys(STUDENT_ID, waitTime=0.03)
        time.sleep(0.4)
        value = ""
        try:
            value = field.GetValuePattern().Value
        except Exception:
            pass
        e2e.log("field fill at +%d, readback=%r" % (offset, value))
        if value == STUDENT_ID:
            return True
    return False


def main():
    e2e._WIN = e2e.start_app(reuse=True)
    win = e2e._WIN
    if win is None:
        raise RuntimeError("campus_atlas window not found")
    win.SetActive()
    time.sleep(0.8)
    e2e.focus_app()
    time.sleep(0.8)

    # get to the evaluation screen from wherever we are
    for _ in range(6):
        if buttons(win, RESOLVE):
            break
        back = e2e.find_exact(win, BACK)
        if back:
            e2e.click_center(back, BACK)
            time.sleep(1.2)
            win = e2e.get_window()
            e2e._WIN = win
            continue
        if click_button(win, MORE, last=True):
            time.sleep(1.2)
            if click_button(win, EVAL):
                time.sleep(1.5)
            win = e2e.get_window()
            e2e._WIN = win
            continue
        break

    if not buttons(win, RESOLVE):
        e2e.save_texts("no_eval_screen", win)
        e2e.shot("no_eval_screen")
        raise RuntimeError("评教 screen not reached")

    if not fill_id(win):
        e2e.save_texts("no_id_field", win)
        e2e.shot("no_id_field")
        raise RuntimeError("student id field not found")

    if not click_button(win, RESOLVE, RESOLVE):
        raise RuntimeError("解析评教入口 button not found")
    time.sleep(12)
    e2e.shot("30_eval_resolved")

    texts = e2e.save_texts("eval_resolved_texts", win)
    hit = [t for t in texts if RESOLVED in t]
    errors = [t for t in texts
              if any(k in t for k in ("not an http", "sign-in", "failed",
                                      "\u5931\u8d25", "\u9519\u8bef"))]
    e2e.log("resolved lines: %s" % [
        t.encode("unicode_escape").decode("ascii")[:160] for t in hit])
    e2e.log("error-ish lines: %s" % [
        t.encode("unicode_escape").decode("ascii")[:160] for t in errors])
    if not hit:
        for t in texts:
            e2e.log("  %s" % t.encode("unicode_escape").decode("ascii")[:160])


if __name__ == "__main__":
    main()
