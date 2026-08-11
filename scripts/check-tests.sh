#!/usr/bin/env bash
# CI orchestration and aggregate coverage gate for every Daml Script package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

package_paths="$(sed -n 's/^[[:space:]]*-[[:space:]]*//p' "$ROOT/multi-package.yaml")"
coverage_dir="$(mktemp -d)"

cleanup() {
	[ -n "$coverage_dir" ] && [ -d "$coverage_dir" ] || return
	rm -rf -- "$coverage_dir"
}
trap cleanup EXIT

[ -n "$package_paths" ] || {
	printf 'check-tests: multi-package.yaml declares no packages\n' >&2
	exit 1
}

fail() {
	printf 'check-tests: %s\n' "$*" >&2
	exit 1
}

check_zero() {
	local report="$1"
	local metric="$2"
	local value=""

	value="$(sed -n "s/^  ${metric}: //p" "$report")"
	[ -n "$value" ] || fail "DPM metric not found: $metric"
	[ "$value" -eq 0 ] || fail "$metric: $value"
}

script_package_count=0
aggregate_package=""
coverage_inputs=()
while IFS= read -r package_path; do
	manifest="$ROOT/$package_path/daml.yaml"
	grep -Eq '(^|[[:space:]-])daml-script($|[[:space:]])' "$manifest" || continue

	package_name="$(sed -n 's/^name:[[:space:]]*//p' "$manifest")"
	coverage_file="$coverage_dir/$package_name.coverage"
	script_package_count=$((script_package_count + 1))
	printf 'check-tests: %s\n' "$package_path"

	case "$package_name" in
	*-test | *-driver-v1 | *-driver-v2)
		# Measure the repository packages consumed by isolated tests and SCU drivers.
		DAML_PACKAGE="$package_path" dpm test --all --save-coverage "$coverage_file"
		;;
	*-exemplar)
		# Measure the exemplar itself without adding vendored DAR internals.
		DAML_PACKAGE="$package_path" dpm test --save-coverage "$coverage_file"
		;;
	*)
		fail "unclassified daml-script package: $package_path ($package_name)"
		;;
	esac

	[ -n "$aggregate_package" ] || aggregate_package="$package_path"
	coverage_inputs+=(--load-coverage "$coverage_file")
done <<< "$package_paths"

[ "$script_package_count" -gt 0 ] || {
	printf 'check-tests: no daml-script packages declared\n' >&2
	exit 1
}

coverage_report="$coverage_dir/all.txt"
printf 'check-tests: aggregating coverage\n'
DAML_PACKAGE="$aggregate_package" dpm test \
	--load-coverage-only \
	"${coverage_inputs[@]}" \
	--show-coverage \
	| tee "$coverage_report"

check_zero "$coverage_report" "internal templates never created"
check_zero "$coverage_report" "internal template choices never exercised"
check_zero "$coverage_report" "internal interface choices never exercised"
check_zero "$coverage_report" "external templates never created"
check_zero "$coverage_report" "external template choices never exercised"
check_zero "$coverage_report" "external interface choices never exercised"

printf 'check-tests: OK (%d Daml Script packages, complete template/choice coverage)\n' \
	"$script_package_count"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### Daml experiment coverage"
		echo
		echo "All measured templates and choices have complete coverage across $script_package_count Daml Script packages."
		echo
		echo "Daml reports template/choice coverage, not source-line or branch coverage."
	} >> "$GITHUB_STEP_SUMMARY"
fi
