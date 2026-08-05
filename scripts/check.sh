#!/usr/bin/env bash
# Fast repository structure, package, and dependency-provenance checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'check: %s\n' "$*" >&2
	exit 1
}

require_file() {
	[ -f "$ROOT/$1" ] || fail "missing $1"
}

for file in \
	README.md CONTRIBUTING.md SECURITY.md AGENTS.md LICENSE multi-package.yaml \
	docs/README.md experiments/README.md dars/README.md dars/manifest.yaml \
	scripts/check-lint.sh scripts/check-tests.sh scripts/check-docs.sh; do
	require_file "$file"
done

if [ -f "$ROOT/daml.yaml" ]; then
	fail "the repository root is a workspace, not a Daml package"
fi

workspace_sdk="$(sed -n 's/^sdk-version:[[:space:]]*//p' "$ROOT/multi-package.yaml")"
[ -n "$workspace_sdk" ] || fail "multi-package.yaml must declare sdk-version"

package_paths="$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$ROOT/multi-package.yaml")" ||
	fail "failed to read package paths from multi-package.yaml"
[ -n "$package_paths" ] || fail "multi-package.yaml declares no packages"

declared_manifests=""
while IFS= read -r package_path; do
	case "$package_path" in
	/* | ../* | */../* | */..)
		fail "multi-package.yaml contains an unsafe package path: $package_path"
		;;
	esac
	require_file "$package_path/daml.yaml"
	declared_manifests="${declared_manifests}${ROOT}/${package_path}/daml.yaml\n"
done <<< "$package_paths"

actual_manifests="$(find "$ROOT/experiments" -name daml.yaml -type f -not -path '*/.daml/*' | sort)" ||
	fail "failed to discover experiment manifests"
[ -n "$actual_manifests" ] || fail "no experiment manifests found"

if [ "$(printf '%b' "$declared_manifests" | sed '/^$/d' | sort)" != "$actual_manifests" ]; then
	fail "multi-package.yaml must list every experiment package exactly once"
fi

while IFS= read -r manifest; do
	package_sdk="$(sed -n 's/^sdk-version:[[:space:]]*//p' "$manifest")"
	[ "$package_sdk" = "$workspace_sdk" ] ||
		fail "${manifest#"$ROOT/"} sdk-version must match multi-package.yaml"
	grep -Eq '^[[:space:]]*-[[:space:]]*--target=2\.1[[:space:]]*$' "$manifest" ||
		fail "${manifest#"$ROOT/"} must target Daml-LF 2.1"

	package_name="$(sed -n 's/^name:[[:space:]]*//p' "$manifest")"
	package_version="$(sed -n 's/^version:[[:space:]]*//p' "$manifest")"
	if grep -Eq '(^|[[:space:]-])daml-script($|[[:space:]])' "$manifest"; then
		case "$package_name" in
		*-test)
			case "${manifest#"$ROOT/"}" in
			*/test/daml.yaml) ;;
			*) fail "${manifest#"$ROOT/"} test package must use a test/ directory" ;;
			esac
			[ "$package_version" = "0.0.0" ] ||
				fail "${manifest#"$ROOT/"} test package must use version 0.0.0"
			;;
		*-driver-v1 | *-driver-v2)
			case "${manifest#"$ROOT/"}" in
			*/driver-v1/daml.yaml | */driver-v2/daml.yaml) ;;
			*) fail "${manifest#"$ROOT/"} driver package must use a driver-vN/ directory" ;;
			esac
			;;
		*-exemplar) ;;
		*) fail "${manifest#"$ROOT/"} has an unclassified daml-script package name" ;;
		esac
	fi
done <<< "$actual_manifests"

if grep -R -n -E \
	--exclude-dir=.git --exclude-dir=.daml --exclude-dir=.cache --exclude-dir=.vscode --exclude-dir=.claude \
	--exclude='*.dar' --exclude='check.sh' \
	'/Users/|/home/[^/]+/|/private/tmp/|/var/folders/|[A-Za-z]:\\Users\\' "$ROOT"; then
	fail "repository content contains a machine-specific home path"
fi

artifact_lines="$(awk '
  /^[[:space:]]+-[[:space:]]+package:/ { package=$3 }
  /^[[:space:]]+version:/ { version=$2 }
  /^[[:space:]]+file:/ { file=$2 }
  /^[[:space:]]+main-package-id:/ { package_id=$2 }
  /^[[:space:]]+sha256:/ { sha256=$2 }
  /^[[:space:]]+license:/ {
    print package "\t" version "\t" file "\t" package_id "\t" sha256
    package=version=file=package_id=sha256=""
  }
' "$ROOT/dars/manifest.yaml")"
[ -n "$artifact_lines" ] || fail "dars/manifest.yaml contains no artifact records"

manifest_artifacts="$(printf '%s\n' "$artifact_lines" | cut -f3 | sort)"
vendored_artifacts="$(
	find "$ROOT/dars/vendor" "$ROOT/dars/token-standard" -maxdepth 1 -type f -name '*.dar' -print |
		sed "s#^$ROOT/##" |
		sort
)" || fail "failed to discover vendored DARs"
[ "$manifest_artifacts" = "$vendored_artifacts" ] ||
	fail "dars/manifest.yaml must list every vendored DAR exactly once"

while IFS=$'\t' read -r package version file package_id expected; do
	case "$file" in
	dars/vendor/*.dar | dars/token-standard/*.dar) ;;
	*) fail "dars/manifest.yaml contains an unsafe artifact path: $file" ;;
	esac
	case "$file" in
	/* | ../* | */../* | */..)
		fail "dars/manifest.yaml contains an unsafe artifact path: $file"
		;;
	esac
	require_file "$file"
	actual="$(shasum -a 256 "$ROOT/$file" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || fail "$file SHA-256 does not match dars/manifest.yaml"

	dpm damlc validate-dar "$ROOT/$file" >/dev/null
	inspect_fields="$(dpm damlc inspect-dar "$ROOT/$file" --json | python3 -c '
import json
import sys

dar = json.load(sys.stdin)
package_id = dar["main_package_id"]
package = dar["packages"][package_id]
print("\t".join((package_id, package["name"], package["version"])))
')"
	IFS=$'\t' read -r actual_package_id actual_package actual_version <<< "$inspect_fields"
	[ "$actual_package_id" = "$package_id" ] || fail "$file main package ID does not match dars/manifest.yaml"
	[ "$actual_package" = "$package" ] || fail "$file package name does not match dars/manifest.yaml"
	[ "$actual_version" = "$version" ] || fail "$file package version does not match dars/manifest.yaml"
done <<< "$artifact_lines"

printf 'check: OK\n'
