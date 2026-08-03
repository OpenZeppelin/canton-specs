#!/usr/bin/env bash
# CI orchestration for every declared package that contains Daml Script code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_paths="$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$ROOT/multi-package.yaml")"

[ -n "$package_paths" ] || {
	printf 'check-tests: multi-package.yaml declares no packages\n' >&2
	exit 1
}

script_package_count=0
while IFS= read -r package_path; do
	manifest="$ROOT/$package_path/daml.yaml"
	grep -Eq '(^|[[:space:]-])daml-script($|[[:space:]])' "$manifest" || continue

	package_name="$(sed -n 's/^name:[[:space:]]*//p' "$manifest")"
	script_package_count=$((script_package_count + 1))
	printf 'check-tests: %s\n' "$package_path"

	case "$package_name" in
	*-test)
		(cd "$ROOT" && DAML_PACKAGE="$package_path" dpm test --all --show-coverage)
		;;
	*-exemplar | *-driver-v1 | *-driver-v2)
		(cd "$ROOT" && DAML_PACKAGE="$package_path" dpm test)
		;;
	*)
		printf 'check-tests: unclassified daml-script package: %s (%s)\n' \
			"$package_path" "$package_name" >&2
		exit 1
		;;
	esac
done <<< "$package_paths"

[ "$script_package_count" -gt 0 ] || {
	printf 'check-tests: no daml-script packages declared\n' >&2
	exit 1
}

printf 'check-tests: OK\n'
