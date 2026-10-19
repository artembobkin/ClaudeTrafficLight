#!/bin/bash
# Installs Claude Traffic Light:
#   1. the hook script into ~/.claude/traffic-light/hook.sh
#   2. the hooks into ~/.claude/settings.json (a backup is kept next to the script)
#   3. the app into ~/Applications, built from Sources/
#   4. a LaunchAgent that starts the app at login and keeps it running
# Running it again updates the script and the app and leaves the hooks as they are.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.claude/traffic-light"
settings="$HOME/.claude/settings.json"
label="com.artembobkin.claude-traffic-light"
agent="$HOME/Library/LaunchAgents/$label.plist"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

mkdir -p "$target/sessions"
cp "$here/hook.sh" "$target/hook.sh"
chmod +x "$target/hook.sh"

if [ -f "$settings" ] && grep -q 'traffic-light/hook.sh' "$settings"; then
  echo "hooks already present in $settings, left unchanged"
else
  [ -f "$settings" ] || echo '{}' > "$settings"
  cp "$settings" "$target/settings.json.backup-$(date +%Y%m%d-%H%M%S)"
  jq --arg h 'bash "$HOME/.claude/traffic-light/hook.sh"' '
    def cmd($state): {type: "command", command: ($h + " " + $state), timeout: 5};
    def entry($state): {hooks: [cmd($state)]};
    def entry($matcher; $state): {matcher: $matcher, hooks: [cmd($state)]};
    .hooks = ((.hooks // {}) + {
      SessionStart:       ((.hooks.SessionStart // [])       + [entry("idle")]),
      UserPromptSubmit:   ((.hooks.UserPromptSubmit // [])   + [entry("working")]),
      PreToolUse:         ((.hooks.PreToolUse // [])         + [entry("AskUserQuestion"; "attention")]),
      PostToolUse:        ((.hooks.PostToolUse // [])        + [entry("working")]),
      PostToolUseFailure: ((.hooks.PostToolUseFailure // []) + [entry("working")]),
      PermissionRequest:  ((.hooks.PermissionRequest // [])  + [entry("attention")]),
      PermissionDenied:   ((.hooks.PermissionDenied // [])   + [entry("working")]),
      Notification:       ((.hooks.Notification // [])       + [
                             entry("permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"; "attention"),
                             entry("idle_prompt"; "idle")]),
      Stop:               ((.hooks.Stop // [])               + [entry("idle")]),
      SessionEnd:         ((.hooks.SessionEnd // [])         + [entry("gone")])
    })' "$settings" > "$settings.new"
  mv "$settings.new" "$settings"
  echo "hooks added to $settings"
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$here/$label.plist" > "$agent"

"$here/build.sh"

if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  pkill -x ClaudeTrafficLight 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$agent"
  echo "LaunchAgent $label started"
fi
echo "done. Open /hooks in a running Claude Code session, or start a new one, so it picks up the hooks."
