#!/usr/bin/env bash
#
# Top-level validation gate for the CIP-0112 settlement RI workspace.
#
# Builds every package in dependency order, runs the Daml Script spine suite in
# `test/`, and runs the deep settlement exemplar's scripts in
# `experiments/settlement-exemplar/`. The exemplar package is NOT a
# data-dependency of `test/` (its consumer template lives next to its scripts),
# so without this gate its scripts would never run under `cd test && dpm test`
# and could rot silently. CI (.github/workflows/ci.yml) invokes this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/dpm-env.sh"

oz_setup_dpm_env "$ROOT/.cache"
oz_has_dpm || {
	printf 'run-tests: dpm is not available; install DPM or expose ~/.dpm/bin/dpm\n' >&2
	exit 1
}
oz_has_java_21 || {
	printf 'run-tests: Java 21 runtime is not available; install or expose a JDK\n' >&2
	exit 1
}

printf 'run-tests: building all packages\n'
(cd "$ROOT" && dpm build --all)

printf 'run-tests: running the spine test suite (test/)\n'
(cd "$ROOT/test" && dpm test)

printf 'run-tests: running the deep settlement exemplar scripts (experiments/settlement-exemplar/)\n'
(cd "$ROOT/experiments/settlement-exemplar" && dpm test)

printf 'run-tests: OK\n'
