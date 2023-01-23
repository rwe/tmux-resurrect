#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"

# if "quiet" script produces no output
SCRIPT_OUTPUT="$1"

_grouped_sessions_tmux_fields=(
	'#{session_grouped}'
	'#{session_group}'
	'#{session_id}'
	'#{session_name}'
)

grouped_sessions_tmux_format="$(tmr:tmux-fields "${_grouped_sessions_tmux_fields[@]}")"

_pane_tmux_fields=(
	'#{l:pane}'
	'#{session_name}'
	'#{window_index}'
	'#{window_active}'
	':#{window_flags}'
	'#{pane_index}'
	'#{pane_title}'
	':#{pane_current_path}'
	'#{pane_active}'
	'#{pane_current_command}'
	'#{pane_pid}'
	'#{history_size}'
)

pane_tmux_format="$(tmr:tmux-fields "${_pane_tmux_fields[@]}")"

_window_tmux_fields=(
	'#{l:window}'
	'#{session_name}'
	'#{window_index}'
	':#{window_name}'
	'#{window_active}'
	':#{window_flags}'
	'#{window_layout}'
)

window_tmux_format="$(tmr:tmux-fields "${_window_tmux_fields[@]}")"

_state_tmux_fields=(
	'#{l:state}'
	'#{client_session}'
	'#{client_last_session}'
)

state_tmux_format="$(tmr:tmux-fields "${_state_tmux_fields[@]}")"

dump_panes_raw() {
	tmux list-panes -a -F "${pane_tmux_format}"
}

dump_windows_raw(){
	tmux list-windows -a -F "${window_tmux_format}"
}

toggle_window_zoom() {
	local target="$1"
	tmux resize-pane -Z -t "$target"
}

_save_command_strategy_file() {
	local save_command_strategy
	save_command_strategy="$(get_tmux_option "$save_command_strategy_option" "$default_save_command_strategy")"
	local strategy_file="$CURRENT_DIR/../save_command_strategies/${save_command_strategy}.sh"
	local default_strategy_file="$CURRENT_DIR/../save_command_strategies/${default_save_command_strategy}.sh"
	if [[ -e "$strategy_file" ]]; then # strategy file exists?
		echo "$strategy_file"
	else
		echo "$default_strategy_file"
	fi
}

pane_full_command() {
	local pane_pid="$1"
	local strategy_file
	strategy_file="$(_save_command_strategy_file)"
	# execute strategy script to get pane full command
	"$strategy_file" "$pane_pid"
}

number_nonempty_lines_on_screen() {
	local pane_id="$1"
	tmux capture-pane -pJ -t "$pane_id" | \grep -c .
}

# tests if there was any command output in the current pane
pane_has_any_content() {
	local pane_id="$1"
	local history_size
	history_size="$(tmux display -p -t "$pane_id" -F '#{history_size}')"

	local cursor_y
	cursor_y="$(tmux display -p -t "$pane_id" -F '#{cursor_y}')"
	# doing "cheap" tests first
	[[ "$history_size" -gt 0 ]] || # history has any content?
		[[ "$cursor_y" -gt 0 ]] || # cursor not in first line?
		[[ "$(number_nonempty_lines_on_screen "$pane_id")" -gt 1 ]]
}

capture_pane_contents() {
	local pane_id="$1"
	local start_line="-$2"
	local pane_contents_area="$3"
	if pane_has_any_content "$pane_id"; then
		if [[ "$pane_contents_area" == 'visible' ]]; then
			start_line=0
		fi
		# the printf hack below removes *trailing* empty lines
		printf '%s\n' "$(tmux capture-pane -epJ -S "$start_line" -t "$pane_id")" > "$(pane_contents_file 'save' "$pane_id")"
	fi
}

get_active_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" -F '#{window_flags} #{window_index}' |
		awk '$1 ~ /\*/ { print $2; }'
}

get_alternate_window_index() {
	local session_name="$1"
	tmux list-windows -t "$session_name" -F '#{window_flags} #{window_index}' |
		awk '$1 ~ /-/ { print $2; }'
}

dump_grouped_sessions() {
	local current_session_group=''
	local original_session
	local session_is_grouped session_group _session_id session_name

	tmux list-sessions -F "${grouped_sessions_tmux_format}" |
		sort |
		while IFS=$d read session_is_grouped session_group _session_id session_name; do
			[[ "${session_is_grouped}" == 1 ]] || continue
			if [[ "$session_group" != "$current_session_group" ]]; then
				# this session is the original/first session in the group
				original_session="$session_name"
				current_session_group="$session_group"
			else
				# this session "points" to the original session
				local colon_alternate_window_index colon_active_window_index
				colon_alternate_window_index=":$(get_alternate_window_index "$session_name")"
				colon_active_window_index=":$(get_active_window_index "$session_name")"
				local fields=(
					'grouped_session'
					"${session_name}"
					"${original_session}"
					"${colon_alternate_window_index}"
					"${colon_active_window_index}"
				)
				tmr:fields "${fields[@]}"
			fi
		done
}

fetch_and_dump_grouped_sessions(){
	local grouped_sessions_dump
	grouped_sessions_dump="$(dump_grouped_sessions)"

	[[ -n "$grouped_sessions_dump" ]] || return 0
	echo "$grouped_sessions_dump"

	local grouped_session_names_tsv
	grouped_session_names_tsv="$(get_grouped_sessions <<< "$grouped_sessions_dump")"

	IFS="$d" read -a GROUPED_SESSIONS <<< "${grouped_session_names_tsv}"
}

