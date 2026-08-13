#!/bin/sh
# Popup entrypoint. Owns terminal input, so this is where the trail id/URL gets
# pasted. Resolves the trail to its branch, creates (or re-opens) the Herdr
# worktree workspace for that branch, and starts an agent in its root pane.
set -u

herdr="${HERDR_BIN_PATH:-herdr}"
entire="${ENTIRE_BIN_PATH:-entire}"
repo_root="${ETW_REPO_ROOT:-}"
prefill="${ETW_PREFILL:-}"
state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
err_log="$state_dir/current.log"     # output of the command being run right now
history_log="$state_dir/history.log" # rolling diagnostics across runs

# Config: $(herdr plugin config-dir entire.trail-worktree)/config.env
AGENT_KINDS="claude codex none"
AGENT_DEFAULT="claude"
INITIAL_PROMPT=""
AGENT_START_ATTEMPTS=15
config_file="${HERDR_PLUGIN_CONFIG_DIR:-}/config.env"
if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$config_file" ]; then
	# shellcheck disable=SC1090
	. "$config_file"
fi

if [ -t 1 ]; then
	bold=$(printf '\033[1m')
	dim=$(printf '\033[2m')
	red=$(printf '\033[31m')
	green=$(printf '\033[32m')
	reset=$(printf '\033[0m')
else
	bold=''
	dim=''
	red=''
	green=''
	reset=''
fi
step() { printf '  %s%s%s\n' "$dim" "$1" "$reset"; }
ok() { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }

# ---------------------------------------------------------------------------
# Input
#
# A Herdr popup forwards every key to this process and offers no close key of
# its own (src/app/input/mod.rs: a popup short-circuits all key handling), so
# the only ways out are this command exiting or a popup.close socket request.
# A line-buffered `read` therefore traps the popup until Enter or ctrl+c —
# pressing Escape just parks a byte in the line buffer.
#
# So input is read a byte at a time in raw mode instead: Escape cancels on the
# keypress. A bare Escape is told apart from an arrow key (ESC [ A) by peeking
# for a follow-up byte with a 100ms timeout. Pastes stay intact because Herdr
# only wraps them in bracketed-paste markers when the app enabled DECSET 2004
# (src/pane.rs paste_payload), which a shell script never does.
# ---------------------------------------------------------------------------

tty_state=''

restore_tty() {
	[ -n "$tty_state" ] || return 0
	stty "$tty_state" 2>/dev/null
	tty_state=''
}

trap 'restore_tty' EXIT
trap 'restore_tty; exit 130' INT TERM

raw_on() {
	[ -t 0 ] || return 1
	tty_state=$(stty -g 2>/dev/null) || return 1
	stty -icanon -echo min 1 time 0 2>/dev/null || return 1
}

# Numeric value of one byte from stdin; empty on timeout. "peek" waits 100ms,
# anything else blocks.
read_byte() {
	[ "${1:-block}" != peek ] || stty min 0 time 1 2>/dev/null
	value=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -dc '0-9')
	[ "${1:-block}" != peek ] || stty min 1 time 0 2>/dev/null
	printf '%s' "$value"
}

# Consumes the tail of a CSI/SS3 sequence after ESC and its introducer.
swallow_sequence() {
	case "$1" in
	91 | 79) ;;
	*) return 0 ;;
	esac
	while :; do
		tail_byte=$(read_byte peek)
		[ -n "$tail_byte" ] || return 0
		if [ "$tail_byte" -ge 64 ] && [ "$tail_byte" -le 126 ]; then
			return 0
		fi
	done
}

byte_to_char() { printf "\\$(printf '%03o' "$1")"; }

