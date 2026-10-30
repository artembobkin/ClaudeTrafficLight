#!/bin/bash
# Claude Code status line command: records the subscription usage limits for
# Claude Traffic Light, then runs the status line command you had before.
#
# Claude Code hands the status line a JSON payload on stdin. For Claude.ai
# subscribers it carries rate_limits.five_hour and rate_limits.seven_day (and
# rate_limits.spend_limit behind a gateway), each with used_percentage and
# resets_at. Each one is written to ~/.claude/traffic-light/limits/<name> as
#   <used percent> <reset unix time>
# A limit missing from the payload keeps its file: the app treats a limit whose
# reset time has passed as back at zero.
#
# The previous status line command is kept in ~/.claude/traffic-light/statusline-command
# by install.sh. It gets the same payload, and its output is the status line.

input=$(cat)
dir="$HOME/.claude/traffic-light/limits"

limits=$(printf '%s' "$input" | jq -r '
  (.rate_limits // {}) | to_entries[]
  | select((.value.used_percentage | type) == "number" and (.value.resets_at | type) == "number")
  | "\(.key) \(.value.used_percentage) \(.value.resets_at | floor)"' 2>/dev/null)

if [ -n "$limits" ] && { [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; }; then
  while read -r name used resets; do
    case "$name" in ""|*[!a-z0-9_]*) continue;; esac
    line="$used $resets"
    # The status line runs often, a file is rewritten only when its numbers change.
    old=""
    [ -f "$dir/$name" ] && IFS= read -r old < "$dir/$name"
    [ "$old" = "$line" ] && continue
    tmp="$dir/$name.tmp.$$"
    echo "$line" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$name" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  done <<< "$limits"
fi

original="$HOME/.claude/traffic-light/statusline-command"
if [ -s "$original" ]; then
  printf '%s' "$input" | bash -c "$(cat "$original")"
fi
