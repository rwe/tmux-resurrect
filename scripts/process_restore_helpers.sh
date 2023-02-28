# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "$CURRENT_DIR/helpers.sh"

restore_pane_processes_enabled() {
	local restore_processes
	restore_processes="$(get_tmux_option "$restore_processes_option" "$restore_processes")"
	[[ "$restore_processes" != false ]]
}

restore_pane_process() {
	local pane_full_command_goal="$1"
	local session_name="$2"
	local window_index="$3"
	local pane_index="$4"
	local pane_current_path_goal="$5"
	local pane_full_command
	if _process_should_be_restored "$pane_full_command_goal" "$session_name" "$window_index" "$pane_index"; then
		tmux switch-client -t "${session_name}:${window_index}"
		tmux select-pane -t "$pane_index"

		local inline_strategy
		inline_strategy="$(_get_inline_strategy "$pane_full_command_goal")" # might not be defined
		if [[ -n "$inline_strategy" ]]; then
			# inline strategy exists
			# check for additional "expansion" of inline strategy, e.g. `vim` to `vim -S`
			if _strategy_exists "$inline_strategy"; then
				local strategy_file
				strategy_file="$(_get_strategy_file "$inline_strategy")"
				inline_strategy="$("$strategy_file" "$pane_full_command_goal" "$pane_current_path_goal")"
			fi
			pane_full_command="$inline_strategy"
		elif _strategy_exists "$pane_full_command_goal"; then
			local strategy_file
			strategy_file="$(_get_strategy_file "$pane_full_command_goal")"
			local strategy_command
			strategy_command="$("$strategy_file" "$pane_full_command_goal" "$pane_current_path_goal")"
			pane_full_command="$strategy_command"
		else
			# just invoke the raw command
			pane_full_command="$pane_full_command_goal"
		fi
		tmux send-keys -t "${session_name}:${window_index}.${pane_index}" "$pane_full_command" 'C-m'
	fi
}

# private functions below

_process_should_be_restored() {
	local pane_full_command_goal="$1"
	local session_name="$2"
	local window_index="$3"
	local pane_index="$4"
	if is_pane_registered_as_existing "$session_name" "$window_index" "$pane_index"; then
		# Scenario where pane existed before restoration, so we're not
		# restoring the proces either.
		return 1
	elif ! pane_exists "$session_name" "$window_index" "$pane_index"; then
		# pane number limit exceeded, pane does not exist
		return 1
	elif _restore_all_processes; then
		return 0
	elif _process_on_the_restore_list "$pane_full_command_goal"; then
		return 0
	else
		return 1
	fi
}

_restore_all_processes() {
	local restore_processes
	restore_processes="$(get_tmux_option "$restore_processes_option" "$restore_processes")"
	[[ "$restore_processes" == ':all:' ]]
}

_process_on_the_restore_list() {
	local pane_full_command="$1"

	local procs=()
	read -r -a procs < <(_restore_list)

	local proc
	for proc in "${procs[@]}"; do
		[[ -n "$proc" ]] || continue
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
	echo "${1%"${inline_strategy_token}"*}"
}

_get_proc_restore_element() {
	echo "${1##*"${inline_strategy_token}"}"
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
	echo "${pane_full_command}"
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
		echo "${restore_element/ "${inline_strategy_arguments_token}"/ ${command_arguments}}"
	else
		echo "$restore_element"
	fi
}

_restore_list() {
	local user_processes
	user_processes="$(get_tmux_option "$restore_processes_option" "$restore_processes")"

	local default_processes
	default_processes="$(get_tmux_option "$default_proc_list_option" "$default_proc_list")"
	if [[ -z "$user_processes" ]]; then
		# user didn't define any processes
		echo "$default_processes"
	else
		echo "$default_processes $user_processes"
	fi
}

_get_inline_strategy() {
	local pane_full_command="$1"

	local procs=()
	read -r -a procs < <(_restore_list)

	local proc
	for proc in "${procs[@]}"; do
		[[ "$proc" == *"$inline_strategy_token"* ]] || continue
		local match
		match="$(_get_proc_match_element "$proc")"
		if _proc_matches_full_command "$pane_full_command" "$match"; then
			_get_proc_restore_command "$pane_full_command" "$proc" "$match"
			return 0
		fi
	done
}

_strategy_exists() {
	local pane_full_command="$1"
	local strategy
	strategy="$(_get_command_strategy "$pane_full_command")"
	if [[ -n "$strategy" ]]; then # strategy set?
		local strategy_file
		strategy_file="$(_get_strategy_file "$pane_full_command")"
		[[ -e "$strategy_file" ]] # strategy file exists?
	else
		return 1
	fi
}

_get_command_strategy() {
	local pane_full_command="$1"
	local command
	command="$(_just_command "$pane_full_command")"
	get_tmux_option "${restore_process_strategy_option}${command}" ''
}

_just_command() {
	# Remove everything after first space.
	echo "${1%% *}"
}

_get_strategy_file() {
	local pane_full_command="$1"
	local strategy
	strategy="$(_get_command_strategy "$pane_full_command")"
	local command
	command="$(_just_command "$pane_full_command")"
	echo "$CURRENT_DIR/../strategies/${command}_${strategy}.sh"
}
