# Working on the spine repositories

These rules apply to every agent that works in a spine repository, a subagent included, except where
a section says otherwise. A repository keeps its own rules in its `AGENTS.md` (`CLAUDE.md` only
imports it); what is shared lives here.

If a repository's `AGENTS.md` is not already in your instructions, read it before you change
anything in that repository.

## Tests

This section is for `spine-toolkit`, `spine-platform-swift` and `spine-platform-kotlin`, the
repositories with a foundation suite. Elsewhere, run the repository's `verify` entry in
`spine-ops/repos.json`, where it has one; `spine-ops` itself uses `scripts/test.sh`.

Inside a plan, before every commit up to the full suite, run `scripts/test-foundation.sh touched`
with no files. That is a task's commit and a round of fixes after a task review. It
runs the tests that name what the commit holds: the files that differ from HEAD and the untracked
ones, with no sweeps and no branch base. A changed test file runs itself, a changed helper runs the
tests that load it, a changed file under `skills/` runs the tests that name its skill, and a changed
fixture runs all of `lib/`. In a platform it also always runs the
tests that read the `spine-toolkit` checkout beside.

Outside a plan, before a commit, run `scripts/test-foundation.sh changed`. It runs the tests that
name what the branch touched. In `spine-toolkit` and `spine-platform-kotlin`, `changed --list` prints
the choice without running it. In `spine-platform-swift` it follows the map in
`tests/foundation/README.md` and has no `--list`.

Run the full suite, `scripts/test-foundation.sh all`, once, at the end of a plan: in each repository
the plan touched, before the final review of the branch. Do not run it per task. Commit what a
release needs, the toolkit floor in a platform and the like, before that `all`, or the release runs
the full suite again.

A green `all` records the tree it ran on in `.git/spine-verified-trees`; releasing that tree then
runs only the tests that name the files the release rewrites, so a release right after a plan does
not run the full suite again.

After a green `all`, check every fix on the branch with `scripts/test-foundation.sh verified`
instead of `touched`. It runs what `changed` would run for everything that differs from the newest
verified tree in the history of `HEAD`; in a platform it leaves out the rule for the `spine-toolkit`
checkout beside and always runs the tests that read it instead. When green it records the tree with
`via` and that tree, so the release takes it as verified too. Run it with exactly what the commit
will hold in the worktree, and commit all of it: the record is the worktree's tree, and a commit of
part of it is a different tree, which the release runs the full suite on.

If the full suite finds something, fix it, run the failed files with `bats`, then run `touched`.
Then run the full suite again, once, after the last fix: a red `all` records nothing, so `verified`
has no tree from this plan to start from.

A fix after any review is a `touched` run before a green full suite and a `verified` run after it,
even where the skill that runs the plan, or the prompt it gives a fixer, says to run the whole suite.
The full suite runs again only after a fix to something the full suite itself found.

While iterating on one file, `bats <file>` is enough.

## Waiting for a long run

A suite or a build can outlast one tool call. Start it detached and wait for it in bounded steps.
`long-run.sh` lives in `spine-toolkit`: from that repository it is `scripts/long-run.sh`, from any
other one `../spine-toolkit/scripts/long-run.sh`.

In a subagent, start the run, then wait on its log:

```
scripts/long-run.sh start -- scripts/test-foundation.sh all
scripts/long-run.sh wait <log> --for 110
```

`start` prints the log path. Repeat `wait` until its status is `done`: `done exit=0` passed, any
other exit failed. `running` means call it again. `stalled` means the log has been silent for the
default `--stall`; a command that prints nothing for minutes needs a larger `--stall`. `timeout`, or
`stalled` twice in a row, means stop and report rather than keep waiting. A subagent that ends its
turn ends its work, so it cannot wait for a notification.

In the main session, start the command with `run_in_background` and wait for the notification. In
Codex, which has no `run_in_background`, the main session waits the way a subagent does.

Never wait with a `sleep` or a `pgrep` in a loop.

A suite started in the background inherits SIGINT as ignored. The toolkit's pty test helper resets it, so a
backgrounded run is safe.

## Reading a run

Read the result from the log: `grep '^not ok' <log>`. Do not run the suite again to see another
slice of its output.

## How this file is loaded

`spine/` is not a repository, and two files outside git load this one into every session started
there:

- Claude Code: `spine/CLAUDE.md` holds one line, `@spine-ops/WORKSPACE.md`. Its subagents get the
  same set. It loads a repository's `CLAUDE.md`, and through it `AGENTS.md`, when it touches a file
  in that repository.
- Codex: `spine/AGENTS.md` is a symlink to `spine-ops/WORKSPACE.md`; start `codex` from `spine/`.
  Codex reads `AGENTS.md` only from its starting folder up to the project root, never below, so a
  repository's `AGENTS.md` reaches it through the rule at the top of this file.

`spine-ops/scripts/status.sh` says under `workspace:` whether both are there.