get_grouped_sessions() {
	# Reads grouped_session records and outputs tab-separated list of sessions.
	local _line_type session_name _original_session _colon_alternate_window_index _colon_active_window_index
	local grouped_session_names=()
	while IFS="$d" read _line_type session_name _original_session _colon_alternate_window_index _colon_active_window_index; do
		grouped_session_names+=("${session_name}")
	done
	local IFS="$d"
	echo "${grouped_session_names[*]}"
}

is_session_grouped() {
	local session_name="$1"
	local IFS="$d"
	[[ "${GROUPED_SESSIONS[*]}" =~ (^|[$IFS])"${session_name}"([$IFS]|$) ]]
}

# translates pane pid to process command running inside a pane
dump_panes() {
	local line_type session_name window_index window_active colon_window_flags pane_index pane_title colon_pane_current_path pane_active pane_current_command pane_pid _history_size
	dump_panes_raw |
		while IFS=$d read line_type session_name window_index window_active colon_window_flags pane_index pane_title colon_pane_current_path pane_active pane_current_command pane_pid _history_size; do
			# not saving panes from grouped sessions
			if is_session_grouped "$session_name"; then
				continue
			fi
			local colon_pane_full_command
			colon_pane_full_command=":$(pane_full_command "$pane_pid")"
			colon_pane_current_path="${colon_pane_current_path// /\\ }" # escape all spaces in directory path

			local fields=(
				"${line_type}"
				"${session_name}"
				"${window_index}"
				"${window_active}"
				"${colon_window_flags}"
				"${pane_index}"
				"${pane_title}"
				"${colon_pane_current_path}"
				"${pane_active}"
				"${pane_current_command}"
				"${colon_pane_full_command}"
			)
			tmr:fields "${fields[@]}"
		done
}

dump_windows() {
	local line_type session_name window_index colon_window_name window_active colon_window_flags window_layout

	dump_windows_raw |
		while IFS=$d read line_type session_name window_index colon_window_name window_active colon_window_flags window_layout; do
			# not saving windows from grouped sessions
			if is_session_grouped "$session_name"; then
				continue
			fi

			local automatic_rename
			automatic_rename="$(tmux show-window-options -vt "${session_name}:${window_index}" automatic-rename)"
			# If the option was unset, use ":" as a placeholder.
			: "${automatic_rename:=:}"

			local fields=(
				"${line_type}"
				"${session_name}"
				"${window_index}"
				"${colon_window_name}"
				"${window_active}"
				"${colon_window_flags}"
				"${window_layout}"
				"${automatic_rename}"
			)
			tmr:fields "${fields[@]}"
		done
}

dump_state() {
	tmux display-message -p "${state_tmux_format}"
}

dump_pane_contents() {
	local pane_contents_area
	pane_contents_area="$(get_tmux_option "$pane_contents_area_option" "$default_pane_contents_area")"

	local _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title _colon_pane_current_path _pane_active _pane_current_command _pane_pid history_size
	dump_panes_raw |
		while IFS=$d read _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title _colon_pane_current_path _pane_active _pane_current_command _pane_pid history_size; do
			capture_pane_contents "${session_name}:${window_index}.${pane_index}" "$history_size" "$pane_contents_area"
		done
}

remove_old_backups() {
	# remove resurrect files older than 30 days (default), but keep at least 5 copies of backup.
	local delete_after
	delete_after="$(get_tmux_option "$delete_backup_after_option" "$default_delete_backup_after")"
	local -a files
	files=($(ls -t "$(resurrect_dir)/${RESURRECT_FILE_PREFIX}_"*".${RESURRECT_FILE_EXTENSION}" | tail -n +6))
	[[ ${#files[@]} -eq 0 ]] ||
		find "${files[@]}" -type f -mtime "+${delete_after}" -exec rm -v '{}' ';' > /dev/null
}

save_all() {
	local resurrect_file_path
	resurrect_file_path="$(new_resurrect_file_path)"

	local last_resurrect_file
	last_resurrect_file="$(last_resurrect_file)"

	mkdir -p "$(resurrect_dir)"
	{
		fetch_and_dump_grouped_sessions
		dump_panes
		dump_windows
		dump_state
	} > "$resurrect_file_path"
	execute_hook 'post-save-layout' "$resurrect_file_path"
	if files_differ "$resurrect_file_path" "$last_resurrect_file"; then
		ln -fs "$(basename "$resurrect_file_path")" "$last_resurrect_file"
	else
		rm "$resurrect_file_path"
	fi
	if capture_pane_contents_option_on; then
		mkdir -p "$(pane_contents_dir 'save')"
		dump_pane_contents
		pane_contents_create_archive
		rm "$(pane_contents_dir 'save')"/*
	fi
	remove_old_backups
	execute_hook 'post-save-all'
}

show_output() {
	[[ "$SCRIPT_OUTPUT" != 'quiet' ]]
}

main() {
	if supported_tmux_version_ok; then
		if show_output; then
			start_spinner 'Saving...' 'Tmux environment saved!'
		fi
		save_all
		if show_output; then
			stop_spinner
			display_message 'Tmux environment saved!'
		fi
	fi
}
main
