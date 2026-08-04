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
# Group 1 captures the link label: a line anchor is only correct if the line it
# points at declares whatever the label names.
link_pattern = re.compile(r"!?\[([^\]]*)\]\(([^)]+)\)")
# Only a lone backticked identifier is matched against the target line. Prose
# labels like [the settlement test suite] name no declaration and would
# false-positive, so they stay unchecked.
identifier_label = re.compile(r"^`([A-Za-z_][A-Za-z0-9_']*)`$")
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
            label = match.group(1).strip()
            target = match.group(2).strip()
            # Report the failing link's own line, not just its file: a report that
            # names only the document leaves long tables to be searched by hand.
            line_number = text.count("\n", 0, match.start()) + 1
            location = f"{rel_doc}#{line_number}"
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
                errors.append(f"{location}: link escapes repository: {target}")
                continue
            if not os.path.exists(resolved):
                errors.append(f"{location}: missing link target: {target}")
                continue

            checked += 1
            if not (separator and anchor):
                continue

            if anchor.startswith("L") and anchor[1:].isdigit() and os.path.isfile(resolved):
                with open(resolved, encoding="utf-8", errors="replace") as target_stream:
                    # splitlines() gives the line's content as well as the count
                    target_lines = target_stream.read().splitlines()
                number = int(anchor[1:])
                # Report a repository-relative `path#line` rather than the
                # document-relative `path#Lline` the link is written as: VS Code
                # quick open (ctrl+P) resolves the former and cannot find the latter.
                reported = f"{os.path.relpath(resolved, root)}#{number}"
                if number > len(target_lines):
                    errors.append(f"{location}: line anchor exceeds target: {reported}")
                else:
                    # Check if the target line contains the identifier. Editing the
                    # target shifts its declarations, leaving the anchor pointing at
                    # an unrelated line that still exists.
                    identifier = identifier_label.match(label)
                    if identifier and not re.search(
                        r"(?<![\w'])" + re.escape(identifier.group(1)) + r"(?![\w'])",
                        target_lines[number - 1],
                    ):
                        errors.append(
                            f"{location}: line anchor does not declare "
                            f"{identifier.group(1)}: {reported}"
                        )
            # GitHub only resolves line anchors written as #L[number]; a bare #[number] is
            # treated as a heading fragment and silently lands at the top of the
            # file, so reject the digits-only form instead of following it.
            elif anchor.isdigit():
                errors.append(f"{location}: line anchor must use an L prefix: {target}")
            else:
                heading_path = resolved
                if os.path.isdir(heading_path):
                    heading_path = os.path.join(heading_path, "README.md")
                if heading_path.endswith(".md") and os.path.isfile(heading_path):
                    decoded_anchor = unquote(anchor).lower()
                    if decoded_anchor not in markdown_headings(heading_path):
                        errors.append(f"{location}: missing heading anchor: {target}")

if errors:
    for error in errors:
        print(f"check-docs: {error}", file=sys.stderr)
    sys.exit(1)

print(f"check-docs: OK ({checked} local links)")
PY
