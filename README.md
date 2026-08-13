# Entire Trail Worktree

A Herdr plugin: paste an Entire trail id or URL, get a worktree workspace on
that trail's branch with an agent already running in it.

It's the `new worktree` flow (`prefix+shift+g`), except you name a trail instead
of a branch.

```
  new worktree from trail  entireio/cli

  trail (number, id, branch, or URL): https://entire.io/gh/entireio/cli/trails/1000
  trail #1000  Detect hook-config drift for every agent
  branch soph/pi-reenable

  agent [1] claude [2] codex [3] none
  choice [enter = claude]:

  creating worktree for soph/pi-reenable…
  ✓ /Users/soph/.herdr/worktrees/cli/soph-pi-reenable
  starting claude…
  ✓ claude running as trail-1000 in wF:p1
```

## Install

Prerequisites: Herdr 0.8.0+, and `entire` (logged in), `git`, and `jq` on
`PATH`. `jq` is not preinstalled on macOS before 15 — `brew install jq`.

```bash
herdr plugin install entireio/herdr-plugin-trail-worktree
```

Pin a revision with `--ref v0.1.0` when you want a known version: install
re-fetches on every run and there is no `plugin update`, so reinstalling is
what picks up new code.

While the repo is private, each person needs git to be able to clone it over
**HTTPS** — `plugin install` builds `https://github.com/<owner>/<repo>.git` and
cannot be pointed at SSH. If your remotes are all `git@github.com:`, you have no
HTTPS credential and install fails with `could not read Username for
'https://github.com'`. Fix it once with either:

```bash
gh auth setup-git                                                    # simplest
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

The second reuses your existing SSH keys but redirects *every* HTTPS github.com
clone, which can surprise you later.

Installing does not bind a key — Herdr plugins cannot add keybindings. Add one
to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+e"
type = "plugin_action"
command = "entire.trail-worktree.new"
description = "new worktree from trail"
```

Then `herdr server reload-config`. Without a keybinding the flow still works
through `herdr plugin action invoke entire.trail-worktree.new`.

To hack on it locally instead, `herdr plugin link /path/to/checkout` — linking
skips build commands and runs straight from your working tree.

## What it does

1. Resolves the trail with `entire trail resume <selector> --no-resume --json`,
   which accepts a number, trail id, or branch and returns the branch and title.
   A pasted URL is reduced to its trail number first, and its `owner/repo` is
   checked against the workspace's `origin` — resolving a foreign trail here
   would silently check out the wrong branch.
2. Fetches the branch if it only exists on `origin`. This step matters: Herdr's
   own `worktree create --branch` consults local refs only, so without it a
   remote-only trail branch would silently become a *new* branch off `HEAD`.
3. Creates the worktree workspace with `herdr worktree create`, so the checkout
   lands under `worktrees.directory` (`~/.herdr/worktrees/<repo>/<slug>`) and is
   grouped with the parent repo workspace like any other Herdr worktree. If the
   branch already has a worktree, it re-opens that one instead of failing.
4. Starts the chosen agent in the new workspace's root pane, named `trail-<n>`
   so `herdr agent read trail-1000` and friends work.

Remove one with `herdr worktree remove --workspace <id>`, the same as any Herdr
worktree. The branch is never deleted.

## Entry points

The keybinding is the main one. The action also reads the terminal selection: if
you highlight a trail URL or a bare trail number before pressing the key, the
popup offers it as the default and you just press Enter.

You can also call it from a script or an agent:

```bash
herdr plugin action invoke entire.trail-worktree.new
```

`Esc` cancels at any prompt, as does `ctrl+c`. The agent picker takes a single
keypress — no Enter.

Escape needs care in a Herdr popup. A popup forwards *every* key to its process
and has no close key of its own, so a script that reads with a line-buffered
`read` cannot be dismissed with Escape at all: the byte just sits in the line
buffer until you press Enter or `ctrl+c`. This plugin reads keys in raw mode
instead, telling a bare Escape apart from an arrow key by peeking for a
follow-up byte. Worth copying if you write another popup plugin.

If a popup from any plugin ever does get stuck, there is no CLI for it, but the
socket method exists:

```bash
printf '{"id":"x","method":"popup.close","params":{}}\n' | nc -U "$HERDR_SOCKET_PATH"
```

## Config

Optional, at `$(herdr plugin config-dir entire.trail-worktree)/config.env`:

```sh
# Agents offered in the picker, in order. "none" leaves a plain shell.
AGENT_KINDS="claude codex droid none"

# Pre-selected on Enter.
AGENT_DEFAULT="claude"

# Sent to the agent once it is ready. {number}, {branch} and {title} expand.
INITIAL_PROMPT="You are working on trail #{number} ({title}). Run 'entire trail show {number}' for context first."

# Seconds to keep retrying `agent start` while the new pane's shell is still
# running its rc files. See "agent did not start" below.
AGENT_START_ATTEMPTS=15
```

Any Herdr agent kind works: `pi`, `claude`, `codex`, `gemini`, `cursor`,
`opencode`, `copilot`, `droid`, `amp`, `grok`, and the rest of the list in
`herdr agent start --help`.

## Troubleshooting

Diagnostics land in `$(herdr plugin config-dir entire.trail-worktree)`'s state
sibling — `~/.local/state/herdr/plugins/<id>/history.log`, a rolling log capped
at 400 lines. `herdr plugin log list --plugin entire.trail-worktree` shows the
action invocations, but note that it only covers the action that opens the
popup; the popup's own work is in `history.log`.

**"agent did not start" / `agent_pane_busy`.** `agent start` requires the target
pane's shell to be the *sole* process in its foreground job
(`platform/mod.rs:223`, `available_pane_shell_from_job`). A worktree workspace is
a second or two old when the agent is started, so its shell is often still
running rc files — mise, direnv, completions, prompt setup — and herdr rejects
the pane in about a millisecond. Despite what the wording suggests, this is not
the 30s startup timeout; that is a separate CLI-side failure that reports
`timeout: timed out waiting for agent startup`.

The plugin retries once a second while the error stays `agent_pane_busy`,
`AGENT_START_ATTEMPTS` times. Raise it if your shell startup is slow. The
worktree is never discarded because of this — worst case you start the agent
yourself with the command the popup prints.

## Notes

- `entire trail checkout <n> --worktree` (Entire CLI, `main`) does a similar job
  outside Herdr, but places checkouts in `<repo>/.entire/worktrees` and does not
  open a workspace. This plugin deliberately uses Herdr's own worktree directory
  and lifecycle instead. Worktrees made either way are picked up by step 3, so
  the two coexist.
- The popup is the only way to accept pasted input: plugin actions take no
  arguments, and Herdr plugins have no native UI surface (no sidebar or menu
  entries).
