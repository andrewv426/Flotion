# Contributing

## Before you commit

```bash
./Scripts/verify.sh          # package build, all tests, data-layer and MCP budgets, app build
./Scripts/verify.sh --ui     # also the in-app smoke test and in-app budgets (opens the app briefly)
```

Warnings are errors in every target, and the budget tests fail the run when a limit is exceeded.

## Commits

```
type(scope): summary in the imperative, 72 characters at most
```

| Type | Use it for |
|---|---|
| `feat` | A capability a user or an MCP client can now see |
| `bug` | A fix for behaviour that was wrong |
| `perf` | Faster or lighter with the same behaviour; quote the `PERF` line before and after |
| `refactor` | Restructuring with no behaviour change |
| `test` | Tests, fixtures or the verify gate only |
| `docs` | Documentation and templates only |
| `build` | Project config, dependencies, build scripts |
| `chore` | Anything else that does not touch shipped code |

Scopes are optional: `core`, `mcp`, `editor`, `ai`, `app`, `diagrams`.

Keep one logical change per commit, and make each commit build on its own. The repository ships a commit message template; turn it on once per clone:

```bash
git config commit.template .gitmessage
```

## Pull requests

The title follows the commit format. The description is filled in from [the template](.github/pull_request_template.md):

- **What this changes** in plain language a newcomer could follow.
- **Why**, with the issue if there is one.
- **Changes**: a table of files, line counts and the reason each one changed.
- **Visuals** when relevant: screenshots for UI changes, and the updated part of [docs/architecture.md](docs/architecture.md) when a process, target, table, tool or data flow changes.
- **How it was checked**, including what was not tested.

Screenshots do not need screen-recording permission: `Scripts/selftest.sh` renders the running app to PNG files in `.build/selftest/`.

## Where things go

| Change | Place | Test it in |
|---|---|---|
| Data model, storage, search, Markdown, diagram validation | `Packages/FlotionKit/Sources/FlotionCore` | `FlotionCoreTests` |
| An MCP tool | `Sources/FlotionMCP` (the tool list is asserted in `MCPTests`: changing it is deliberate) | `FlotionMCPTests` |
| An editing rule (split, merge, indent, undo) | `Sources/FlotionEditor/EditorState.swift` | `FlotionEditorTests` |
| AI provider, stream parsing, chat state | `Sources/FlotionAI` | `FlotionAITests` with `FakeProvider` |
| Views | `App/` | `App/Debug/SelfTest.swift` |
| A performance budget | `Tests/FlotionPerfTests` or `SelfTest.runPerformance` | `./Scripts/verify.sh --ui` |

Logic belongs in the package, where it runs headless in milliseconds. `App/` holds views only.
