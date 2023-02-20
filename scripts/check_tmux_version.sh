#!/usr/bin/env bash

get_tmux_option() {
	local option=$1
	local default_value=$2
	local option_value
	option_value=$(tmux show-option -gqv "$option")
	if [ -z "$option_value" ]; then
		echo "$default_value"
	else
		echo "$option_value"
	fi
}

# Ensures a message is displayed for 5 seconds in tmux prompt.
# Does not override the 'display-time' tmux option.
display_message() {
	local message="$1"

	# display_duration defaults to 5 seconds, if not passed as an argument
		local display_duration
	if [ "$#" -eq 2 ]; then
		display_duration="$2"
	else
		display_duration="5000"
	fi

	# saves user-set 'display-time' option
	local saved_display_time
	saved_display_time=$(get_tmux_option "display-time" "750")

	# sets message display time to 5 seconds
	tmux set-option -gq display-time "$display_duration"

	# displays message
	tmux display-message "$message"

	# restores original 'display-time' value
	tmux set-option -gq display-time "$saved_display_time"
}

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

tmr:check-tmux-version() {
	local version
	version="$1"

	local unsupported_msg
	unsupported_msg="${2:-"Error, Tmux version unsupported! Please install Tmux version $version or greater!"}"

	local supported_version_int
	supported_version_int="$(coerce-int "$version")"

	local tmux_version_string
	tmux_version_string="$(tmux -V)"

	local tmux_version_int
	tmux_version_int="$(coerce-int "$tmux_version_string")"

	if (( tmux_version_int < supported_version_int )); then
		display_message "$unsupported_msg"
		return 1
	fi
}

[[ "${#BASH_SOURCE[@]}" -ne 1 || "${BASH_SOURCE[0]}" != "${0}" ]] || tmr:check-tmux-version "$@"
