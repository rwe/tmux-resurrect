#!/usr/bin/env bash
set -Eeu -o pipefail

# Quote a value as a C literal string.
c:() {
	local val="$1" val_q
	printf -v val_q '%q' "${val}"

	# Either the value is rendered in "ANSI" quotes $'…', or it's
	# backslash-escaped: either way, it means the same within C (not shell!)
	# double quotes.
	if [[ "${val_q}" =~ ^\$?\'(.*)\'$ ]]; then
		val_q="${BASH_REMATCH[1]}"
	fi
	printf '"%s"\n' "${val_q}"
}

main() (
	local pane_pid="$1"
	[[ -n "${pane_pid}" ]] || return 0

	local hist_loc
	hist_loc="$(mktemp -t "bash_history-${pane_pid}.XXXXXX")" || return $?
	trap 'rm -f "$hist_loc"' EXIT

	local hist_loc_c
	hist_loc_c="$(c: "${hist_loc}")"

	local gdb=(
		gdb -batch
		--eval "attach $pane_pid"
		# https://www.thanassis.space/bashheimer.html
		# This calls readline's `append_history` function to write
		# the most recent command to the file.
		# https://github.com/bminor/bash/blob/74091dd4e8086db518b30df7f222691524469998/lib/readline/histfile.c#L820-L824
		--eval "call append_history(1, ${hist_loc_c})"
		--eval 'detach'
		--eval 'q'
	)

	"${gdb[@]}" >/dev/null 2>&1 || return $?
	cat < "${hist_loc}"
)

main "$@"
