#!/usr/bin/env bash
# Validate repository-local Markdown targets and reject machine-specific paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os
import re
import sys
from urllib.parse import unquote

root = os.path.realpath(sys.argv[1])
excluded = {".git", ".daml", ".cache", ".coverage", ".vscode"}
link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
home_pattern = re.compile(r"/(?:Users|home)/[^/\s]+/")
errors = []
checked = 0
heading_cache = {}


def markdown_headings(path):
    if path in heading_cache:
        return heading_cache[path]

    headings = set()
    occurrences = {}
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
            if not match:
                continue
            heading = match.group(1)
            heading = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", heading)
            heading = re.sub(r"<[^>]+>", "", heading)
            heading = heading.replace("`", "").lower().strip()
            heading = re.sub(r"[^\w\s-]", "", heading)
            slug = re.sub(r"\s+", "-", heading)
            occurrence = occurrences.get(slug, 0)
            occurrences[slug] = occurrence + 1
            headings.add(slug if occurrence == 0 else f"{slug}-{occurrence}")

    heading_cache[path] = headings
    return headings

for directory, dirnames, filenames in os.walk(root):
    dirnames[:] = [name for name in dirnames if name not in excluded]
    for filename in filenames:
        if not filename.endswith(".md"):
            continue
        path = os.path.join(directory, filename)
        rel_doc = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as stream:
            text = stream.read()

        if home_pattern.search(text):
            errors.append(f"{rel_doc}: contains a machine-specific home path")

        for match in link_pattern.finditer(text):
            target = match.group(1).strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            target = target.split(" ", 1)[0]
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue

            file_part, separator, anchor = target.partition("#")
            if file_part.startswith("/"):
                continue

            resolved = path if not file_part else os.path.realpath(
                os.path.join(directory, unquote(file_part))
            )
            if os.path.commonpath([root, resolved]) != root:
                errors.append(f"{rel_doc}: link escapes repository: {target}")
                continue
            if not os.path.exists(resolved):
                errors.append(f"{rel_doc}: missing link target: {target}")
                continue

            checked += 1
            if separator and anchor.startswith("L") and anchor[1:].isdigit() and os.path.isfile(resolved):
                with open(resolved, encoding="utf-8", errors="replace") as target_stream:
                    line_count = sum(1 for _ in target_stream)
                if int(anchor[1:]) > line_count:
                    errors.append(f"{rel_doc}: line anchor exceeds target: {target}")
            elif separator and anchor:
                heading_path = resolved
                if os.path.isdir(heading_path):
                    heading_path = os.path.join(heading_path, "README.md")
                if heading_path.endswith(".md") and os.path.isfile(heading_path):
                    decoded_anchor = unquote(anchor).lower()
                    if decoded_anchor not in markdown_headings(heading_path):
                        errors.append(f"{rel_doc}: missing heading anchor: {target}")

if errors:
    for error in errors:
        print(f"check-docs: {error}", file=sys.stderr)
    sys.exit(1)

print(f"check-docs: OK ({checked} local links)")
PY
