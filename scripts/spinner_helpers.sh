# shellcheck shell=bash

: "${CURRENT_DIR:="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}" || :

start_spinner() {
	"$CURRENT_DIR/tmux_spinner.sh" "$1" "$2" &
	export SPINNER_PID=$!
}

stop_spinner() {
	kill "$SPINNER_PID"
}
