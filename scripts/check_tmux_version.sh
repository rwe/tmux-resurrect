#!/usr/bin/env bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

source "${CURRENT_DIR}/helpers.sh"

tmr:check-tmux-version() {
	local version
	version="$1"

	local unsupported_msg
	unsupported_msg="${2:-"Error, Tmux version unsupported! Please install Tmux version $version or greater!"}"

	if ! tmr:has-tmux-version "${version}"; then
		display_message "$unsupported_msg"
		return 1
	fi
}

[[ "${#BASH_SOURCE[@]}" -ne 1 || "${BASH_SOURCE[0]}" != "${0}" ]] || tmr:check-tmux-version "$@"
