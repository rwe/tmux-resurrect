#!/usr/bin/env bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/tmux_spinner.sh"
source "$CURRENT_DIR/check_tmux_version.sh"

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

_history_cursor_tmux_fields=(
	'#{history_size}'
	'#{cursor_y}'
)

history_cursor_tmux_format="$(tmr:tmux-fields "${_history_cursor_tmux_fields[@]}")"

_window_flag_index_tmux_fields=(
	'#{window_flags}'
	'#{window_index}'
)

window_flag_index_tmux_format="$(tmr:tmux-fields "${_window_flag_index_tmux_fields[@]}")"

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
		out "$strategy_file"
	else
		out "$default_strategy_file"
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

	# doing "cheap" tests first
	local history_and_cursor
	history_and_cursor="$(tmux display -p -t "$pane_id" -F "${history_cursor_tmux_format}")"

	local history_size cursor_y
	tmr:read history_size cursor_y <<< "${history_and_cursor}"

	# history has any content?
	[[ "$history_size" -le 0 ]] || return 0

	 # cursor not in first line?
	[[ "$cursor_y" -le 0 ]] || return 0

	local num_lines
	num_lines="$(number_nonempty_lines_on_screen "$pane_id")"
	[[ "$num_lines" -le 1 ]] || return 0

	# No content.
	return 1
}

capture_pane_contents() {
	local pane_id="$1"
	local start_line="-$2"
	local pane_contents_area="$3"

	pane_has_any_content "$pane_id" || return 0

	if [[ "$pane_contents_area" == 'visible' ]]; then
		start_line=0
	fi

	local content_file
	content_file="$(pane_contents_file 'save' "$pane_id")"

	# capturing to a variable removes *trailing* empty lines.
	# This is very inefficient if the scrollback is large.
	local contents
	contents="$(tmux capture-pane -epJ -S "$start_line" -t "$pane_id")"

	printf '%s\n' "$contents" > "$content_file"
}

dump_grouped_sessions() {
	local current_session_group=''
	local original_session
	local session_is_grouped session_group _session_id session_name

	local grouped_sessions
	grouped_sessions="$(tmux list-sessions -F "${grouped_sessions_tmux_format}" | sort)"

	while tmr:read session_is_grouped session_group _session_id session_name; do
		[[ "${session_is_grouped}" == 1 ]] || continue
		if [[ "$session_group" != "$current_session_group" ]]; then
			# this session is the original/first session in the group
			original_session="$session_name"
			current_session_group="$session_group"
		else
			# this session "points" to the original session
			local window_flag_indices window_flag window_index
			window_flag_indices="$(tmux list-windows -t "$session_name" -F "${window_flag_index_tmux_format}")"

			local alternate_window_index='' active_window_index=''
			while tmr:read window_flag window_index; do
				if [[ "$window_flag" == '*' ]]; then
					active_window_index="$window_index"
				elif [[ "$window_flag" == '-' ]]; then
					alternate_window_index="$window_index"
				fi
			done <<< "${window_flag_indices}"

			local colon_active_window_index=":${active_window_index}"
			local colon_alternate_window_index=":${alternate_window_index}"

			local fields=(
				'grouped_session'
				"${session_name}"
				"${original_session}"
				"${colon_alternate_window_index}"
				"${colon_active_window_index}"
			)
			tmr:fields "${fields[@]}"
		fi
	done <<< "${grouped_sessions}"
}

get_grouped_sessions() {
	# Reads grouped_session records and outputs tab-separated list of sessions.
	local _line_type session_name _original_session _colon_alternate_window_index _colon_active_window_index
	local grouped_session_names=()
	while tmr:read _line_type session_name _original_session _colon_alternate_window_index _colon_active_window_index; do
		grouped_session_names+=("${session_name}")
	done
	local IFS="${TMR_FIELD_SEP}"
	outln "${grouped_session_names[*]}"
}

is_session_grouped() {
	local session_name="$1"
	local grouped_session_names=("${@:2}")
	local IFS="${TMR_FIELD_SEP}"
	[[ "${grouped_session_names[*]}" =~ (^|[$IFS])"${session_name}"([$IFS]|$) ]]
}

# translates pane pid to process command running inside a pane
dump_panes() {
	local grouped_session_names=("$@")
	local raw_panes
	raw_panes="$(dump_panes_raw)"

	local line_type session_name window_index window_active colon_window_flags pane_index pane_title colon_pane_current_path pane_active pane_current_command pane_pid _history_size
	while tmr:read line_type session_name window_index window_active colon_window_flags pane_index pane_title colon_pane_current_path pane_active pane_current_command pane_pid _history_size; do
		# not saving panes from grouped sessions
		if is_session_grouped "$session_name" "${grouped_session_names[@]}"; then
			continue
		fi
		local colon_pane_full_command
		colon_pane_full_command=":$(pane_full_command "$pane_pid")"

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
	done <<< "${raw_panes}"
}

