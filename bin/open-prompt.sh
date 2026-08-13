#!/bin/sh
# Action entrypoint. Runs headless when the keybinding fires: resolves the repo
# the popup should work against, then opens the popup pane.
set -u

herdr="${HERDR_BIN_PATH:-herdr}"

fail() {
	"$herdr" notification show "New worktree from trail" --body "$1" >/dev/null 2>&1
	echo "$1" >&2
	exit 1
}

context="${HERDR_PLUGIN_CONTEXT_JSON:-}"
[ -n "$context" ] || fail "no invocation context"

command -v jq >/dev/null 2>&1 || fail "jq is required (brew install jq)"

# worktree.repo_root is the main checkout even when the action fires from a
# linked worktree workspace; Herdr refuses worktree actions rooted in one.
repo_root=$(printf '%s' "$context" | jq -r '.worktree.repo_root // empty')
if [ -z "$repo_root" ]; then
	cwd=$(printf '%s' "$context" | jq -r '.workspace_cwd // .focused_pane_cwd // empty')
	[ -n "$cwd" ] || fail "no workspace directory in context"
	repo_root=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
		fail "not a git repository: $cwd"
	repo_root=${repo_root%/.git}
fi

[ -d "$repo_root" ] || fail "repo root not found: $repo_root"

# selected_text lets you highlight a trail URL and hit the key: the popup
# pre-fills it instead of asking. Only a selection that looks like a trail
# reference is used — arbitrary highlighted text must not become the default.
selection=$(printf '%s' "$context" | jq -r '.selected_text // .clicked_url // empty' |
	head -n 1 | tr -d '[:space:]')
case "$selection" in
*/trails/[0-9]*) ;;
'' | *[!0-9]*) selection='' ;;
esac

exec "$herdr" plugin pane open \
	--plugin entire.trail-worktree \
	--entrypoint prompt \
	--placement popup \
	--env "ETW_REPO_ROOT=$repo_root" \
	--env "ETW_PREFILL=$selection"
