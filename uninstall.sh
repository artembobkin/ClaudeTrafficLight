#!/bin/bash
# Removes Claude Traffic Light: the LaunchAgent, the app, the hooks from
# ~/.claude/settings.json, the status line wrapper (the previous status line
# command is put back) and the ~/.claude/traffic-light folder.
set -uo pipefail
label="com.artembobkin.claude-traffic-light"
settings="$HOME/.claude/settings.json"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist"
pkill -x ClaudeTrafficLight 2>/dev/null
rm -rf "$HOME/Applications/Claude Traffic Light.app"

if [ -f "$settings" ]; then
  jq '
    .hooks |= with_entries(
      .value |= map(.hooks |= map(select((.command // "") | contains("traffic-light/hook.sh") | not))
                    | select(.hooks | length > 0))
      | select(.value | length > 0))
    | if .hooks == {} then del(.hooks) else . end' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
  echo "hooks removed from $settings"

  if jq -e '(.statusLine.command // "") | contains("traffic-light/statusline.sh")' "$settings" >/dev/null; then
    original=$(cat "$HOME/.claude/traffic-light/statusline-command" 2>/dev/null)
    jq --arg c "$original" '
      if $c == "" then del(.statusLine) else .statusLine.command = $c end' "$settings" > "$settings.new" \
      && mv "$settings.new" "$settings"
    echo "status line restored in $settings"
  fi
fi
rm -rf "$HOME/.claude/traffic-light"
echo "done"
