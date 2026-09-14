#!/usr/bin/env bash
# Behavioral guard for GitHub Copilot CLI. Blocks common unbounded reads of
# large files and tells the parent agent to use the bulk-reader subagent.
#
# Deliberately fail open for malformed or inapplicable input: Copilot CLI
# treats a non-zero preToolUse hook exit as a denial.

MIN_LINES="${COPILOT_SHUNT_MIN_LINES:-350}"
case "$MIN_LINES" in
  ''|*[!0-9]*) MIN_LINES=350 ;;
esac

allow() {
  printf '{}\n'
  exit 0
}

deny() {
  jq -cn --arg reason "$1" \
    '{permissionDecision:"deny", permissionDecisionReason:$reason}'
  exit 0
}

command -v jq >/dev/null 2>&1 || allow

INPUT=$(cat) || allow
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || allow

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.toolName // empty' 2>/dev/null) || allow
EVENT_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || allow
[ -n "$EVENT_CWD" ] || EVENT_CWD=$(pwd)

# Current CLI hooks normally encode toolArgs as a JSON string. The SDK hook
# contract also permits an object, so accept both documented representations.
TOOL_ARGS=$(printf '%s' "$INPUT" | jq -c '
  .toolArgs as $args
  | if ($args | type) == "string" then (try ($args | fromjson) catch {})
    elif ($args | type) == "object" then $args
    else {}
    end
' 2>/dev/null) || allow

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$EVENT_CWD" "$1" ;;
  esac
}

check_path() {
  local supplied_path="$1" resolved_path lines
  [ -n "$supplied_path" ] || return 1
  resolved_path=$(resolve_path "$supplied_path")
  [ -f "$resolved_path" ] && [ -r "$resolved_path" ] || return 1
  lines=$(wc -l < "$resolved_path" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$lines" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$lines" -gt "$MIN_LINES" ]; then
    deny "File is ${lines} lines (threshold: ${MIN_LINES}). Delegate the question and paths to the bulk-reader agent. If exact content is needed for an edit, inspect only the relevant bounded range."
  fi
  return 1
}

if [ "$TOOL_NAME" = "view" ]; then
  VIEW_PATH=$(printf '%s' "$TOOL_ARGS" | jq -r '.path // empty' 2>/dev/null) || allow
  check_path "$VIEW_PATH"
  allow
fi

[ "$TOOL_NAME" = "bash" ] || allow
COMMAND=$(printf '%s' "$TOOL_ARGS" | jq -r '.command // empty' 2>/dev/null) || allow
[ -n "$COMMAND" ] || allow

# Piped reads are assumed to filter their output, and redirections are not
# reads into model context. Compound commands are left alone rather than
# partially parsing shell syntax and producing unsafe false positives.
if [[ "$COMMAND" == *"|"* || "$COMMAND" == *">"* ||
      "$COMMAND" == *";"* || "$COMMAND" == *"&&"* ]]; then
  allow
fi

TRIMMED=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
case "$TRIMMED" in
  cat\ *|head\ *|tail\ *|less\ *|more\ *) ;;
  *) allow ;;
esac

REST=${TRIMMED#* }
SHELL_PATH=""

# Common one-file forms, including a quoted path containing spaces. For
# unquoted commands, the final token is the file operand; preceding flags and
# numeric head/tail counts are ignored.
if [[ "$REST" =~ \"([^\"]+)\"[[:space:]]*$ ]]; then
  SHELL_PATH="${BASH_REMATCH[1]}"
elif [[ "$REST" =~ \'([^\']+)\'[[:space:]]*$ ]]; then
  SHELL_PATH="${BASH_REMATCH[1]}"
else
  SHELL_PATH=${REST##*[[:space:]]}
fi

case "$SHELL_PATH" in ''|-*) allow ;; esac
check_path "$SHELL_PATH"
allow
