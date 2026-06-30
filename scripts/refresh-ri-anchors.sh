#!/usr/bin/env bash
# refresh-ri-anchors.sh — validate (and optionally fix) the direct code
# references that make the RI architecture reports "living documents".
#
# Every direct code reference in docs/ri-reports/*.md and
# docs/architecture/cip0112-m1-ri-spec.md uses the convention:
#
#     [`SymbolName`](<relative-path>#L<line>)     # source symbol at a line
#     [`pkg-or-file`](<relative-path>)            # file-level link, no line
#
# This script resolves every such link relative to the doc, checks the target
# exists, and — when a #L anchor is present and the link text is a code symbol —
# checks that the symbol actually appears at/near the cited line in the source.
# Line numbers drift as the scaffold evolves; that is expected. Run this to find
# drift, and run with --fix to rewrite the cited line numbers to where each
# symbol is now defined.
#
#   scripts/refresh-ri-anchors.sh           # validate; non-zero exit on ERROR
#   scripts/refresh-ri-anchors.sh --fix     # rewrite drifted line numbers in place
#
# Exit codes: 0 = all anchors resolve; 1 = at least one ERROR (missing file or
# symbol absent from the target); 2 = only DRIFT found and not fixed.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

python3 - "$ROOT" "$FIX" <<'PY'
import os, re, sys

ROOT, FIX = sys.argv[1], sys.argv[2] == "1"
DOC_GLOBS = ["docs/ri-reports", "docs/architecture"]

# [`text`](relpath) or [`text`](relpath#Lnn) where relpath is repo-relative
LINK = re.compile(r"\[`([^`]+)`\]\((\.\.?/[^)\s#]+)(?:#L(\d+))?\)")
WINDOW = 3  # a symbol counts as "at" its anchor if within +/- this many lines

def struct_def_lines(lines, sym):
    """Line numbers (1-based) where `sym` is *structurally defined* (template /
    interface / data / newtype / type / class / choice / a top-level `sym :` sig
    or `sym =` binding). Empty when `sym` is only referenced, not defined here."""
    defpat = re.compile(
        r"^\s*(template|interface|data|newtype|type|class)\s+" + re.escape(sym) + r"\b"
        r"|^\s*(nonconsuming\s+|postconsuming\s+|preconsuming\s+)?choice\s+" + re.escape(sym) + r"\b"
        r"|^\s*" + re.escape(sym) + r"\s*[:=]"
    )
    return [i + 1 for i, l in enumerate(lines) if defpat.search(l)]

def word_lines(lines, sym):
    """Line numbers (1-based) where `sym` appears as a whole word."""
    word = re.compile(r"(^|[^A-Za-z0-9_])" + re.escape(sym) + r"($|[^A-Za-z0-9_])")
    return [i + 1 for i, l in enumerate(lines) if word.search(l)]

docs = []
for g in DOC_GLOBS:
    d = os.path.join(ROOT, g)
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(".md"):
                docs.append(os.path.join(d, f))

ok = drift = error = 0
drift_msgs, error_msgs = [], []
src_cache = {}

for doc in docs:
    text = open(doc, encoding="utf-8").read()
    rel_doc = os.path.relpath(doc, ROOT)
    changed = False

    def handle(m):
        global ok, drift, error, changed
        sym, relpath, line = m.group(1), m.group(2), m.group(3)
        target = os.path.normpath(os.path.join(os.path.dirname(doc), relpath))
        if not os.path.exists(target):
            error += 1
            error_msgs.append(f"  ERROR {rel_doc}: missing target {relpath}  (`{sym}`)")
            return m.group(0)
        if line is None:
            ok += 1
            return m.group(0)  # file-level link, nothing more to check
        if target not in src_cache:
            src_cache[target] = open(target, encoding="utf-8").read().splitlines()
        lines = src_cache[target]
        n = int(line)

        # Prefer the symbol's DEFINITION over mere word-proximity: an anchor must
        # point at (within WINDOW of) a structural definition when one exists, so
        # citing a field *usage* line that merely mentions the symbol is drift,
        # not a pass. Fall back to word-proximity only for reference-only symbols
        # that have no structural definition in the target file.
        sdefs = struct_def_lines(lines, sym)
        if sdefs:
            if any(abs(d - n) <= WINDOW for d in sdefs):
                ok += 1
                return m.group(0)
            new = min(sdefs, key=lambda d: abs(d - n))
            drift += 1
            drift_msgs.append(f"  DRIFT {rel_doc}: `{sym}` cited L{n} -> now L{new} (definition) in {relpath}"
                              + ("  [fixed]" if FIX else ""))
            if FIX:
                changed = True
                return m.group(0).replace(f"#L{n})", f"#L{new})")
            return m.group(0)

        wlines = word_lines(lines, sym)
        if any(abs(d - n) <= WINDOW for d in wlines):
            ok += 1
            return m.group(0)
        if not wlines:
            error += 1
            error_msgs.append(f"  ERROR {rel_doc}: `{sym}` not found in {relpath} (cited L{n})")
            return m.group(0)
        new = min(wlines, key=lambda d: abs(d - n))
        drift += 1
        drift_msgs.append(f"  DRIFT {rel_doc}: `{sym}` cited L{n} -> now L{new} in {relpath}"
                          + ("  [fixed]" if FIX else ""))
        if FIX:
            changed = True
            return m.group(0).replace(f"#L{n})", f"#L{new})")
        return m.group(0)

    new_text = LINK.sub(handle, text)
    if FIX and changed and new_text != text:
        open(doc, "w", encoding="utf-8").write(new_text)

print(f"RI anchor check: {ok} OK, {drift} drift, {error} error  ({len(docs)} docs)")
for msg in drift_msgs + error_msgs:
    print(msg)

if error:
    sys.exit(1)
if drift and not FIX:
    sys.exit(2)
sys.exit(0)
PY
