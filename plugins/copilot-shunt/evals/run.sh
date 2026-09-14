#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
HOOK="$PLUGIN_DIR/scripts/check-large-read.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required to run copilot-shunt evals" >&2
  exit 1
}

for i in $(seq 1 100); do printf 'small %s\n' "$i"; done > "$WORKDIR/small.txt"
for i in $(seq 1 351); do printf 'large %s\n' "$i"; done > "$WORKDIR/large.txt"
cp "$WORKDIR/large.txt" "$WORKDIR/large file.txt"

PASSED=0
FAILED=0

run_case() {
  local name="$1" expected="$2" payload="$3" actual output
  output=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  actual=$(printf '%s' "$output" | jq -r '.permissionDecision // "allow"' 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL  %s (expected %s, got %s; output=%s)\n' "$name" "$expected" "$actual" "$output"
    FAILED=$((FAILED + 1))
  fi
}

payload() {
  jq -cn --arg cwd "$WORKDIR" --arg tool "$1" --argjson args "$2" \
    '{sessionId:"eval", timestamp:0, cwd:$cwd, toolName:$tool, toolArgs:($args|tojson)}'
}

payload_object_args() {
  jq -cn --arg cwd "$WORKDIR" --arg tool "$1" --argjson args "$2" \
    '{sessionId:"eval", timestamp:0, cwd:$cwd, toolName:$tool, toolArgs:$args}'
}

run_case "large view denied" deny "$(payload view '{"path":"large.txt"}')"
run_case "object toolArgs accepted" deny "$(payload_object_args view '{"path":"large.txt"}')"
run_case "bounded large view allowed" allow "$(payload view '{"path":"large.txt","view_range":[1,300]}')"
run_case "oversized large view range denied" deny "$(payload view '{"path":"large.txt","view_range":[1,301]}')"
run_case "open-ended large view range denied" deny "$(payload view '{"path":"large.txt","view_range":[301,-1]}')"
run_case "small view allowed" allow "$(payload view '{"path":"small.txt"}')"
run_case "missing view allowed" allow "$(payload view '{"path":"missing.txt"}')"
run_case "directory view allowed" allow "$(payload view '{"path":"."}')"
run_case "malformed event allowed" allow '{not-json'
run_case "large cat denied" deny "$(payload bash '{"command":"cat large.txt"}')"
run_case "large quoted path denied" deny "$(payload bash '{"command":"cat \"large file.txt\""}')"
run_case "large escaped path denied" deny "$(payload bash '{"command":"cat large\\ file.txt"}')"
run_case "large concatenated quote path denied" deny "$(payload bash '{"command":"cat \"large file\".txt"}')"
run_case "large first multi-file cat denied" deny "$(payload bash '{"command":"cat large.txt small.txt"}')"
run_case "large head denied" deny "$(payload bash '{"command":"head -100 large.txt"}')"
run_case "large first multi-file head denied" deny "$(payload bash '{"command":"head large.txt small.txt"}')"
run_case "small tail allowed" allow "$(payload bash '{"command":"tail small.txt"}')"
run_case "large first multi-file tail denied" deny "$(payload bash '{"command":"tail large.txt small.txt"}')"
run_case "less option argument not treated as file" allow "$(payload bash '{"command":"less -p large.txt small.txt"}')"
run_case "large first multi-file less denied" deny "$(payload bash '{"command":"less large.txt small.txt"}')"
run_case "large first multi-file more denied" deny "$(payload bash '{"command":"more large.txt small.txt"}')"
run_case "large rtk read denied" deny "$(payload bash '{"command":"rtk read large.txt"}')"
run_case "small rtk read allowed" allow "$(payload bash '{"command":"rtk read small.txt"}')"
run_case "large escaped rtk read denied" deny "$(payload bash '{"command":"rtk read large\\ file.txt"}')"
run_case "bounded option large rtk read denied" deny "$(payload bash '{"command":"rtk read --max-lines 100 large.txt"}')"
run_case "large first multi-file rtk read denied" deny "$(payload bash '{"command":"rtk read large.txt small.txt"}')"
run_case "large rtk cat denied" deny "$(payload bash '{"command":"rtk cat large.txt"}')"
run_case "large rtk proxy cat denied" deny "$(payload bash '{"command":"rtk proxy cat large.txt"}')"
run_case "large first multi-file rtk proxy cat denied" deny "$(payload bash '{"command":"rtk proxy cat large.txt small.txt"}')"
run_case "large rtk proxy quoted path denied" deny "$(payload bash '{"command":"rtk proxy cat \"large file.txt\""}')"
run_case "large rtk proxy head denied" deny "$(payload bash '{"command":"rtk proxy head -100 large.txt"}')"
run_case "large first multi-file rtk proxy head denied" deny "$(payload bash '{"command":"rtk proxy head large.txt small.txt"}')"
run_case "bounded rtk proxy sed allowed" allow "$(payload bash '{"command":"rtk proxy sed -n '\''1,300p'\'' large.txt"}')"
run_case "rtk line count allowed" allow "$(payload bash '{"command":"rtk wc -l large.txt"}')"
run_case "piped read allowed" allow "$(payload bash '{"command":"cat large.txt | grep needle"}')"
run_case "piped rtk read allowed" allow "$(payload bash '{"command":"rtk read large.txt | grep needle"}')"
run_case "redirected read allowed" allow "$(payload bash '{"command":"cat large.txt > copy.txt"}')"
run_case "bounded sed allowed" allow "$(payload bash '{"command":"sed -n '\''1,300p'\'' large.txt"}')"
run_case "unrelated command allowed" allow "$(payload bash '{"command":"git status"}')"

