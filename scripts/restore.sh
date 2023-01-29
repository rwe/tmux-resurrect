#!/usr/bin/env bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "$CURRENT_DIR/process_restore_helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"

# Global variable.
# Used during the restore: if a pane already exists from before, it is
# saved in the array in this variable. Later, process running in existing pane
# is also not restored. That makes the restoration process more idempotent.
declare -a EXISTING_PANES_VAR

: "${RESTORING_FROM_SCRATCH:=false}"
: "${RESTORE_PANE_CONTENTS:=false}"
: "${RESTORED_SESSION_0:=false}"


# Filter records by type, where the type is a constant given in the first field
# of the record.
records-of-type() {
	local record_type="$1"
	# Filter with grep, but only fail on real errors, not "no matches" (status 1).
	\grep "^${record_type}${d}" || [[ $? -eq 1 ]]
}

each-record() {
	local record_type="$1"
	shift
	while "$@"; do
		:
	done < <(records-of-type "${record_type}" || :)
}

check_saved_session_exists() {
	local resurrect_file
	resurrect_file="$1"
	if [[ ! -f "$resurrect_file" ]]; then
		display_message 'Tmux resurrect file not found!'
		return 1
	fi
}

pane_exists() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	tmux list-panes -t "${session_name}:${window_index}" -F '#{pane_index}' 2>/dev/null |
		\grep -qFx "$pane_index"
}

register_existing_pane() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_custom_id="${session_name}:${window_index}.${pane_index}"
	EXISTING_PANES_VAR+=("${pane_custom_id}")
}

is_pane_registered_as_existing() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_custom_id="${session_name}:${window_index}.${pane_index}"
	local IFS="$d"
	[[ "${EXISTING_PANES_VAR[*]}" =~ (^|[$IFS])"${pane_custom_id}"([$IFS]|$) ]]
}

restore_from_scratch_true() {
	RESTORING_FROM_SCRATCH=true
}

is_restoring_from_scratch() {
	[[ "$RESTORING_FROM_SCRATCH" == true ]]
}

restore_pane_contents_true() {
	RESTORE_PANE_CONTENTS=true
}

is_restoring_pane_contents() {
	[[ "$RESTORE_PANE_CONTENTS" == true ]]
}

restored_session_0_true() {
	RESTORED_SESSION_0=true
}

has_restored_session_0() {
	[[ "$RESTORED_SESSION_0" == true ]]
}

window_exists() {
	local session_name="$1"
	local window_index="$2"
	tmux list-windows -t "$session_name" -F '#{window_index}' 2>/dev/null |
		\grep -qFx "$window_index"
}

session_exists() {
	local session_name="$1"
	tmux has-session -t "$session_name" 2>/dev/null
}

first_window_index() {
	tmux show -gv base-index
}

tmux_socket() {
	local tmux_socket _tmux_pid _tmux_session
	IFS=, read -r tmux_socket _tmux_pid _tmux_session <<< "${TMUX?TMUX environment is not set}"
	out "${tmux_socket}"
}

get_tmux_default_command() {
	local default_shell
	default_shell="$(get_tmux_option 'default-shell' '')"
	local opt=''
	if [[ "$(basename "$default_shell")" == bash ]]; then
		opt='-l '
	fi
	get_tmux_option 'default-command' "$opt$default_shell"
}

# Tmux option stored in a global variable so that we don't have to "ask"
# tmux server each time.
tmux_default_command() {
	if [[ -z "${TMUX_DEFAULT_COMMAND+x}" ]]; then
		TMUX_DEFAULT_COMMAND="$(get_tmux_default_command)"
		export TMUX_DEFAULT_COMMAND
	fi
	out "$TMUX_DEFAULT_COMMAND"
}

pane_creation_command() {
	# Note that the command itself is a literal shell command, and so is
	# intentionally spliced with '%s' rather than '%q'.
	printf 'cat %q; exec %s' "$(pane_contents_file 'restore' "${1}:${2}.${3}")" "$(tmux_default_command)"
}

