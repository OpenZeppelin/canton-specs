#!/usr/bin/env bash

# Intentionally duplicated at scripts/dpm-env.sh and
# repos/canton-specs/scripts/dpm-env.sh so the repo remains independently
# buildable. Keep both copies in sync until an accepted vendoring step replaces
# the duplication.

oz_setup_java_env() {
	local java_home_candidate=""

	# Prefer the java already in use: if PATH resolves to a new enough runtime,
	# leave the caller's environment alone and do not second-guess it.
	oz_has_java_21_or_newer && return 0

	if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
		export PATH="$JAVA_HOME/bin:$PATH"
		oz_has_java_21_or_newer && return 0
	fi

	if [ -x /usr/libexec/java_home ]; then
		if java_home_candidate="$(/usr/libexec/java_home -v 21+ 2>/dev/null)"; then
			if [ -x "$java_home_candidate/bin/java" ]; then
				export JAVA_HOME="$java_home_candidate"
				export PATH="$JAVA_HOME/bin:$PATH"
				oz_has_java_21_or_newer && return 0
			fi
		fi
	fi

	for java_home_candidate in \
		/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
		/usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
		/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
		/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home; do
		if [ -x "$java_home_candidate/bin/java" ]; then
			export JAVA_HOME="$java_home_candidate"
			export PATH="$JAVA_HOME/bin:$PATH"
			oz_has_java_21_or_newer && return 0
		fi
	done
}

oz_setup_dpm_env() {
	local cache_root="${1:?cache root required}"

	export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root}"
	oz_setup_java_env || true

	if command -v dpm >/dev/null 2>&1; then
		return 0
	fi

	if [ -n "${HOME:-}" ] && [ -x "$HOME/.dpm/bin/dpm" ]; then
		export PATH="$HOME/.dpm/bin:$PATH"
	fi
}

oz_has_dpm() {
	command -v dpm >/dev/null 2>&1
}

oz_java_major_version() {
	local version_line=""
	local version_string=""
	local major=""

	command -v java >/dev/null 2>&1 || return 1
	version_line="$(java -version 2>&1 | head -n 1)" || return 1

	# Banners look like: openjdk version "25.0.3" 2026-04-21 LTS
	# Read the first quoted field so trailing date/LTS fields can never be
	# mistaken for the version.
	case "$version_line" in
	*\"*) ;;
	*) return 1 ;;
	esac
	version_string="${version_line#*\"}"
	version_string="${version_string%%\"*}"

	# Legacy numbering: 1.8.0_401 is Java 8.
	case "$version_string" in
	1.*) version_string="${version_string#1.}" ;;
	esac

	major="${version_string%%[!0-9]*}"
	[ -n "$major" ] || return 1
	printf '%s\n' "$major"
}

oz_has_java_21_or_newer() {
	local major=""

	major="$(oz_java_major_version)" || return 1
	[ "$major" -ge 21 ] 2>/dev/null
}
