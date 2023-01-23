#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

PANE_PID="$1"

exit_safely_if_empty_ppid() {
	if [ -z "$PANE_PID" ]; then
		exit 0
	fi
}

full_command() {
	ps -ao 'ppid=,command=' |
		sed -n 's/^[[:space:]]*'"${PANE_PID}"'[[:space:]]\{1,\}//p'
}

main() {
	exit_safely_if_empty_ppid
	full_command
}
main
