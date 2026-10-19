#!/bin/bash
# Claude Code hook: records the state of the calling session for Claude Traffic Light.
#
# Usage: hook.sh <state>      state is one of: working, attention, idle, gone
# Reads the hook's JSON payload on stdin and writes one file per session into
# ~/.claude/traffic-light/sessions/<session_id> with these lines:
#   state=<state>
#   pid=<pid of the claude process, so the app can drop sessions that died>
#   cwd=<working directory of the session>
#   title=<session title set with /rename, when the payload carries session_title>
#   prompt=<the last message you sent, one line, when the payload carries prompt>
#   updated=<unix time>
# The file is written to a temporary name and renamed, so the app's directory
# watcher sees one complete change.

state="$1"
dir="$HOME/.claude/traffic-light/sessions"
mkdir -p "$dir"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
title=$(printf '%s' "$input" | jq -r '.session_title // empty | gsub("[\\n\\r\\t]+"; " ")' 2>/dev/null)
# UserPromptSubmit carries the message you sent. Kept to one line and 400 characters,
# sliced by jq so a multibyte character is never cut in half.
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty | gsub("[\\n\\r\\t]+"; " ") | gsub(" +"; " ") | .[0:400]' 2>/dev/null)
[ -z "$session_id" ] && exit 0
case "$session_id" in *[!A-Za-z0-9_-]*) exit 0;; esac

file="$dir/$session_id"

if [ "$state" = "gone" ]; then
  rm -f "$file"
  exit 0
fi

# Only some events carry the title and the prompt, the other events keep what was
# recorded before.
if [ -f "$file" ]; then
  [ -z "$title" ] && title=$(sed -n 's/^title=//p' "$file")
  [ -z "$prompt" ] && prompt=$(sed -n 's/^prompt=//p' "$file")
fi

# Walk up the process tree to the claude process that runs this hook.
pid=$PPID
claude_pid=""
for _ in 1 2 3 4 5 6; do
  [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ] && break
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  exe=${args%% *}
  # The claude binary itself, or a node process that runs claude's script.
  # A shell whose command line merely mentions a path under ~/.claude must not match.
  case "${exe##*/}" in
    claude*) claude_pid=$pid; break;;
    node*) case "$args" in *claude*) claude_pid=$pid; break;; esac;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

tmp="$file.tmp.$$"
{
  echo "state=$state"
  echo "pid=$claude_pid"
  echo "cwd=$cwd"
  echo "title=$title"
  echo "prompt=$prompt"
  echo "updated=$(date +%s)"
} > "$tmp" && mv -f "$tmp" "$file"
exit 0
