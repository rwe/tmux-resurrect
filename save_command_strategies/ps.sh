#!/usr/bin/env bash
set -Eeu -o pipefail

main() {
	local pane_pid="$1"
	[[ -n "${pane_pid}" ]] || return 0

	# GNU/Linux `ps` and macOS/BSD `ps` are not effective for programmatic
	# reconstruction of argument lists. They each irrecoverably chew them up in
	# their own way.
	#
	# Testing with an obtuse but valid command line:
	#   bash -c $'FOO=$1\nwhile sleep 5; do\n  echo "${FOO}" >> /dev/null;\ndone' -- $'\\012\n\\\n x\'x' $'hello\n  $there$!'
	# Alternatively written as:
	#   bash -c 'FOO=$1
	#   while sleep 5; do
	#     echo "${FOO}" >> /dev/null;
	#   done' \
	#   -- \
	#   $'\\012\n\\\n x\'x' \
	#   'hello
	#     $there$!'
	# which represents an argument list of literals constructed roughly like so:
	#   arg1='FOO=$1' + NEWLINE + 'while…done'
	#   arg2='--'
	#   arg4=BACKSLASH + '012' + NEWLINE + BACKSLASH + NEWLINE + SPACE + 'x' + SQUOTE + 'x'
	#   arg4='hello' + NEWLINE + SPACE + SPACE + '$there$!'
	#   ['bash', '-c', arg1, arg2, arg3, arg4]
	#
	# Is not recoverable at all through `ps` in either GNU/Linux or macOS.
	#
	# GNU/Linux `ps` omits argument delimiters (e.g. quoting) and special
	# characters in its output, but they cannot be inferred:
	#   bash -c FOO=$1 while sleep 5; do   echo "${FOO}" >> /dev/null; done -- \012 \  x'x hello   $there$!
	#
	# macOS `ps` also elides quotes, but has its own escaping scheme for
	# other things (e.g. newlines become \012). Yet, it inexplicably does not
	# escape spaces or backslashes; again, making it impossible to reliably
	# reconstruct the arg list.
	#   bash -c FOO=$1\012while sleep 5; do\012  echo "${FOO}" >> /dev/null;\012done -- \012\012\\012 x'x hello\012  $there$!
	#
	# Therefore this "strategy" can only function with very simple commands.
	local ppid cmd
	ps -ao 'ppid=,command=' | while read -r ppid cmd; do
		[[ "$ppid" -ne "$pane_pid" ]] || printf '%s\n' "${cmd}"
	done
}

main "$@"
