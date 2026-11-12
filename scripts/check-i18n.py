#!/usr/bin/env python3
"""English UI check: every Korean L("…") / Lf("…") key in Sources/App must exist in Resources/en.json,
and L() must not be cached in a `static let` (it would keep the first language after a switch).
Run by build-cli.sh; exit 1 = missing translations (listed)."""
import json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
en = json.load(open(os.path.join(root, "Resources/en.json"), encoding="utf-8"))
hangul = re.compile("[가-힣]")
call = re.compile(r'\bLf?\(\s*"((?:[^"\\\n]|\\.)*)"')
static_let = re.compile(r'^\s*(?:private |fileprivate )?static let \w+[^=\n]*=\s*(.*)$')

def unescape(s):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1), m.group(0)), s)

missing, cached = [], []
for d, _, files in os.walk(os.path.join(root, "Sources/App")):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        path = os.path.join(d, f)
        rel = os.path.relpath(path, root)
        for n, line in enumerate(open(path, encoding="utf-8"), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in call.finditer(line):
                k = m.group(1)
                if "\\(" in k or not hangul.search(k):
                    continue
                if unescape(k) not in en:
                    missing.append(f"{rel}:{n}: {unescape(k)!r}")
            sl = static_let.match(line)
            if sl and call.search(sl.group(1)) and hangul.search(sl.group(1)):
                cached.append(f"{rel}:{n}: static let with L() — use a computed static var")

for title, items in (("Missing in en.json", missing), ("Cached translations", cached)):
    if items:
        print(f"== {title} ({len(items)})")
        print("\n".join(items))
sys.exit(1 if missing or cached else 0)