dump_windows() {
	local grouped_session_names=("$@")
	local raw_windows
	raw_windows="$(dump_windows_raw)"

	local line_type session_name window_index colon_window_name window_active colon_window_flags window_layout

	while tmr:read line_type session_name window_index colon_window_name window_active colon_window_flags window_layout; do
		# not saving windows from grouped sessions
		if is_session_grouped "$session_name" "${grouped_session_names[@]}"; then
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
	done <<< "${raw_windows}"
}

dump_state() {
	tmux display-message -p "${state_tmux_format}"
}

dump_pane_contents() {
	local pane_contents_area
	pane_contents_area="$(get_tmux_option "$pane_contents_area_option" "$default_pane_contents_area")"

	local raw_panes
	raw_panes="$(dump_panes_raw)"

	local _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title _colon_pane_current_path _pane_active _pane_current_command _pane_pid history_size
	while tmr:read _line_type session_name window_index _window_active _colon_window_flags pane_index _pane_title _colon_pane_current_path _pane_active _pane_current_command _pane_pid history_size; do
		local pane_id
		pane_id="$(custom_pane_id "${session_name}" "${window_index}" "${pane_index}")"
		capture_pane_contents "$pane_id" "$history_size" "$pane_contents_area"
	done <<< "${raw_panes}"
}

dump_layout() {
	local grouped_sessions_dump grouped_session_names=()
	grouped_sessions_dump="$(dump_grouped_sessions)"
	if [[ -n "$grouped_sessions_dump" ]]; then
		outln "$grouped_sessions_dump"

		local grouped_session_names_tsv
		grouped_session_names_tsv="$(get_grouped_sessions <<< "$grouped_sessions_dump")"

		IFS="${TMR_FIELD_SEP}" read -r -a grouped_session_names <<< "$grouped_session_names_tsv"
	fi

	dump_panes "${grouped_session_names[@]}"
	dump_windows "${grouped_session_names[@]}"
	dump_state
}

remove_old_backups() {
	# remove resurrect files older than 30 days (default), but keep at least 5 copies of backup.
	local delete_after
	delete_after="$(get_tmux_option "$delete_backup_after_option" "$default_delete_backup_after")"
	local resurrect_dir
	resurrect_dir="$(resurrect_dir)"
	local -a files
	files=($(ls -t "${resurrect_dir}/${RESURRECT_FILE_PREFIX}_"*".${RESURRECT_FILE_EXTENSION}" | tail -n +6))
	[[ ${#files[@]} -eq 0 ]] ||
		find "${files[@]}" -type f -mtime "+${delete_after}" -exec rm -v '{}' ';' > /dev/null
}

save_all() {
	local resurrect_file_path
	resurrect_file_path="$(new_resurrect_file_path)"

	local last_resurrect_file
	last_resurrect_file="$(last_resurrect_file)"

	local resurrect_dir
	resurrect_dir="$(resurrect_dir)"
	mkdir -p "${resurrect_dir}"

	dump_layout > "$resurrect_file_path"
	execute_hook 'post-save-layout' "$resurrect_file_path"
	if files_differ "$resurrect_file_path" "$last_resurrect_file"; then
		ln -fs "$(basename "$resurrect_file_path")" "$last_resurrect_file"
	else
		rm "$resurrect_file_path"
	fi
	if capture_pane_contents_option_on; then
		local content_save_dir
		content_save_dir="$(pane_contents_dir 'save')"

		mkdir -p "${content_save_dir}"
		dump_pane_contents
		pane_contents_create_archive
		rm "${content_save_dir}"/*
	fi
	remove_old_backups
	execute_hook 'post-save-all'
}

_min_supported_tmux_=1.9

# if first argument is "quiet", script produces no output.
tmr:save() {
	tmr:check-tmux-version "${_min_supported_tmux_}" || return $?

	if [[ "${1:-}" != 'quiet' ]]; then
		local spinner_pid
		tmr:spinner 'Saving...' 'Tmux environment saved!'&
		spinner_pid=$!

		save_all

		kill $spinner_pid
		display_message 'Tmux environment saved!'
	else
		save_all
	fi
}

[[ "${#BASH_SOURCE[@]}" -ne 1 || "${BASH_SOURCE[0]}" != "${0}" ]] || tmr:save "$@"
