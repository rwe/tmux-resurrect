#!/usr/bin/env bash
set -Eeu -o pipefail

# "mosh-client default strategy"
#
# Example mosh-client process:
#   mosh-client -# charm tmux at | 198.199.104.142 60001
#
# When executed, the above will fail. This strategy handles that.

ORIGINAL_COMMAND="$1"
# unused: DIRECTORY="$2"

mosh_command() {
	local args="$ORIGINAL_COMMAND"

	args="${args#*-#}"
	args="${args%|*}"

	echo "mosh $args"
}

main() {
	mosh_command
}
main
