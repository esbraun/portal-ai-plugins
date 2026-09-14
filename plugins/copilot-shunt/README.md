# copilot-shunt

A standalone GitHub Copilot CLI plugin that keeps bulk file contents and predictable code
generation out of the parent agent's context. It does not use Spotify Portal, Portal CLI, AiKA,
or an MCP server.

## Requirements

- A current, authenticated GitHub Copilot CLI
- macOS or Linux with Bash
- [`jq`](https://jqlang.org/)

## Install

From a local checkout:

```bash
copilot plugin install ./plugins/copilot-shunt
```

Or directly from this repository subdirectory:

```bash
copilot plugin install spotify/portal-ai-plugins:plugins/copilot-shunt
```

Copilot caches installed plugins. Re-run the local install command after changing the plugin,
then start a new session. During development, it can also be loaded without installation:

```bash
copilot --plugin-dir ./plugins/copilot-shunt
```

Use `/env` to confirm that `copilot-shunt`, both agents, and the hook were loaded. Use
`/subagents` to inspect or change their models.

## Scope and routing contract

The plugin has two deliberately different routing paths:

- **Bulk reading is hook-gated.** `bulk-reader` has `infer: false`. An unbounded read of a
  readable file over the configured line threshold is denied by the `preToolUse` hook, which
  names `copilot-shunt:bulk-reader` as the next command. The hook is the deterministic first
  stage; explicit agent invocation is the second stage because Copilot hooks cannot replace a
  tool call with an agent call.
- **Boilerplate generation is choice-gated.** `code-writer` keeps `infer: true` because deciding
  whether a task is predictable pattern-based generation requires model judgment. It can also be
  selected explicitly for repeatable automation.

Compared with the initial implementation, bulk-reader inference is no longer part of the
contract. The read gate now handles RTK-wrapped commands, multiple file operands, escaped or
quoted paths, and bounded native `view` ranges. Authenticated integration coverage also verifies
the hook path before exercising either agent directly.

## Agents

### bulk-reader

The read hook routes files over 350 lines to this agent. It is deliberately not inference-driven:
the deterministic line threshold activates it, or you can request it explicitly:

```text
Use the bulk-reader agent to identify the database calls in src/service.ts and src/store.ts.
```

It is read-only, consumes oversized files in bounded chunks, and returns concise findings with
path and line references.

For non-interactive CLI use, select the plugin-qualified agent name:

```bash
copilot --plugin-dir ./plugins/copilot-shunt \
  --agent copilot-shunt:bulk-reader \
  --allow-all \
  -p "Identify the database calls in src/service.ts and src/store.ts."
```

### code-writer

The main agent can infer this agent when it decides a request is predictable, pattern-based
generation:

```text
Use the code-writer agent to create tests/user-service.test.ts from this specification, matching
the patterns in tests/order-service.test.ts: cover successful lookup and a missing user.
```

The task must identify a specification, reference, and target. The agent writes directly to the
shared worktree and returns only a short summary.

The non-interactive agent name is `copilot-shunt:code-writer`.

## Models

Both agents default to the GitHub Copilot model ID `gpt-5.6-luna` with
`reasoningEffort: max`. Their `modelPolicy` is `preferred`, so the defaults are not locked.

Choose any model available to your Copilot account interactively with `/subagents`, or set
per-agent overrides in `~/.copilot/settings.json`:

```json
{
  "subagents": {
    "agents": {
      "bulk-reader": {
        "model": "gpt-5.6-luna",
        "effortLevel": "max"
      },
      "code-writer": {
        "model": "gpt-5.6-luna",
        "effortLevel": "max"
      }
    }
  }
}
```

Replace either model string with any model the account and organization policy permit. If the
authored default is unavailable, Copilot's preferred-model policy can fall back to the session
model.

## Read gate

The `preToolUse` hook denies:

- Native `view` calls for readable files over 350 lines
- Direct `cat`, `head`, `tail`, `less`, and `more` reads of those files

Set `COPILOT_SHUNT_MIN_LINES` before starting Copilot to change the threshold:

```bash
export COPILOT_SHUNT_MIN_LINES=500
copilot
```

The gate permits native `view` ranges of at most 300 lines so the bulk-reader can inspect a large
file in deterministic windows. It intentionally allows pipes, redirections, compound commands,
and `sed`; this is a behavioral routing aid, not a security boundary or a complete shell parser.

The hook is the deterministic first stage: it blocks the oversized read and names
`copilot-shunt:bulk-reader` in the denial. Copilot hooks cannot replace one tool call with an
agent call, so invoking that named agent is the explicit second stage.

## RTK interaction

RTK is optional and is not a plugin dependency. The hook recognizes RTK command text without
executing or probing the `rtk` binary, so installing copilot-shunt does not fail or change behavior
when RTK is absent.

When RTK is installed:

- In the parent agent, unbounded `rtk read`, RTK-wrapped `cat`, and `rtk proxy` forms of
  `cat`, `head`, `tail`, `less`, and `more` are checked against the same line threshold as their
  native forms. Every parsed file operand is checked.
- Small files remain readable. Pipes, redirections, compound commands, metadata commands, and
  bounded alternatives remain outside the gate's intentionally narrow scope.
- Inside `bulk-reader`, RTK is skipped. File contents are read through native `view_range`
  windows of at most 300 lines so filtering cannot hide source text. Raw `bash` remains available
  for metadata, diffs, and other analysis that does not replace those bounded content reads.

The effective instruction precedence is:

1. `bulk-reader` fidelity rules
2. RTK rules for the parent agent
3. Other command preferences

## Test

Hook and static configuration checks need no Copilot authentication:

```bash
bash plugins/copilot-shunt/evals/run.sh
```

Authenticated integration checks create a disposable fixture repository. They verify plugin
loading and live hook behavior first, then run secondary explicit-command smoke tests for both
agents and the authored worker model:

```bash
bash plugins/copilot-shunt/evals/integration.sh
```

The integration suite uses GitHub Copilot requests and therefore consumes account quota. It tests
Copilot CLI 1.0.83 by default; set `COPILOT_SHUNT_EXPECTED_VERSION` to another exact version when
intentionally validating a different release.
