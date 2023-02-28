#!/usr/bin/env bash

# "irb default strategy"
#
# Example irb process with junk variables:
#   irb RBENV_VERSION=1.9.3-p429 GREP_COLOR=34;47 TERM_PROGRAM=Apple_Terminal
#
# When executed, the above will fail. This strategy handles that.

ORIGINAL_COMMAND="$1"
DIRECTORY="$2"

original_command_wo_junk_vars() {
	local command="${ORIGINAL_COMMAND}"
	command="${command//RBENV_VERSION[^ ]*/}"
	command="${command//GREP_COLOR[^ ]*/}"
	command="${command//TERM_PROGRAM[^ ]*/}"
	printf '%s\n' "${command}"
}

main() {
	original_command_wo_junk_vars
}
main
