#!/usr/bin/env bash

# This script shows tmux spinner with a message. It is intended to be running
# as a background process which should be `kill`ed at the end.
#
# Example usage:
#
#   ./tmux_spinner.sh "Working..." "End message!" &
#   SPINNER_PID=$!
#   ..
#   .. execute commands here
#   ..
#   kill $SPINNER_PID # Stops spinner and displays 'End message!'

_tmr-spinner:out() {
	tmux display-message "$1"
}

_tmr-spinner:glyph() {
	local i="$1" SPIN='-\|/'
	printf '%s' "${SPIN:$(( i % 4 )):1}"
}

_tmr-spinner:tick() {
	local i="$1" message="$2" glyph=' '

	glyph="$(_tmr-spinner:glyph "$i")"
	_tmr-spinner:out " $glyph $message"
	sleep 0.1
}

_tmr-spinner:loop() {
	local message="$1" i=0
	while _tmr-spinner:tick "$i" "$message"; do
		i=$(( i + 1 ))
	done
}

# Accepts message + list of traps. Unsets the traps, outputs message, returns
# the original status, or failure if message output failed.
_tmr-spinner:trap() {
	# Store current status before anything else.
	local status=$?
	# Rebind the traps to "exit", to immediately fail if any other error or signal occurs.
	trap exit "${@:2}"
	# Output the completion message.
	_tmr-spinner:out "$1" || status=$?
	# Exit with the initial or output-failure status.
	exit $status
}

_tmr:spinner:main() {
	set -Eeu -o pipefail
	local message="$1"
	local end_message="$2"
	local traps=(ERR SIGINT SIGTERM)
	trap '_tmr-spinner:trap "$end_message" "${traps[@]}"' "${traps[@]}"
	_tmr-spinner:loop "$message"
}

if [[ "${#BASH_SOURCE[@]}" -ne 1 || "${BASH_SOURCE[0]}" != "${0}" ]]; then
	# If we're being sourced, defined `tmr:spinner()` as a subshell function, to
	# avoid clobbering shell opts and traps.
	tmr:spinner() ( _tmr:spinner "$@"; )
else
	# Otherwhise run the function directly.
	_tmr:spinner "$@"
fi
