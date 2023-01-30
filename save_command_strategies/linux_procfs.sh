#!/usr/bin/env bash
set -Eeu -o pipefail

shell-quote() {
	[[ $# -lt 1 ]] || printf '%q' "$1"
	[[ $# -lt 2 ]] || printf ' %q' "${@:2}"
	printf '\n'
}
export -f shell-quote

main() {
	local pane_pid
	pane_pid="$1"
	[[ -n "${pane_pid}" ]] || return 0

	local command_pid
	command_pid="$(pgrep -P "$pane_pid")"
	[[ -n "$command_pid" ]] || return
	# See: https://unix.stackexchange.com/a/567021
	# Avoid complications with system printf by using bash subshell interpolation.
	# This will properly escape sequences and null in cmdline.
	xargs -0 < "/proc/${command_pid}/cmdline" "${BASH}" -c 'shell-quote "$@"' --
}

main "$@"
