# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "$CURRENT_DIR/helpers.sh"

get_restore_processes_option() {
	get_tmux_option "$restore_processes_option" "$restore_processes"
}

restore_pane_processes_enabled() {
	local restore_processes
	restore_processes="$(get_restore_processes_option)"
	[[ "$restore_processes" != false ]]
}

get_pane_restoration_command() {
	local pane_full_command_goal="$1"
	local pane_current_path_goal="$2"

	local restored_command
	restored_command="$(_get_maybe_restored_command "$pane_full_command_goal")" || return

	# Collect non-empty strategies.
	local s strategies=()
	for s in "$restored_command" "$pane_full_command_goal"; do
		[[ -n "$s" ]] || continue
		strategies+=("$s")

		# check for additional "expansion" of inline strategy, e.g. `vim` to `vim -S`
		if _strategy_exists "$s"; then
			local strategy_file
			strategy_file="$(_get_strategy_file "$s")"
			"$strategy_file" "$pane_full_command_goal" "$pane_current_path_goal"
			return
		fi
	done

	# fall back to just the inline strategy or full command.
	# If there are none, return failure.
	[[ ${#strategies[@]} -gt 0 ]] && out "${strategies[0]}"
}

restore_pane_process() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_current_path_goal="$4"
	local pane_full_command_goal="$5"

	local pane_id
	pane_id="$(custom_pane_id "$session_name" "$window_index" "$pane_index")"

	if is_pane_registered_as_existing "$session_name" "$window_index" "$pane_index"; then
		# Scenario where pane existed before restoration, so we're not
		# restoring the proces either.
		return
	elif ! pane_exists "$session_name" "$window_index" "$pane_index"; then
		# pane number limit exceeded, pane does not exist
		return
	elif ! _process_on_the_restore_list "$pane_full_command_goal"; then
		return
	fi

	tmux switch-client -t "${session_name}:${window_index}"
	tmux select-pane -t "$pane_index"

	local pane_full_command
	pane_full_command="$(get_pane_restoration_command "$pane_full_command_goal" "$pane_current_path_goal")" || return 0
	[[ -n "${pane_full_command}" ]] || return 0

	tmux send-keys -t "${pane_id}" "$pane_full_command" 'C-m'
}

_process_on_the_restore_list() {
	local pane_full_command="$1"

	local procs=()
	read -r -a procs < <(_restore_list)

	local proc
	for proc in "${procs[@]}"; do
		[[ -n "$proc" ]] || continue
		if [[ "$proc" == ':all:' ]]; then
			return 0
		fi
		local match
		match="$(_get_proc_match_element "$proc")"
		if _proc_matches_full_command "$pane_full_command" "$match"; then
			return 0
		fi
	done
	return 1
}

_proc_matches_full_command() {
	local pane_full_command="$1"
	local match="$2"
	if [[ "$match" == '~'* ]]; then
		match="${match#'~'}"
		# pattern matching the command makes sure `$match` string is somewhere in the command string
		[[ "$pane_full_command" == *"${match}"* ]]
	else
		# regex matching the command makes sure process is a "word"
		[[ "$pane_full_command" =~ (^"${match}"(["$IFS"]|$)) ]]
	fi
}

_get_proc_match_element() {
	out "${1%"${inline_strategy_token}"*}"
}

_get_proc_restore_element() {
	out "${1##*"${inline_strategy_token}"}"
}

# given full command: 'ruby /Users/john/bin/my_program arg1 arg2'
# and inline strategy: '~bin/my_program->my_program *'
# returns: 'arg1 arg2'
_get_command_arguments() {
	local pane_full_command="$1"
	local match="$2"
	match="${match#'~'}"  # remove leading tilde, if any.
	# Strip out anything leading up to the (first) match.
	pane_full_command="${pane_full_command#*"${match}"}"
	# Strip out everything up until the next space.
	pane_full_command="${pane_full_command#* }"
	out "${pane_full_command}"
}

_get_proc_restore_command() {
	local pane_full_command="$1"
	local proc="$2"
	local match="$3"
	local restore_element
	restore_element="$(_get_proc_restore_element "$proc")"
	if [[ "$restore_element" == *" ${inline_strategy_arguments_token}"* ]]; then
		# replaces "%" with command arguments
		local command_arguments
		command_arguments="$(_get_command_arguments "$pane_full_command" "$match")"
		out "${restore_element/ "${inline_strategy_arguments_token}"/ ${command_arguments}}"
	else
		out "$restore_element"
	fi
}

_restore_list() {
	local default_procs
	default_procs="$(get_tmux_option "$default_proc_list_option" "$default_proc_list")"

	local user_procs
	user_procs="$(get_restore_processes_option)"

	outln "$default_procs $user_procs"
}

# For the given command, check all of the process list options.
# If any of them are "inline strategies" (include ` -> `), then this outputs
# the processed command based on that. If the list includes ':all:', or any
# element which is a prefix of the command, then the original command is
# output.
# Otherwise, 1 is returned.
_get_maybe_restored_command() {
	local pane_full_command="$1"

	local procs=()
	read -r -a procs < <(_restore_list)

	local match_non_inline=

	local proc
	for proc in "${procs[@]}"; do
		[[ -n "$proc" ]] || continue
		if [[ "$proc" == ':all:' ]]; then
			match_non_inline=true
			continue
		fi
		local match
		match="$(_get_proc_match_element "$proc")"
		if _proc_matches_full_command "$pane_full_command" "$match"; then
			if [[ "$proc" == *"$inline_strategy_token"* ]]; then
				_get_proc_restore_command "$pane_full_command" "$proc" "$match"
				return 0
			else
				match_non_inline=true
			fi
		fi
	done

	if [[ "${match_non_inline}" == true ]]; then
		outln "${pane_full_command}"
		return 0
	fi
	return 1
}

_strategy_exists() {
	local pane_full_command="$1"
	[[ -n "$pane_full_command" ]] || return 1

	# strategy set?
	local strategy
	strategy="$(_get_command_strategy "$pane_full_command")"
	[[ -n "$strategy" ]] || return 1

	# strategy file exists?
	local strategy_file
	strategy_file="$(_get_strategy_file "$pane_full_command")"
	[[ -e "$strategy_file" ]] || return 1
}

_get_command_strategy() {
	local pane_full_command="$1"
	local command
	command="$(_just_command "$pane_full_command")"
	get_tmux_option "${restore_process_strategy_option}${command}" ''
}

_just_command() {
	# Remove everything after first space.
	out "${1%% *}"
}

_get_strategy_file() {
	local pane_full_command="$1"
	local strategy
	strategy="$(_get_command_strategy "$pane_full_command")"
	local command
	command="$(_just_command "$pane_full_command")"
	out "$CURRENT_DIR/../strategies/${command}_${strategy}.sh"
}
