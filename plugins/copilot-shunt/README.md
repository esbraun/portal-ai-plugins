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

## Agents

### bulk-reader

The main agent can infer this agent for files over 350 lines, questions across three or more
files, and large diff summaries. You can also request it explicitly:

```text
Use the bulk-reader agent to identify the database calls in src/service.ts and src/store.ts.
```

It is read-only, consumes oversized files in bounded chunks, and returns concise findings with
path and line references.

### code-writer

The main agent can infer this agent for predictable generation based on an existing pattern:

```text
Use the code-writer agent to create tests/user-service.test.ts from this specification, matching
the patterns in tests/order-service.test.ts: cover successful lookup and a missing user.
```

The task must identify a specification, reference, and target. The agent writes directly to the
shared worktree and returns only a short summary.

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

The gate intentionally allows pipes, redirections, compound commands, and `sed`. The
bulk-reader uses bounded `sed` ranges to do its work. This is a behavioral routing aid, not a
security boundary or a complete shell parser.

## Test

Hook and static configuration checks need no Copilot authentication:

```bash
bash plugins/copilot-shunt/evals/run.sh
```

For an integration smoke test, load the plugin with `--plugin-dir`, confirm it under `/env`,
attempt a full read of a file over the threshold, then exercise both agents and a model override
from `/subagents`.
