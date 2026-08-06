#!/usr/bin/env bash
# CI orchestration for linting every declared Daml package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_paths="$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$ROOT/multi-package.yaml")"

[ -n "$package_paths" ] || {
	printf 'check-lint: multi-package.yaml declares no packages\n' >&2
	exit 1
}

while IFS= read -r package_path; do
	printf 'check-lint: %s\n' "$package_path"
	(cd "$ROOT" && DAML_PACKAGE="$package_path" dpm damlc lint)
done <<< "$package_paths"

printf 'check-lint: OK\n'
