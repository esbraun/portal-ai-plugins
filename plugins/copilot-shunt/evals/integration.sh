#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
COPILOT_BIN="${COPILOT_BIN:-copilot}"
EXPECTED_VERSION="${COPILOT_SHUNT_EXPECTED_VERSION:-1.0.83}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

for dependency in "$COPILOT_BIN" jq node; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "FAIL: $dependency is required to run copilot-shunt integration tests" >&2
    exit 1
  }
done

PASSED=0
FAILED=0

pass() {
  printf 'PASS  %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAILED=$((FAILED + 1))
}

assert_contains() {
  local name="$1" value="$2" expected="$3"
  if printf '%s' "$value" | grep -Fq "$expected"; then
    pass "$name"
  else
    fail "$name (missing: $expected)"
  fi
}

VERSION_OUTPUT=$("$COPILOT_BIN" --version 2>&1)
ACTUAL_VERSION=$(printf '%s\n' "$VERSION_OUTPUT" |
  sed -n 's/^GitHub Copilot CLI \([^[:space:]]*\)\.$/\1/p' |
  head -n 1)
if [ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ]; then
  pass "Copilot CLI version"
else
  fail "Copilot CLI version (expected $EXPECTED_VERSION, got ${ACTUAL_VERSION:-unknown})"
fi

PLUGIN_LIST=$("$COPILOT_BIN" --plugin-dir "$PLUGIN_DIR" plugin list 2>&1)
assert_contains "plugin discovered" "$PLUGIN_LIST" "copilot-shunt"

awk 'BEGIN {
  for (i = 1; i <= 401; i++) {
    if (i == 17) print "EARLY_MARKER database=postgres"
    else if (i == 389) print "LATE_MARKER cache=redis"
    else print "fixture line " i
  }
}' > "$WORKDIR/large.txt"

cat > "$WORKDIR/reference-order-service.test.js" <<'EOF'
const assert = require("node:assert/strict");
const test = require("node:test");

const { findOrder } = require("./order-service");

test("returns an existing order", () => {
  assert.deepEqual(findOrder("order-1"), { id: "order-1", total: 42 });
});

test("returns null for an unknown order", () => {
  assert.equal(findOrder("missing"), null);
});
EOF

cat > "$WORKDIR/user-service.js" <<'EOF'
const users = new Map([["user-1", { id: "user-1", name: "Ada" }]]);

function findUser(id) {
  return users.get(id) ?? null;
}

module.exports = { findUser };
EOF

printf 'do not modify\n' > "$WORKDIR/unrelated.txt"

(
  cd "$WORKDIR" &&
    "$COPILOT_BIN" \
      --plugin-dir "$PLUGIN_DIR" \
      --allow-all \
      --no-custom-instructions \
      --output-format json \
      -p "Use the view tool exactly once to read all of large.txt. If the hook denies it, do not retry or delegate; report the denial briefly."
) > "$WORKDIR/native-read.jsonl"

if jq -e '
  select(
    .type == "tool.execution_complete"
    and .data.success == false
    and ((.data.error.message // "") | contains("Denied by preToolUse hook"))
  )
' "$WORKDIR/native-read.jsonl" >/dev/null; then
  pass "live native read denied"
else
  fail "live native read denied"
fi

if jq -e '
  select(
    .type == "tool.execution_complete"
    and .data.success == false
    and ((.data.error.message // "") | contains("copilot-shunt:bulk-reader"))
  )
' "$WORKDIR/native-read.jsonl" >/dev/null; then
  pass "live hook provides namespaced route"
else
  fail "live hook provides namespaced route"
fi

(
  cd "$WORKDIR" &&
    "$COPILOT_BIN" \
      --plugin-dir "$PLUGIN_DIR" \
      --allow-all \
      --no-custom-instructions \
      --output-format json \
      -p "Use the bash tool exactly once to run: rtk read large.txt. If the hook denies it, do not retry or delegate; report the denial briefly."
) > "$WORKDIR/rtk-read.jsonl"

if jq -e '
  select(
    .type == "tool.execution_complete"
    and .data.success == false
    and ((.data.error.message // "") | contains("Denied by preToolUse hook"))
  )
' "$WORKDIR/rtk-read.jsonl" >/dev/null; then
  pass "live RTK read denied"
else
  fail "live RTK read denied"
fi

(
  cd "$WORKDIR" &&
    "$COPILOT_BIN" \
      --plugin-dir "$PLUGIN_DIR" \
      --agent copilot-shunt:bulk-reader \
      --allow-all \
      --no-custom-instructions \
      --output-format json \
      -p "Read large.txt completely and report the exact marker names and values. Keep the answer concise."
) > "$WORKDIR/bulk-reader.jsonl"

BULK_OUTPUT=$(jq -r '
  select(.type == "assistant.message") | .data.content // .data.message // empty
' "$WORKDIR/bulk-reader.jsonl")
assert_contains "bulk-reader early marker name" "$BULK_OUTPUT" "EARLY_MARKER"
assert_contains "bulk-reader early marker value" "$BULK_OUTPUT" "database=postgres"
assert_contains "bulk-reader late marker name" "$BULK_OUTPUT" "LATE_MARKER"
assert_contains "bulk-reader late marker value" "$BULK_OUTPUT" "cache=redis"

if jq -e -s '
  [
    .[]
    | select(.type == "tool.execution_start" and .data.toolName == "view")
  ] as $views
  | ($views | length) > 0
    and all(
      $views[];
      (.data.arguments.view_range | type) == "array"
      and (.data.arguments.view_range | length) == 2
      and .data.arguments.view_range[0] >= 1
      and .data.arguments.view_range[1] >= .data.arguments.view_range[0]
      and (.data.arguments.view_range[1] - .data.arguments.view_range[0] + 1) <= 300
    )
' "$WORKDIR/bulk-reader.jsonl" >/dev/null; then
  pass "bulk-reader uses only bounded native views"
else
  fail "bulk-reader uses only bounded native views"
fi

if jq -e '
  select(.type == "model.call_start" and .data.model == "gpt-5.6-luna")
' "$WORKDIR/bulk-reader.jsonl" >/dev/null; then
  pass "authored worker model used"
else
  fail "authored worker model used"
fi

WRITER_OUTPUT=$(
  cd "$WORKDIR" &&
    "$COPILOT_BIN" \
      --plugin-dir "$PLUGIN_DIR" \
      --agent copilot-shunt:code-writer \
      --allow-all \
      --no-custom-instructions \
      --silent \
      -p "Create user-service.test.js. Specification: test successful lookup of user-1 and missing lookup returning null. Reference: reference-order-service.test.js. Target: user-service.test.js. Match the reference style and only change the target."
)

assert_contains "code-writer target summary" "$WRITER_OUTPUT" "user-service.test.js"

if (
  cd "$WORKDIR" &&
    node --test user-service.test.js >/dev/null &&
    [ "$(cat unrelated.txt)" = "do not modify" ] &&
    ! grep -Eq '```|TODO|PLACEHOLDER' user-service.test.js
); then
  pass "code-writer generated usable target"
else
  fail "code-writer generated usable target"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
