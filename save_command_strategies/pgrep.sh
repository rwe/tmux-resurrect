#!/usr/bin/env bash
set -Eeu -o pipefail

main() {
	local pane_pid="$1"
	[[ -n "${pane_pid}" ]] || return 0

	# GNU and macOS/BSD pgrep have incompatible interfaces.
	#
	# GNU pgrep needs `-a` to get the whole command line. Its output deletes
	# quotes and special characters, so the arg list cannot be (reliably)
	# reconstructed from it.
	#
	# macOS pgrep needs `-lf` to get the whole command line, and `-a` means
	# something else. It also deletes quotes, but not all special characters: for
	# example, newlines are printed raw. Although not necessary here, this would
	# make it impossible to distinguish more than one entry.
	#
	# Neither implementation's `-d` option permits NULL-separated entries like
	# one might hope. Both of these tools are a mess. See ./ps.sh for an example
	# command line that demonstrates these issues.
	local args=()
	if [[ "${OSTYPE}" == *darwin* ]]; then
		args=(-lf)
	else
		args=(-a)
	fi
	args+=(-P "$pane_id")

	pgrep "${args[@]}" |
		cut -d' ' -f2-
}

main "$@"
