#!/bin/bash
# Removes Claude Traffic Light: the LaunchAgent, the app, the hooks from
# ~/.claude/settings.json and the ~/.claude/traffic-light folder.
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
fi
rm -rf "$HOME/.claude/traffic-light"
echo "done"
