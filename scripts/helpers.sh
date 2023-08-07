# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "${CURRENT_DIR}/variables.sh"

SUPPORTED_VERSION=1.9
RESURRECT_FILE_PREFIX=tmux_resurrect
RESURRECT_FILE_EXTENSION=txt

d=$'\t'

# Convert the string argument to an integer. All non-digit characters are
# removed, and the remaining digits are printed without leading zeros.
coerce-int() {
	# The '10#' prefix here ensures the value is interpreted as a decimal number.
	# This prevents leading zeros from causing an octal interpretaion.
	local int
	int="10#${1//[^[:digit:]]/}"
	echo $(( int ))
}

# 'echo' has some dangerous edge cases due to how it parses flags.
# For example, `echo "$foo"` will output nothing if `foo='-e'`.
# This makes it brittle to use in the context of arbitrary expansions.
# These helpers print their arguments literally, making them composable.

# Output zero or more literal strings.
# If more than one argument is provided, they are joined on IFS.
out() { printf '%s' "$*"; }

# Output zero or more literal strings terminated by newlines.
outln() { printf '%s\n' "$@"; }

tmr:fields() {
	local IFS="$d"
	outln "$*"
}

tmr:tmux-fields() {
	# Render a sequence of tmux fields joind on tab.
	tmr:fields "$@"
}

# Parse a single tab-delimited, escaped record into fields named by the given args.
tmr:read() {
	# The var names given in our arguments are set to those raw field values.
	IFS="$d" read "$@"
}

# Cached value of the integer digits of $(tmux -V).
tmr:tmux-version() {
	if [[ -z "${TMUX_VERSION_INT+x}" ]]; then
		local tmux_version_string
		tmux_version_string="$(tmux -V)"

		TMUX_VERSION_INT="$(coerce-int "$tmux_version_string")"
	fi
	echo "${TMUX_VERSION_INT}"
}

tmr:has-tmux-version() {
	local version="$1"
	local supported_version_int
	supported_version_int="$(coerce-int "$version")"

	local tmux_version_int
	tmux_version_int="$(tmr:tmux-version)"

	(( supported_version_int <= tmux_version_int ))
}

# helper functions
get_tmux_option() {
	local option="$1"
	local option_value status=0
	option_value=$(tmux show-option -gv "$option" 2>/dev/null) || status=$?
	if [[ $status -eq 0 ]]; then
		out "$option_value"
	elif [[ $status -eq 1 && $# -eq 2 ]]; then
		local default_value="$2"
		out "$default_value"
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
	out "${1:1}"
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
	local archive_file
	archive_file="$(pane_contents_archive_file)"

	local save_dir
	save_dir="$(resurrect_dir)/save"

	tar cfz - -C "${save_dir}/" ./pane_contents/ > "${archive_file}"
}

pane_content_files_restore_from_archive() {
	local archive_file
	archive_file="$(pane_contents_archive_file)"

	[[ -f "$archive_file" ]] || return 0

	local pane_dir
	pane_dir="$(pane_contents_dir 'restore')"

	local restore_dir
	restore_dir="$(resurrect_dir)/restore"

	mkdir -p "${pane_dir}"
	tar xfz - -C "${restore_dir}/" < "${archive_file}"
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
	out "${path}"
}

resurrect_dir() {
	[[ -n "${_RESURRECT_DIR+x}" ]] || _RESURRECT_DIR="$(get_resurrect_dir_opt)"
	out "${_RESURRECT_DIR}"
}

new_resurrect_file_path() {
	local timestamp
	timestamp="$(date '+%Y%m%dT%H%M%S')"

	resurrect_dir
	out "/${RESURRECT_FILE_PREFIX}_${timestamp}.${RESURRECT_FILE_EXTENSION}"
}

last_resurrect_file() {
	resurrect_dir
	out '/last'
}

pane_contents_dir() {
	local save_or_restore="$1"

	resurrect_dir
	out "/${save_or_restore}"
	out '/pane_contents'
}

pane_contents_file() {
	local save_or_restore="$1"
	local pane_id="$2"

	pane_contents_dir "$save_or_restore"
	out "/pane-${pane_id}"
}

pane_contents_file_exists() {
	local pane_id="$1"
	local file
	file="$(pane_contents_file 'restore' "$pane_id")"
	[[ -f "$file" ]]
}

pane_contents_archive_file() {
	resurrect_dir
	out '/pane_contents.tar.gz'
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
