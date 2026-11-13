<!--
Title: type(scope): short summary
Types: feat · bug · perf · refactor · test · docs · build · chore
Scopes (optional): core · mcp · editor · ai · app · diagrams
Example: feat(editor): add table blocks
-->

## What this changes

<!-- Two to four plain sentences that someone new to the project could follow.
     Say what a user, or an MCP client, can now do, or what no longer goes wrong.
     No file names here; that is the next section. -->

## Why

<!-- The problem or goal behind it. Link the issue if there is one. -->

## Changes

<!-- One row per file, or per group of trivial files. `git diff --stat main...HEAD` gives the line counts.
     "Why" is the reason this file had to change, in a few words. -->

| File | Lines | What changed and why |
|---|---|---|
| `path/to/File.swift` | +40 −12 | |

## Visuals

<!-- Delete this section if nothing visible or structural changed.

     UI change: before and after screenshots. `Scripts/selftest.sh` writes PNGs of the
     running app to .build/selftest/, with no screen-recording permission needed.

     Architecture change (a new process, target, table, tool or data flow): update
     docs/architecture.md and paste the changed part of the diagram here. -->

## How it was checked

- [ ] `./Scripts/verify.sh` passes
- [ ] `./Scripts/verify.sh --ui` passes (needed when `App/` or anything performance-sensitive changed)
- [ ] New behaviour has a test, or the note below says why not

<!-- Paste any PERF lines that moved, old → new. Say plainly what was not tested. -->

## Notes for the reviewer

<!-- Risks, follow-ups, or a decision you want a second opinion on. Delete if empty. -->
