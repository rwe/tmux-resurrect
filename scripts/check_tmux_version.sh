#!/usr/bin/env bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "${CURRENT_DIR}/helpers.sh"

# Convert the string argument to an integer. All non-digit characters are
# removed, and the remaining digits are printed without leading zeros.
#
# This is used to get "clean" integer version number. Examples:
# `tmux 1.9` => `19`
# `1.9a`     => `19`
coerce-int() {
	# The '10#' prefix here ensures the value is interpreted as a decimal number.
	# This prevents leading zeros from causing an octal interpretaion.
	local int
	int="10#${1//[^[:digit:]]/}"
	echo $(( int ))
}

# Cached value of the integer digits of $(tmux -V).
tmr:tmux-version() {
	if [[ -z "${TMUX_VERSION_INT+x}" ]]; then
		local tmux_version_string
		tmux_version_string="$(tmux -V)"

		TMUX_VERSION_INT="$(coerce-int "$tmux_version_string")"
	fi
	echo "${TMUX_VERSION_INT}"
}

tmr:has-tmux-version() {
	local version="$1"
	local supported_version_int
	supported_version_int="$(coerce-int "$version")"

	local tmux_version_int
	tmux_version_int="$(tmr:tmux-version)"

	(( supported_version_int <= tmux_version_int ))
}

tmr:check-tmux-version() {
	local version
	version="$1"

	local unsupported_msg
	unsupported_msg="${2:-"Error, Tmux version unsupported! Please install Tmux version $version or greater!"}"

	if ! tmr:has-tmux-version "${version}"; then
		display_message "$unsupported_msg"
		return 1
	fi
}

[[ "${#BASH_SOURCE[@]}" -ne 1 || "${BASH_SOURCE[0]}" != "${0}" ]] || tmr:check-tmux-version "$@"
