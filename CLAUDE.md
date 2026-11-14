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

## Finishing: open a PR

When the change is done:

1. Run `./Scripts/verify.sh` (and `--ui` when `App/` or anything performance-sensitive changed) in the worktree, and add a test for new behaviour.
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