# Reads a line into REPLY_LINE. Returns 1 when cancelled (Escape, ctrl+c,
# ctrl+d). Falls back to a plain read when stdin is not a terminal.
read_line() {
	REPLY_LINE=''
	if ! raw_on; then
		IFS= read -r REPLY_LINE || return 1
		return 0
	fi
	while :; do
		byte=$(read_byte)
		[ -n "$byte" ] || continue
		case "$byte" in
		27)
			next=$(read_byte peek)
			if [ -z "$next" ]; then
				restore_tty
				return 1
			fi
			swallow_sequence "$next"
			;;
		3 | 4)
			restore_tty
			return 1
			;;
		10 | 13) break ;;
		8 | 127)
			if [ -n "$REPLY_LINE" ]; then
				REPLY_LINE=${REPLY_LINE%?}
				printf '\b \b'
			fi
			;;
		21)
			while [ -n "$REPLY_LINE" ]; do
				REPLY_LINE=${REPLY_LINE%?}
				printf '\b \b'
			done
			;;
		*)
			if [ "$byte" -ge 32 ]; then
				char=$(byte_to_char "$byte")
				REPLY_LINE="$REPLY_LINE$char"
				printf '%s' "$char"
			fi
			;;
		esac
	done
	restore_tty
	printf '\n'
}

# Reads a single keypress into REPLY_KEY (empty for Enter). Returns 1 when
# cancelled.
read_key() {
	REPLY_KEY=''
	if ! raw_on; then
		IFS= read -r REPLY_KEY || return 1
		return 0
	fi
	while :; do
		byte=$(read_byte)
		[ -n "$byte" ] || continue
		case "$byte" in
		27)
			next=$(read_byte peek)
			if [ -z "$next" ]; then
				restore_tty
				return 1
			fi
			swallow_sequence "$next"
			;;
		3 | 4)
			restore_tty
			return 1
			;;
		10 | 13)
			restore_tty
			printf '\n'
			return 0
			;;
		*)
			if [ "$byte" -ge 32 ]; then
				REPLY_KEY=$(byte_to_char "$byte")
				restore_tty
				printf '%s\n' "$REPLY_KEY"
				return 0
			fi
			;;
		esac
	done
}

die() {
	restore_tty
	record "$1"
	printf '\n  %serror%s %s\n' "$red" "$reset" "$1"
	if [ -s "$err_log" ]; then
		sed -n '1,6p' "$err_log" | sed "s/^/  $dim/;s/\$/$reset/"
	fi
	printf '\n  %spress any key to close%s ' "$dim" "$reset"
	read_key || true
	exit 1
}

# Herdr CLI calls print a JSON envelope; a failed call carries .error.
check_response() {
	message=$(printf '%s' "$1" | jq -r '.error.message // .error.code // empty' 2>/dev/null)
	[ -z "$message" ] || die "$2: $message"
}

# Appends the current command's output to a rolling log. Agent-start failures
# are intermittent, so overwriting one log per run would destroy the only
# evidence the next time it happens.
record() {
	{
		printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" "$1"
		[ -s "$err_log" ] && sed 's/^/    /' "$err_log"
	} >>"$history_log" 2>/dev/null || true
	if [ -f "$history_log" ] && tail -n 400 "$history_log" >"$history_log.tmp" 2>/dev/null; then
		mv "$history_log.tmp" "$history_log" 2>/dev/null || true
	fi
}

: >"$err_log" 2>/dev/null || {
	err_log=/dev/null
	history_log=/dev/null
}

[ -n "$repo_root" ] || die "no repo root supplied"
cd "$repo_root" 2>/dev/null || die "cannot enter $repo_root"
command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"
command -v "$entire" >/dev/null 2>&1 || die "'entire' not found on PATH"

origin=$(git remote get-url origin 2>/dev/null) ||
	die "no origin remote in $repo_root"
origin_slug=$(printf '%s' "$origin" | sed -e 's#\.git$##' -e 's#^.*[:/]\([^/]*/[^/]*\)$#\1#')

printf '\n  %snew worktree from trail%s  %s%s%s\n\n' \
	"$bold" "$reset" "$dim" "$origin_slug" "$reset"

printf '  %sesc to cancel%s\n\n' "$dim" "$reset"
if [ -n "$prefill" ]; then
	printf '  trail %s[%s]%s: ' "$dim" "$prefill" "$reset"
else
	printf '  trail %s(number, id, branch, or URL)%s: ' "$dim" "$reset"