new_window() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_current_path_goal="$4"
	local pane_id="${session_name}:${window_index}.${pane_index}"
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		local pane_creation_command
		pane_creation_command="$(pane_creation_command "$session_name" "$window_index" "$pane_index")"
		tmux new-window -d -t "${session_name}:${window_index}" -c "$pane_current_path_goal" "$pane_creation_command"
	else
		tmux new-window -d -t "${session_name}:${window_index}" -c "$pane_current_path_goal"
	fi
}

new_session() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_current_path_goal="$4"
	local pane_id="${session_name}:${window_index}.${pane_index}"
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		local pane_creation_command
		pane_creation_command="$(pane_creation_command "$session_name" "$window_index" "$pane_index")"
		TMUX='' tmux -S "$(tmux_socket)" new-session -d -s "$session_name" -c "$pane_current_path_goal" "$pane_creation_command"
	else
		TMUX='' tmux -S "$(tmux_socket)" new-session -d -s "$session_name" -c "$pane_current_path_goal"
	fi
	# change first window number if necessary
	local created_window_index
	created_window_index="$(first_window_index)"
	if [[ "$created_window_index" -ne "$window_index" ]]; then
		tmux move-window -s "${session_name}:${created_window_index}" -t "${session_name}:${window_index}"
	fi
}

new_pane() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	local pane_current_path_goal="$4"
	local pane_id="${session_name}:${window_index}.${pane_index}"
	if is_restoring_pane_contents && pane_contents_file_exists "$pane_id"; then
		local pane_creation_command
		pane_creation_command="$(pane_creation_command "$session_name" "$window_index" "$pane_index")"
		tmux split-window -t "${session_name}:${window_index}" -c "$pane_current_path_goal" "$pane_creation_command"
	else
		tmux split-window -t "${session_name}:${window_index}" -c "$pane_current_path_goal"
	fi
	# minimize window so more panes can fit
	tmux resize-pane -t "${session_name}:${window_index}" -U 999
}

restore_pane() {
	local _line_type session_name window_index _window_active _colon_window_flags pane_index pane_title colon_pane_current_path _pane_active _pane_current_command colon_pane_full_command
	IFS=$d read _line_type session_name window_index _window_active _colon_window_flags pane_index pane_title colon_pane_current_path _pane_active _pane_current_command colon_pane_full_command || return $?

	local pane_current_path_goal
	pane_current_path_goal="${colon_pane_current_path#:}"
	pane_current_path_goal="${pane_current_path_goal/#\~/$HOME}"

	local pane_full_command_goal
	pane_full_command_goal="${colon_pane_full_command#:}"

	if [[ "$session_name" == '0' ]]; then
		restored_session_0_true
	fi
	if pane_exists "$session_name" "$window_index" "$pane_index"; then
		if is_restoring_from_scratch; then
			# overwrite the pane
			# happens only for the first pane if it's the only registered pane for the whole tmux server
			local pane_id
			pane_id="$(tmux display-message -p -F '#{pane_id}' -t "$session_name:$window_index")"
			new_pane "$session_name" "$window_index" "$pane_index" "$pane_current_path_goal"
			tmux kill-pane -t "$pane_id"
		else
			# Pane exists, no need to create it!
			# Pane existence is registered. Later, its process also won't be restored.
			register_existing_pane "$session_name" "$window_index" "$pane_index"
		fi
	elif window_exists "$session_name" "$window_index"; then
		new_pane "$session_name" "$window_index" "$pane_index" "$pane_current_path_goal"
	elif session_exists "$session_name"; then
		new_window "$session_name" "$window_index" "$pane_index" "$pane_current_path_goal"
	else
		new_session "$session_name" "$window_index" "$pane_index" "$pane_current_path_goal"
	fi
	# set pane title
	tmux select-pane -t "$session_name:$window_index.$pane_index" -T "$pane_title"
}

restore_active_and_alternate_session_state() {
	local _line_type client_session client_last_session
	IFS=$d read _line_type client_session client_last_session || return $?

	tmux switch-client -t "$client_last_session"
	tmux switch-client -t "$client_session"
}

