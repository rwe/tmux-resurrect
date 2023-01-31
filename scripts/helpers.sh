# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "${CURRENT_DIR}/variables.sh"

SUPPORTED_VERSION=1.9
RESURRECT_FILE_PREFIX=tmux_resurrect
RESURRECT_FILE_EXTENSION=txt

d=$'\t'

# helper functions
get_tmux_option() {
	local option="$1"
	local option_value status=0
	option_value=$(tmux show-option -gv "$option" 2>/dev/null) || status=$?
	if [[ $status -eq 0 ]]; then
		echo "$option_value"
	elif [[ $status -eq 1 && $# -eq 2 ]]; then
		local default_value="$2"
		echo "$default_value"
	else
		# Some other failure.
		return $status
	fi
}

# Ensures a message is displayed for 5 seconds in tmux prompt.
# Does not override the 'display-time' tmux option.
display_message() {
	local message="$1"

	# display_duration defaults to 5 seconds, if not passed as an argument
	local display_duration
	display_duration="${2:-5000}"

	# saves user-set 'display-time' option, if one was set
	local saved_display_time
	if ! saved_display_time="$(get_tmux_option 'display-time')"; then
		unset saved_display_time
	fi

	# sets message display time to 5 seconds
	tmux set-option -gq display-time "$display_duration"

	# displays message
	tmux display-message "$message"

	# restores original 'display-time' value, if one existed.
	if [[ -n "${saved_display_time+x}" ]]; then
		tmux set-option -gq display-time "$saved_display_time"
	fi
}


supported_tmux_version_ok() {
	"$CURRENT_DIR/check_tmux_version.sh" "$SUPPORTED_VERSION"
}

remove_first_char() {
	echo "${1:1}"
}

capture_pane_contents_option_on() {
	local option
	option="$(get_tmux_option "$pane_contents_option" off)"
	[[ "$option" == on ]]
}

files_differ() {
	! cmp -s "$1" "$2"
}

get_grouped_sessions() {
	local grouped_sessions_dump="$1"
	GROUPED_SESSIONS="${d}$(echo "$grouped_sessions_dump" | cut -f2 -d"$d" | tr "\\n" "$d")"
	export GROUPED_SESSIONS
}

is_session_grouped() {
	local session_name="$1"
	[[ "$GROUPED_SESSIONS" == *"${d}${session_name}${d}"* ]]
}

# pane content file helpers

pane_contents_create_archive() {
	tar cf - -C "$(resurrect_dir)/save/" ./pane_contents/ |
		gzip > "$(pane_contents_archive_file)"
}

pane_content_files_restore_from_archive() {
	local archive_file
	archive_file="$(pane_contents_archive_file)"
	if [[ -f "$archive_file" ]]; then
		mkdir -p "$(pane_contents_dir 'restore')"
		gzip -d < "$archive_file" |
			tar xf - -C "$(resurrect_dir)/restore/"
	fi
}

# path helpers

get_resurrect_dir_opt() {
	local path
	path="$(get_tmux_option "$resurrect_dir_option" '')"
	if [[ -n "${path}" ]]; then
		# expands tilde, $HOME and $HOSTNAME if used in @resurrect-dir
		path="${path//\~/$HOME}"
		path="${path//\$HOME/$HOME}"
		path="${path//\$HOSTNAME/$(hostname)}"
	elif [[ -d "$HOME/.tmux/resurrect" ]]; then
		path="$HOME/.tmux/resurrect"
	else
		path="${XDG_DATA_HOME:-"${HOME}/.local/share"}"/tmux/resurrect
	fi
	echo "${path}"
}

resurrect_dir() {
	[[ -n "${_RESURRECT_DIR+x}" ]] || _RESURRECT_DIR="$(get_resurrect_dir_opt)"
	echo "${_RESURRECT_DIR}"
}

new_resurrect_file_path() {
	local timestamp
	timestamp="$(date '+%Y%m%dT%H%M%S')"
	echo "$(resurrect_dir)/${RESURRECT_FILE_PREFIX}_${timestamp}.${RESURRECT_FILE_EXTENSION}"
}

last_resurrect_file() {
	echo "$(resurrect_dir)/last"
}

pane_contents_dir() {
	local save_or_restore="$1"
	echo "$(resurrect_dir)/${save_or_restore}/pane_contents"
}

pane_contents_file() {
	local save_or_restore="$1"
	local pane_id="$2"
	echo "$(pane_contents_dir "$save_or_restore")/pane-${pane_id}"
}

pane_contents_file_exists() {
	local pane_id="$1"
	[[ -f "$(pane_contents_file 'restore' "$pane_id")" ]]
}

pane_contents_archive_file() {
	echo "$(resurrect_dir)/pane_contents.tar.gz"
}

execute_hook() {
	local kind="$1"
	shift

	local hook
	hook="$(get_tmux_option "$hook_prefix$kind" '')"
	[[ -n "$hook" ]] || return 0

	# If there are any args, pass them to the hook in a way that preserves/copes
	# with spaces and unusual characters.
	eval "$hook$(printf ' %q' "$@")"
}
