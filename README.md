# Claude Traffic Light

A floating panel for macOS with one lamp per running [Claude Code](https://code.claude.com) session, so you can read or do something else and see at a glance when an agent is done or waits for you.

- red: the session is working
- yellow: the session waits for your input (a permission, a question, an elicitation)
- green: the session is done and waits for the next prompt

Each row shows the project folder (or the session title set with `/rename`) and the last message you sent to that session, cut to one line. Hover for the full message.

Under the lamps are the usage limits of your Claude subscription: the 5-hour window and the weekly one, each with a bar, the percentage used and the time left until it resets. The bar turns yellow from 70% and red from 90%. Hover for the exact reset times.

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

The usage limits come from the [status line](https://code.claude.com/docs/en/statusline): Claude Code hands its command a JSON payload that carries `rate_limits` for Pro and Max subscribers. `statusline.sh` writes each limit into `~/.claude/traffic-light/limits/` and then runs the status line command you had before with the same payload, so your status line stays as it was. Nothing goes over the network. The numbers are as fresh as the last status line update of any running session, and a window whose reset time has passed is shown as empty. Without a subscription there are no limits and the section is hidden.

The hook also records the pid of the `claude` process, found by walking up the process tree, and the app drops a session whose process is gone or is no longer claude. That is the one thing not taken from the hook payload, and it only removes rows: a session that crashed or whose terminal was closed sends no `SessionEnd`.

## Install

Requires macOS 15 or later on Apple silicon, Xcode command line tools (`swiftc`) and `jq`.

```sh
./install.sh
```

It copies `hook.sh` and `statusline.sh` to `~/.claude/traffic-light/`, adds the hooks to `~/.claude/settings.json` and points its `statusLine` at `statusline.sh`, keeping your previous status line command in `~/.claude/traffic-light/statusline-command` (a backup of the settings is kept next to the scripts), builds `~/Applications/Claude Traffic Light.app` and installs a LaunchAgent that starts it at login. Running Claude Code sessions pick up the hooks after `/hooks` is opened once, new sessions right away.

After changing `Sources/main.swift`, `./build.sh` rebuilds and restarts the app.

```sh
./uninstall.sh
```

removes everything, the hooks included, and puts your previous status line command back.

## License

MIT