restore_active_and_alternate_sessions() {
	each-record 'state' restore_active_and_alternate_session_state
}

restore_grouped_session() {
	local _line_type grouped_session original_session _colon_alternate_window_index _colon_active_window_index
	IFS=$d read _line_type grouped_session original_session _colon_alternate_window_index _colon_active_window_index || return $?

	TMUX='' tmux -S "$(tmux_socket)" new-session -d -s "$grouped_session" -t "$original_session"
}

restore_active_and_alternate_windows_for_grouped_session() {
	local _line_type grouped_session original_session colon_alternate_window_index colon_active_window_index
	IFS=$d read _line_type grouped_session original_session colon_alternate_window_index colon_active_window_index || return $?

	local alternate_window_index active_window_index
	alternate_window_index="${colon_alternate_window_index#:}"
	active_window_index="${colon_active_window_index#:}"
	if [[ -n "$alternate_window_index" ]]; then
		tmux switch-client -t "${grouped_session}:${alternate_window_index}"
	fi
	if [[ -n "$active_window_index" ]]; then
		tmux switch-client -t "${grouped_session}:${active_window_index}"
	fi
}

never_ever_overwrite() {
	local overwrite_option_value
	overwrite_option_value="$(get_tmux_option "$overwrite_option" '')"
	[[ -n "$overwrite_option_value" ]]
}

detect_if_restoring_from_scratch() {
	if never_ever_overwrite; then
		return
	fi
	local total_number_of_panes
	total_number_of_panes="$(tmux list-panes -a | \grep -c .)"
	if [[ "$total_number_of_panes" -eq 1 ]]; then
		restore_from_scratch_true
	fi
}

detect_if_restoring_pane_contents() {
	if capture_pane_contents_option_on; then
		restore_pane_contents_true
	fi
}

# functions called from main (ordered)

restore_all_panes() {
	detect_if_restoring_from_scratch   # sets a global variable
	detect_if_restoring_pane_contents  # sets a global variable
	if is_restoring_pane_contents; then
		pane_content_files_restore_from_archive
	fi

	each-record 'pane' restore_pane
}

handle_session_0() {
	if is_restoring_from_scratch && ! has_restored_session_0; then
		local current_session
		current_session="$(tmux display -p '#{client_session}')"
		if [[ "$current_session" == '0' ]]; then
			tmux switch-client -n
		fi
		tmux kill-session -t '0'
	fi
}

restore_window_property() {
	local _line_type session_name window_index colon_window_name _window_active _colon_window_flags window_layout automatic_rename
	IFS=$d read _line_type session_name window_index colon_window_name _window_active _colon_window_flags window_layout automatic_rename || return $?

	tmux select-layout -t "${session_name}:${window_index}" "$window_layout"

	# Below steps are properly handling window names and automatic-rename
	# option. `rename-window` is an extra command in some scenarios, but we
	# opted for always doing it to keep the code simple.
	local window_name
	window_name="${colon_window_name#:}"
	tmux rename-window -t "${session_name}:${window_index}" "$window_name"
	if [[ "${automatic_rename}" == ':' ]]; then
		tmux set-option -u -t "${session_name}:${window_index}" automatic-rename
	else
		tmux set-option -t "${session_name}:${window_index}" automatic-rename "$automatic_rename"
	fi
}

restore_window_properties() {
	each-record 'window' restore_window_property
}

restore_one_pane_process() {
	local _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title colon_pane_current_path _pane_active _pane_current_command colon_pane_full_command
	IFS=$d read _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title colon_pane_current_path _pane_active _pane_current_command colon_pane_full_command || return $?

	local pane_current_path_goal
	pane_current_path_goal="${colon_pane_current_path#:}"

	local pane_full_command_goal
	pane_full_command_goal="${colon_pane_full_command#:}"
	[[ -n "${pane_full_command_goal}" ]] || return 0

	restore_pane_process "$pane_full_command_goal" "$session_name" "$window_index" "$pane_index" "$pane_current_path_goal"
}

