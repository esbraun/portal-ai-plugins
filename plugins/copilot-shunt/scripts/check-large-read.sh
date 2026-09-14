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
    deny "File is ${lines} lines (threshold: ${MIN_LINES}). Delegate the question and paths to the copilot-shunt:bulk-reader agent. If exact content is needed for an edit, inspect only the relevant bounded range."
  fi
  return 1
}

if [ "$TOOL_NAME" = "view" ]; then
  VIEW_PATH=$(printf '%s' "$TOOL_ARGS" | jq -r '.path // empty' 2>/dev/null) || allow
  VIEW_RANGE=$(printf '%s' "$TOOL_ARGS" | jq -c '.view_range // empty' 2>/dev/null) || allow
  if printf '%s' "$VIEW_RANGE" | jq -e '
    type == "array"
    and length == 2
    and (.[0] | type) == "number"
    and (.[1] | type) == "number"
    and .[0] >= 1
    and .[1] >= .[0]
    and (.[1] - .[0] + 1) <= 300
  ' >/dev/null 2>&1; then
    allow
  fi
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
  cat\ *)
    REST=${TRIMMED#* }
    READER_KIND=cat
    ;;
  head\ *)
    REST=${TRIMMED#* }
    READER_KIND=head
    ;;
  tail\ *)
    REST=${TRIMMED#* }
    READER_KIND=tail
    ;;
  less\ *)
    REST=${TRIMMED#* }
    READER_KIND=less
    ;;
  more\ *)
    REST=${TRIMMED#* }
    READER_KIND=more
    ;;
  rtk\ read\ *)
    REST=${TRIMMED#rtk read }
    READER_KIND=rtk-read
    ;;
  rtk\ cat\ *)
    REST=${TRIMMED#rtk }
    REST=${REST#* }
    READER_KIND=cat
    ;;
  rtk\ head\ *)
    REST=${TRIMMED#rtk }
    REST=${REST#* }
    READER_KIND=head
    ;;
  rtk\ tail\ *)
    REST=${TRIMMED#rtk }
    REST=${REST#* }
    READER_KIND=tail
    ;;
  rtk\ less\ *)
    REST=${TRIMMED#rtk }
    REST=${REST#* }
    READER_KIND=less
    ;;
  rtk\ more\ *)
    REST=${TRIMMED#rtk }
    REST=${REST#* }
    READER_KIND=more
    ;;
  rtk\ proxy\ cat\ *)
    REST=${TRIMMED#rtk proxy }
    REST=${REST#* }
    READER_KIND=cat
    ;;
  rtk\ proxy\ head\ *)
    REST=${TRIMMED#rtk proxy }
    REST=${REST#* }
    READER_KIND=head
    ;;
  rtk\ proxy\ tail\ *)
    REST=${TRIMMED#rtk proxy }
    REST=${REST#* }
    READER_KIND=tail
    ;;
  rtk\ proxy\ less\ *)
    REST=${TRIMMED#rtk proxy }
    REST=${REST#* }
    READER_KIND=less
    ;;
  rtk\ proxy\ more\ *)
    REST=${TRIMMED#rtk proxy }
    REST=${REST#* }
    READER_KIND=more
    ;;
  *) allow ;;
esac

TOKENS=$(printf '%s\n' "$REST" | xargs -n1 printf '%s\n' 2>/dev/null) || allow
[ -n "$TOKENS" ] || allow

OPTIONS=true
SKIP_NEXT=false
while IFS= read -r token; do
  if [ "$SKIP_NEXT" = true ]; then
    SKIP_NEXT=false
    continue
  fi

  if [ "$OPTIONS" = true ]; then
    case "$token" in
      --) OPTIONS=false; continue ;;
      +*) [ "$READER_KIND" = less ] && continue ;;
      -n)
        case "$READER_KIND" in head|tail|more) SKIP_NEXT=true ;; esac
        continue
        ;;
      -c|--lines|--bytes)
        case "$READER_KIND" in head|tail) SKIP_NEXT=true ;; esac
        continue
        ;;
      -b|-j|-k|-o|-O|-p|-P|-t|-T|-x|-y|-z)
        [ "$READER_KIND" = less ] && SKIP_NEXT=true
        continue
        ;;
      -l|--level|-m|--max-lines|--tail-lines)
        [ "$READER_KIND" = rtk-read ] && SKIP_NEXT=true
        continue
        ;;
      --lines=*|--bytes=*|--level=*|--max-lines=*|--tail-lines=*|-*) continue ;;
    esac
  fi

  check_path "$token"
done <<< "$TOKENS"
allow