fi
read_line || exit 0
input=$REPLY_LINE
[ -n "$input" ] || input="$prefill"
[ -n "$input" ] || exit 0

# A pasted URL (https://entire.io/gh/owner/repo/trails/992/slug) carries both the
# trail number and the repo it belongs to. The repo has to match this checkout:
# resolving a foreign trail here would silently check out the wrong branch.
selector=$input
case "$input" in
*/trails/*)
	path=${input#*://}
	path=${path#*/}
	before=${path%%/trails/*}
	after=${path#*/trails/}
	number=${after%%/*}
	number=${number%%\?*}
	number=${number%%#*}
	url_owner=${before%/*}
	url_owner=${url_owner##*/}
	url_repo=${before##*/}
	url_slug="$url_owner/$url_repo"

	case "$number" in
	'' | *[!0-9]*) die "could not read a trail number from $input" ;;
	esac
	lower_url=$(printf '%s' "$url_slug" | tr '[:upper:]' '[:lower:]')
	lower_origin=$(printf '%s' "$origin_slug" | tr '[:upper:]' '[:lower:]')
	if [ "$lower_url" != "$lower_origin" ]; then
		die "that trail belongs to $url_slug, but this workspace is $origin_slug"
	fi
	selector=$number
	;;
esac

step "resolving trail ${selector}…"
trail_json=$("$entire" trail resume "$selector" --no-resume --json 2>"$err_log") ||
	die "could not resolve trail $selector"

branch=$(printf '%s' "$trail_json" | jq -r '.trail.branch // empty')
title=$(printf '%s' "$trail_json" | jq -r '.trail.title // empty')
number=$(printf '%s' "$trail_json" | jq -r '.trail.number // empty')
[ -n "$branch" ] || die "trail $selector has no branch"

short_title=$(printf '%s' "$title" | cut -c1-46)
printf '  %strail #%s%s  %s\n' "$bold" "$number" "$reset" "$short_title"
printf '  %sbranch%s %s\n\n' "$dim" "$reset" "$branch"

# Agent picker. "none" leaves a plain shell in the new workspace.
index=1
choices=''
printf '  agent '
for kind in $AGENT_KINDS; do
	printf '%s[%s] %s%s ' "$dim" "$index" "$reset" "$kind"
	choices="$choices $index:$kind"
	index=$((index + 1))
done
printf '\n  choice %s[enter = %s]%s: ' "$dim" "$AGENT_DEFAULT" "$reset"
read_key || exit 0
choice=$REPLY_KEY