restore_all_pane_processes() {
	restore_pane_processes_enabled || return 0

	each-record 'pane' restore_one_pane_process
}

restore_active_pane_for_window() {
	local _line_type session_name window_index _window_active _colon_window_flags pane_index pane_title _colon_pane_current_path pane_active _pane_current_command _colon_pane_full_command
	IFS=$d read _line_type session_name window_index _window_active _colon_window_flags pane_index pane_title _colon_pane_current_path pane_active _pane_current_command _colon_pane_full_command || return $?
	[[ "${pane_active}" == 1 ]] || return 0
	tmux switch-client -t "${session_name}:${window_index}"
	tmux select-pane -t "$pane_index"
}

restore_active_pane_for_each_window() {
	each-record 'pane' restore_active_pane_for_window
}

restore_zoomed_window() {
	local _line_type session_name window_index _window_active colon_window_flags _pane_index _pane_title _colon_pane_current_path pane_active _pane_current_command _colon_pane_full_command
	IFS=$d read _line_type session_name window_index _window_active colon_window_flags _pane_index _pane_title _colon_pane_current_path pane_active _pane_current_command _colon_pane_full_command || return $?

	[[ "${colon_window_flags}" == *Z* ]] || return 0
	[[ "${pane_active}" == 1 ]] || return 0
	tmux resize-pane -t "${session_name}:${window_index}" -Z
}

restore_zoomed_windows() {
	each-record 'pane' restore_zoomed_window
}

restore_grouped_session_and_windows() {
	local line
	read line || return $?

	restore_grouped_session <<< "$line"
	restore_active_and_alternate_windows_for_grouped_session <<< "$line"
}

restore_grouped_sessions() {
	each-record 'grouped_session' restore_grouped_session_and_windows
}

restore_active_and_alternate_windows() {
	# Collect the alternate and active windows for each session.
	local alternate_window_targets=()
	local active_window_targets=()

	local _line_type session_name window_index _colon_window_name _window_active colon_window_flags _window_layout _automatic_rename
	while IFS=$d read _line_type session_name window_index _colon_window_name _window_active colon_window_flags _window_layout _automatic_rename; do
		local target="${session_name}:${window_index}"
		if [[ "$colon_window_flags" == *-* ]]; then
			alternate_window_targets+=("${target}")
		elif [[ "$colon_window_flags" == *\** ]]; then
			active_window_targets+=("${target}")
		fi
	done < <(records-of-type 'window' || :)

	# Switch to each "alternate" window first, then each "active" window.
	local target
	for target in "${alternate_window_targets[@]}" "${active_window_targets[@]}"; do
		tmux switch-client -t "${target}"
	done
}

# A cleanup that happens after 'restore_all_panes' seems to fix fish shell
# users' restore problems.
cleanup_restored_pane_contents() {
	if is_restoring_pane_contents; then
		rm "$(pane_contents_dir 'restore')"/*
	fi
}

main() {
	supported_tmux_version_ok || return $?

	local resurrect_file
	resurrect_file="$(last_resurrect_file)"

	check_saved_session_exists "${resurrect_file}" || return $?

	start_spinner 'Restoring...' 'Tmux restore complete!'
	execute_hook 'pre-restore-all'
	restore_all_panes < "${resurrect_file}"
	handle_session_0
	restore_window_properties >/dev/null 2>&1 < "${resurrect_file}"
	execute_hook 'pre-restore-pane-processes'
	restore_all_pane_processes < "${resurrect_file}"
	# below functions restore exact cursor positions
	restore_active_pane_for_each_window < "${resurrect_file}"
	restore_zoomed_windows < "${resurrect_file}"
	# also restores active and alt windows for grouped sessions
	restore_grouped_sessions < "${resurrect_file}"
	restore_active_and_alternate_windows  < "${resurrect_file}"
	restore_active_and_alternate_sessions < "${resurrect_file}"
	cleanup_restored_pane_contents
	execute_hook 'post-restore-all'
	stop_spinner
	display_message 'Tmux restore complete!'
}
main