ROUTING_OUTPUT=$(printf '%s' "$(payload view '{"path":"large.txt"}')" | bash "$HOOK")
if printf '%s' "$ROUTING_OUTPUT" | jq -e '
  .permissionDecision == "deny"
  and (.permissionDecisionReason | contains("copilot-shunt:bulk-reader"))
' >/dev/null; then
  printf 'PASS  hook namespaced routing guidance\n'
  PASSED=$((PASSED + 1))
else
  printf 'FAIL  hook namespaced routing guidance\n'
  FAILED=$((FAILED + 1))
fi

CUSTOM_PAYLOAD=$(payload view '{"path":"small.txt"}')
CUSTOM_OUTPUT=$(printf '%s' "$CUSTOM_PAYLOAD" | COPILOT_SHUNT_MIN_LINES=50 bash "$HOOK")
CUSTOM_ACTUAL=$(printf '%s' "$CUSTOM_OUTPUT" | jq -r '.permissionDecision // "allow"')
if [ "$CUSTOM_ACTUAL" = deny ]; then
  printf 'PASS  custom threshold\n'
  PASSED=$((PASSED + 1))
else
  printf 'FAIL  custom threshold\n'
  FAILED=$((FAILED + 1))
fi

jq -e '.name == "copilot-shunt" and .version == "0.1.0" and ."$schema" == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"' \
  "$PLUGIN_DIR/plugin.json" >/dev/null || {
    printf 'FAIL  plugin manifest\n'
    FAILED=$((FAILED + 1))
  }
jq -e '.version == 1 and (.hooks.preToolUse | length) == 1' \
  "$PLUGIN_DIR/com.github.copilot/hooks/hooks.json" >/dev/null || {
    printf 'FAIL  hooks manifest\n'
    FAILED=$((FAILED + 1))
  }

for agent in bulk-reader code-writer; do
  agent_file="$PLUGIN_DIR/com.github.copilot/agents/$agent.agent.md"
  if ! grep -q '^model: gpt-5\.6-luna$' "$agent_file" ||
     ! grep -q '^modelPolicy: preferred$' "$agent_file" ||
     ! grep -q '^reasoningEffort: max$' "$agent_file"; then
    printf 'FAIL  %s model configuration\n' "$agent"
    FAILED=$((FAILED + 1))
  fi
done

if grep -q '^infer: false$' \
  "$PLUGIN_DIR/com.github.copilot/agents/bulk-reader.agent.md" &&
   grep -q '^infer: true$' \
  "$PLUGIN_DIR/com.github.copilot/agents/code-writer.agent.md"; then
  printf 'PASS  hook-first agent inference policy\n'
  PASSED=$((PASSED + 1))
else
  printf 'FAIL  hook-first agent inference policy\n'
  FAILED=$((FAILED + 1))
fi

if grep -q 'Never invoke RTK' \
  "$PLUGIN_DIR/com.github.copilot/agents/bulk-reader.agent.md" &&
   grep -q '^  - bash$' \
  "$PLUGIN_DIR/com.github.copilot/agents/bulk-reader.agent.md"; then
  printf 'PASS  bulk-reader RTK exemption\n'
  PASSED=$((PASSED + 1))
else
  printf 'FAIL  bulk-reader RTK exemption\n'
  FAILED=$((FAILED + 1))
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
