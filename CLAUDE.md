# Flotion

A native macOS notes app (SwiftUI + AppKit) with a bundled MCP server. Read [README.md](README.md) for the layout and [CONTRIBUTING.md](CONTRIBUTING.md) for commit, PR and placement rules; they apply to everything below.

## One worktree and branch per feature or fix

Never implement or test a change in the main checkout. Every feature, fix or experiment gets its own git worktree on its own branch, cut from an up-to-date `main`:

```bash
git fetch origin
git worktree add .worktrees/<name> -b <type>/<name> origin/main
```

- `<type>` is the commit type from CONTRIBUTING.md (`feat`, `bug`, `perf`, `refactor`, `test`, `docs`, `build`, `chore`); `<name>` is short and kebab-case, e.g. `bug/editor-placeholder`.
- Worktrees live in `.worktrees/` at the repository root, which is git-ignored. Do all editing, building and testing inside the worktree.
- A worktree starts without the generated Xcode project or build products. Run `xcodegen generate` there before the first app build; `./Scripts/verify.sh` does this for you.
- Run app builds and `--ui` tests in one worktree at a time. Parallel Xcode builds slow each other down and make the in-app performance budgets fail for the wrong reason.
- Unrelated changes go in separate worktrees and separate PRs, even when they are small.

## Testing without getting in the user's way

The user keeps working on this Mac while tests run, so test in the background by default:

- `swift test` and `./Scripts/verify.sh`, including `--ui`, show nothing on screen. The in-app tests run in background mode: no Dock icon, transparent off-screen windows that ignore the mouse, the app never takes focus, and it uses its own preferences (`app.flotion.Flotion.tests`), never the user's.
- Ask first before anything that takes over the screen, mouse or keyboard: `FLOTION_FOREGROUND=1`, computer use, or launching the app normally.

### What a background run cannot check

Background mode gives these up. A background run does not verify any of them:

| Not checked in the background | Why | How to check it |
|---|---|---|
| Anything that needs keyboard focus: SwiftUI key handlers (`onKeyPress`, `.keyboardShortcut`), `@FocusState`, focus rings, code that reads `isKeyWindow` or `NSApp.isActive` | The app never becomes active | `FLOTION_FOREGROUND=1 Scripts/selftest.sh` (takes focus for about 15 seconds), or by hand |
| The real keyboard path: key bindings, menu shortcuts, input methods (Japanese, Chinese, dead keys) | The self-test types by calling the text views or sending events straight to the window | By hand |
| The mouse: clicks, hover, drag and drop, trackpad scrolling | Test windows ignore the mouse | By hand, or computer use with the user's permission |
| How it looks on the real screen: shadows, materials and Liquid Glass, animation, placement near screen edges or across displays | Snapshots render views to a bitmap, and the windows are transparent and off-screen | A foreground run, or by hand |
| macOS's own text-input popups: autocorrect and completion bubbles, the input-source indicator, Writing Tools | Background mode closes them as they appear, since they fade themselves in over any transparency | By hand |
| Exact performance numbers | The user's own work shares the CPU | Rerun when the machine is idle, or compare against `main` in the same session |

In the self-test, wrap a check that needs focus in `if needsFocus("what it checks") { ... }`. Without focus it is logged as `skip …` and counted in the `RESULT` line, never passed silently. If macOS makes the background app active anyway, it gives focus straight back and the run logs a `note` line; mention that to the user too.

### Tell the user what was not verified

When a change touches anything in that table, or a run prints `skip` lines or misses a budget:

- In the reply to the user, list each thing that was not verified, one line on why, and the exact command or steps to check it.
- Put the same list in the PR's "How it was checked".
- Never describe skipped or unverifiable behaviour as tested.

## Finishing: open a PR

When the change is done:

1. Run `./Scripts/verify.sh` (and `--ui` when `App/` or anything performance-sensitive changed) in the worktree, and add a test for new behaviour. Note anything the background run could not check (see above).
2. Commit following CONTRIBUTING.md.
3. Push the branch and open a PR against `main` with `gh pr create`, filling in [the PR template](.github/pull_request_template.md). Say plainly what was not tested.

Do not merge PRs yourself unless asked.

## Cleaning up after a PR closes

Once a PR is merged or closed, remove its worktree and branches. Check the state first and clean up only when it is `MERGED` or `CLOSED`:

```bash
gh pr view <branch> --json state -q .state
```

```bash
git worktree remove .worktrees/<name>
```

```bash
git branch -D <type>/<name>
```

```bash
git push origin --delete <type>/<name>
```

- Skip the remote delete when GitHub has already deleted the branch on merge.
- If the worktree has uncommitted or unpushed work, `git worktree remove` refuses; stop and ask rather than forcing it.
- `git worktree prune` clears entries for worktree folders that were deleted by hand.
- Never remove a worktree or branch whose PR is still open.