agent_kind=$AGENT_DEFAULT
if [ -n "$choice" ]; then
	agent_kind=''
	for pair in $choices; do
		case "$pair" in "$choice":*) agent_kind=${pair#*:} ;; esac
	done
	[ -n "$agent_kind" ] || die "no such choice: $choice"
fi
printf '\n'

# Sidebar labels are narrow; keep the trail number and a readable title stub.
short_label=$(printf '%s' "$title" | cut -c1-22)
[ "$short_label" = "$title" ] || short_label="${short_label}…"
label="#$number $short_label"

# Re-opening beats failing: if the branch already has a worktree (from a previous
# run, or from `entire trail checkout --worktree`), adopt it instead.
existing=$("$herdr" worktree list --cwd "$repo_root" 2>"$err_log" |
	jq -r --arg b "$branch" '.result.worktrees[]? | select(.branch == $b) | .path' | head -n 1)

if [ -n "$existing" ]; then
	step "opening existing worktree $existing"
	response=$("$herdr" worktree open --cwd "$repo_root" --branch "$branch" \
		--label "$label" --focus 2>"$err_log") || die "worktree open failed"
	check_response "$response" "worktree open failed"
else
	# Herdr's worktree create only consults local refs — for a trail branch that
	# only exists on origin it would silently create a new branch from HEAD.
	if ! git show-ref --verify --quiet "refs/heads/$branch"; then
		step "fetching $branch from origin…"
		git fetch origin "refs/heads/$branch:refs/heads/$branch" >"$err_log" 2>&1 ||
			die "branch $branch not found locally or on origin"
	fi
	step "creating worktree for ${branch}…"
	response=$("$herdr" worktree create --cwd "$repo_root" --branch "$branch" \
		--label "$label" --focus 2>"$err_log") || die "worktree create failed"
	check_response "$response" "worktree create failed"
fi

checkout=$(printf '%s' "$response" | jq -r '.result.worktree.path // empty')
pane=$(printf '%s' "$response" | jq -r '.result.root_pane.pane_id // empty')
ok "${checkout:-worktree ready}"

if [ "$agent_kind" = "none" ] || [ -z "$pane" ]; then
	printf '\n'
	exit 0
fi

# An adopted workspace may already be running an agent in its root pane.
occupied=$("$herdr" agent list 2>/dev/null |
	jq -r --arg p "$pane" '[.result.agents[]? | select(.pane_id == $p)] | length')
if [ "${occupied:-0}" != "0" ]; then
	ok "$pane already has an agent"
	printf '\n'
	exit 0
fi

# Agent names must be unique among live agents and match [a-z][a-z0-9_-]{0,31}.
name="trail-$number"
suffix=2
while [ "$suffix" -lt 20 ] &&
	"$herdr" agent list 2>/dev/null |
	jq -e --arg n "$name" '.result.agents[]? | select(.name == $n)' >/dev/null 2>&1; do
	name="trail-$number-$suffix"
	suffix=$((suffix + 1))
done

# `agent start` requires the pane's shell to be the sole process in its
# foreground job (platform/mod.rs available_pane_shell_from_job). A worktree
# workspace is seconds old at this point, so its shell is often still running
# rc files — mise, direnv, completions — and herdr rejects the pane outright
# with agent_pane_busy in about a millisecond. That is a race, not a timeout,
# so retry it rather than reporting failure on the first miss.
start_agent() {
	attempt=1
	while :; do
		: >"$err_log" 2>/dev/null || true
		if "$herdr" agent start "$name" --kind "$agent_kind" --pane "$pane" >>"$err_log" 2>&1; then
			[ "$attempt" -eq 1 ] || record "agent start succeeded on attempt $attempt"
			return 0
		fi
		start_error=$(jq -r '.error.code // empty' <"$err_log" 2>/dev/null | tail -n 1)
		record "agent start attempt $attempt failed (${start_error:-unknown})"
		case "$start_error" in
		agent_pane_busy | agent_pane_unavailable) ;;
		*) return 1 ;;
		esac
		[ "$attempt" -lt "$AGENT_START_ATTEMPTS" ] || return 1
		printf '.'
		sleep 1
		attempt=$((attempt + 1))
	done
}

printf '  %sstarting %s…%s' "$dim" "$agent_kind" "$reset"
if start_agent; then
	printf '\n'
	ok "$agent_kind running as $name in $pane"
	if [ -n "$INITIAL_PROMPT" ]; then
		text=$(printf '%s' "$INITIAL_PROMPT" |
			sed -e "s|{number}|$number|g" -e "s|{branch}|$branch|g" -e "s|{title}|$title|g")
		"$herdr" agent prompt "$name" "$text" >/dev/null 2>&1 ||
			printf '  %scould not send the initial prompt%s\n' "$dim" "$reset"
	fi
	printf '\n'
	exit 0
fi

# The worktree exists either way — an agent that would not start is worth
# reporting, but not worth discarding the workspace over.
printf '\n\n  %swarning%s %s did not start in %s (%s)\n' \
	"$red" "$reset" "$agent_kind" "$pane" "${start_error:-unknown}"
sed -n '1,4p' "$err_log" 2>/dev/null | sed "s/^/  $dim/;s/\$/$reset/"
printf '  %sstart it yourself with: herdr agent start %s --kind %s --pane %s%s\n' \
	"$dim" "$name" "$agent_kind" "$pane" "$reset"
printf '  %sdetails: %s%s\n' "$dim" "$history_log" "$reset"
printf '\n  %spress any key to close%s ' "$dim" "$reset"
read_key || true
