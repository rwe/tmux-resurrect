# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "${CURRENT_DIR}/variables.sh"

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

# Double backslashes, then use that to escape tabs (the field separator) and
# newlines (the record separator).
escape_field() {
	local f="$1"
	f="${f//"\\"/\\\\}" # double backslashes
	f="${f//$'\t'/\\t}" # represent tabs as "\t"
	f="${f//$'\n'/\\n}" # represent newlines as "\n"
	out "$f"
}

# Construct a new tmux format which escapes the value produced by the supplied tmux format.
# The escaping is performed by the tmux server.
#
# As an example, the following will produce the correctly-escaped values of
# `#{pane_current_path}` for each pane and window.
# > tmux display -p '#{W:#{P:#{'"$(escape_tmux_format_field '#{pane_current_path}')"'}'$'\n}}'
escape_tmux_format_field() {
	local f="$1"
	# Double backslashes as '\\'.
	printf -v f '#{s/%s/%s/:%s}' $'\\' "\\\\" "${f}"
	# Represent tabs as '\n'.
	printf -v f '#{s/%s/%s/:%s}' $'\t' '\\t' "${f}"
	# Represent newlines as '\n'.
	printf -v f '#{s/%s/%s/:%s}' $'\n' '\\n' "${f}"
	out "$f"
}

# Reverse the above escaping. This must be performed sequentially, to avoid
# misinterpreting adjacent sequences like "\\\t" and "\\t"
unescape_field() {
	local str="${1}" i is_escaping=0 result=''
	for (( i=0; i < "${#str}"; ++i )); do
		local char="${str:$i:1}"
		if [[ $is_escaping -eq 1 ]]; then
			is_escaping=0
			local token
			if [[ "$char" == 't' ]]; then
				token=$'\t'
			elif [[ "$char" == 'n' ]]; then
				token=$'\n'
			else
				token="$char"
			fi
			result+="$token"
		elif [[ "$char" == "\\" ]]; then
			is_escaping=1
		else
			result+="$char"
		fi
	done
	out "${result}"
}

tmr:fields() {
	# Render a sequence of fields, escaping each field and joining on tab.
	local f escaped_fields=()
	for f in "$@"; do
		escaped_fields+=("$(escape_field "$f")")
	done
	local IFS="$d"
	outln "${escaped_fields[*]}"
}

tmr:tmux-fields() {
	# Render a sequence of tmux fields, specifying a format for each field which
	# renders escaped and joined on tab.
	local f escaped_fields=()
	for f in "$@"; do
		escaped_fields+=("$(escape_tmux_format_field "$f")")
	done
	local IFS="$d"
	outln "${escaped_fields[*]}"
}

# Parse a single tab-delimited, escaped record into fields named by the given args.
tmr:read() {
	# Read fields raw, separating only on tabs, until newline.
	# The var names given in our arguments are set to those raw field values.
	IFS="$d" read -r "$@" || return $?
	while [[ $# -gt 0 ]]; do
		# Get the escaped value of the named var, un-escape it, and store it in
		# our temp variable. The temp is just to avoid masking error codes.
		# We're being careful about names here due to intentionally modifying names
		# from our outer scope. For example, don't call this "field" or "f" in case
		# this is invoked like `tmr:read a b c d e f`.
		local _tmr_read_f
		_tmr_read_f="$(unescape_field "${!1}")"
		# Update the var to it un-escaped value.
		printf -v "$1" '%s' "${_tmr_read_f}"
		# Move to the next var that needs un-escaping.
		shift
	done
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

	if ! tmr:has-tmux-version 3.2; then
		_tmr:tmux-le-31:display_message "${message}" "${display_duration}"
		return
	fi

	tmux display-message -d "${display_duration}" "${message}"
}

# Display a message for tmux <3.2 by temporarily setting and restoring 'display-time'.
_tmr:tmux-le-31:display_message() {
	local message="$1" display_duration="$2"

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

capture_pane_contents_option_on() {
	local option
	option="$(get_tmux_option "$pane_contents_option" off)"
	[[ "$option" == on ]]
}

files_differ() {
	! cmp -s "$1" "$2"
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

custom_pane_id() {
	local session_name="$1"
	local window_index="$2"
	local pane_index="$3"
	out "${session_name}:${window_index}.${pane_index}"
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
