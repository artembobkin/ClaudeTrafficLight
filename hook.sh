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
#
# The script runs on every tool call, so it stays cheap: one jq call for the
# payload, the claude pid is looked up once per session, and it always exits 0
# with nothing on stdout, so it can neither block nor confuse Claude Code.

state="$1"
dir="$HOME/.claude/traffic-light/sessions"
[ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || exit 0

# One jq call gives the four fields, one per line. Title and prompt are folded to
# one line and the prompt is cut to 400 characters, sliced by jq so a multibyte
# character is never cut in half.
fields=$(jq -r '
  def line: tostring | gsub("[\\n\\r\\t]+"; " ") | gsub(" +"; " ");
  (.session_id // ""), (.cwd // ""),
  ((.session_title // "") | line),
  ((.prompt // "") | line | .[0:400])' 2>/dev/null) || exit 0
{
  IFS= read -r session_id
  IFS= read -r cwd
  IFS= read -r title
  IFS= read -r prompt
} <<< "$fields"

[ -z "$session_id" ] && exit 0
case "$session_id" in *[!A-Za-z0-9_-]*) exit 0;; esac

file="$dir/$session_id"

if [ "$state" = "gone" ]; then
  rm -f "$file"
  exit 0
fi

# Only some events carry the title and the prompt, and the pid does not change,
# so the other events keep what was recorded before.
claude_pid=""
if [ -f "$file" ]; then
  while IFS= read -r line; do
    case "$line" in
      pid=*) claude_pid=${line#pid=};;
      title=*) [ -z "$title" ] && title=${line#title=};;
      prompt=*) [ -z "$prompt" ] && prompt=${line#prompt=};;
    esac
  done < "$file"
fi

# Walk up the process tree to the claude process that runs this hook.
if [ -z "$claude_pid" ]; then
  pid=$PPID
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
fi

tmp="$file.tmp.$$"
{
  echo "state=$state"
  echo "pid=$claude_pid"
  echo "cwd=$cwd"
  echo "title=$title"
  echo "prompt=$prompt"
  echo "updated=$(date +%s)"
} > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
rm -f "$tmp" 2>/dev/null
exit 0
