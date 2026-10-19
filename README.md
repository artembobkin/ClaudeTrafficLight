# Claude Traffic Light

A floating panel for macOS with one lamp per running [Claude Code](https://code.claude.com) session, so you can read or do something else and see at a glance when an agent is done or waits for you.

- red: the session is working
- yellow: the session waits for your input (a permission, a question, an elicitation)
- green: the session is done and waits for the next prompt

Each row shows the project folder (or the session title set with `/rename`) and the last message you sent to that session, cut to one line. Hover for the full message.

The panel stays above every window and on every Space, never takes the focus, can be dragged anywhere and remembers its position. A right click opens the menu with Quit.

## How it works

Only Claude Code [hooks](https://code.claude.com/docs/en/hooks) are used. `hook.sh` is called by the hooks and writes one small file per session into `~/.claude/traffic-light/sessions/`. The app watches that folder and draws it. A session whose `claude` process is gone is dropped, so a crash leaves no stale lamp.

| State | Hooks |
|---|---|
| working | `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` |
| needs you | `PermissionRequest`, `PreToolUse` on `AskUserQuestion`, `Notification` (`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`) |
| done | `Stop`, `StopFailure`, `SessionStart`, `Notification` (`idle_prompt`) |
| removed | `SessionEnd` |

Known gaps, both from how the hooks are defined: after you grant a permission in the dialog, no hook fires until that tool finishes, so the lamp stays yellow until then. `Stop` does not fire when you interrupt Claude with Esc, so the lamp stays red until the `idle_prompt` notification about a minute later.

The hook also records the pid of the `claude` process, found by walking up the process tree, and the app drops a session whose process is gone or is no longer claude. That is the one thing not taken from the hook payload, and it only removes rows: a session that crashed or whose terminal was closed sends no `SessionEnd`.

## Install

Requires macOS 15 or later on Apple silicon, Xcode command line tools (`swiftc`) and `jq`.

```sh
./install.sh
```

It copies `hook.sh` to `~/.claude/traffic-light/`, adds the hooks to `~/.claude/settings.json` (a backup is kept next to the script), builds `~/Applications/Claude Traffic Light.app` and installs a LaunchAgent that starts it at login. Running Claude Code sessions pick up the hooks after `/hooks` is opened once, new sessions right away.

After changing `Sources/main.swift`, `./build.sh` rebuilds and restarts the app.

```sh
./uninstall.sh
```

removes everything, the hooks included.

## License

MIT
