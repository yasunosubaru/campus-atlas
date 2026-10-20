# -*- coding: utf-8 -*-
"""Desensitization guard for the public repository.

A tripwire, not a proof: it catches the shapes that must never be committed
(a student's number, somebody's home directory, a token) before they are
pushed. The scan covers the text that goes into git; the images that go with
it are captured from a **synthetic** dataset (see
`scripts/e2e/capture_screens.py`).

Two families of shape need an exemption, and both are noted here rather than
hidden:

* 正方's **course codes** are 13 digits — the same shape as a student number.
  A line that mentions a course code is not a leak, so those lines are
  exempt from the number rule.
* A **captured page** (`test/fixtures/`) is full of timestamps and course
  codes. The only identifier it ever held was redacted when it was captured,
  and a unit test asserts that it stays redacted.

Exit code 0 = clean, 1 = something matched.
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SKIP_DIRS = {".git", "build", ".dart_tool", ".idea", ".android-sdk-stub",
             ".workbuddy-ai", "bin", "ephemeral", "__pycache__"}
TEXT_SUFFIXES = (".dart", ".md", ".py", ".yaml", ".yml", ".json", ".txt",
                  ".html", ".xml", ".plist", ".sh", ".bat", ".ps1", ".cfg",
                  ".toml", ".cpp", ".h", ".rc", ".cmake", ".svg")

# Markers that mean "this line talks about a course code, not a person".
COURSE_CODE_MARKERS = ("kch", "course_code", "courseCode", "course code",
                        "osmId", "node/", "jxb", "kx", "courseId")


class Rule:
    def __init__(self, label, pattern, exempt_paths=(), exempt_markers=()):
        self.label = label
        self.pattern = pattern
        self.exempt_paths = exempt_paths
        self.exempt_markers = exempt_markers

    def skip_line(self, rel, line):
        if any(rel.startswith(p) for p in self.exempt_paths):
            return True
        return any(m in line for m in self.exempt_markers)


RULES = [
    Rule("学号形状（13 位数字）",
         re.compile(r"(?<![\d.\-/])(\d{13})(?![\d.\-/])"),
         exempt_paths=("test/fixtures/",),
         exempt_markers=COURSE_CODE_MARKERS),
    Rule("Windows 用户目录",
         re.compile(r"[A-Za-z]:\\Users\\[A-Za-z0-9._-]+")),
    Rule("POSIX 用户目录",
         re.compile(r"(?<![\w/])/(?:home|Users)/[A-Za-z0-9._-]+/")),
    Rule("邮箱",
         re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(?:com|cn|org|net|io)")),
    Rule("手机号（中国大陆）",
         # The lookbehind excludes a preceding slash, which is what an
         # OpenStreetMap node id looks like (`node/13266231641`).
         re.compile(r"(?<![\d/])1[3-9]\d{9}(?!\d)")),
    Rule("GitHub 令牌形状",
         re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    Rule("私钥块",
         re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----")),
    Rule("Ham 令牌（40 位十六进制）",
         re.compile(r"\b[0-9a-f]{40}\b")),
]


def files():
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in names:
            if name.endswith(TEXT_SUFFIXES):
                yield os.path.join(base, name)


def main():
    hits = []
    for path in files():
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        try:
            with io.open(path, encoding="utf-8") as f:
                for number, line in enumerate(f, 1):
                    for rule in RULES:
                        if rule.skip_line(rel, line):
                            continue
                        if rule.pattern.search(line):
                            hits.append((rel, number, rule.label,
                                         line.strip()[:100]))
        except (UnicodeDecodeError, OSError):
            continue

    # The guard's own rule list is allowed to contain the shapes it looks for.
    hits = [h for h in hits
            if os.path.basename(h[0]) != "check_desensitization.py"]

    if not hits:
        print("desensitization: clean")
        return 0
    print("desensitization: %d hit(s)" % len(hits))
    for rel, number, label, text in hits[:40]:
        print("  %s:%d  [%s]  %s" % (rel, number, label, text))
    print("\nThese must not be committed. Scrub them, or add a narrow, "
          "commented exception if the shape is genuinely part of the code.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
