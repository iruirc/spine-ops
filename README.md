# spine-ops

Maintenance for the `spine-toolkit` family: the plugins, and the marketplace that lists them.

It lives outside all three because it must name all three. `spine-toolkit` cannot host it — its own
suite forbids core naming a sibling tree by filesystem path — and `claude-marketplace` is a public
catalogue, not a workshop.

## Layout it assumes

All repositories are siblings:

```
spine/
  claude-marketplace/
  spine-toolkit/
  swift-platform/
  spine-ops/          <- here
```

`repos.json` declares that, and nothing else: **which checkout is where, and how each one verifies
itself**. Which plugins exist is not written here — it is read from the marketplace's own
`marketplace.json`. Two rosters would drift, and the drift `check.sh` found on its first run is what
that looks like.

## Commands

| | |
|---|---|
| `scripts/status.sh` | one table: version, highest tag, branch, ahead/behind, tree, and unreleased commits |
| `scripts/check.sh` | the invariants nobody was checking — exits 1 on a breach |
| `scripts/release.sh` | bump, commit, tag. Stops there |
| `scripts/push.sh` | publish what release prepared, `--dry-run` to look first |

## Releasing

```
scripts/release.sh minor                        every repo with work since its last tag
scripts/release.sh minor swift-platform=patch   same, one overridden
scripts/release.sh spine-toolkit=minor          only that one
scripts/release.sh spine-toolkit=1.3.0          an explicit version
```

The marketplace is never released alone and never skipped: any plugin bump rewrites its listing, so
it goes along at the highest increment of the release unless `marketplace=<kind|version>` says
otherwise. An explicit plugin version carries no increment, so the marketplace defaults to `patch`
there — name it yourself when that is wrong.

**The release body of each plugin is a file**, `notes/<plugin>-<version>.md`. Its path depends on the
version, which the increment only decides at run time — so the first run prints the plan and the
paths, and the second one releases. That file becomes the commit body, and since no repository in
this family keeps a CHANGELOG, `notes/` is the only place these accumulate.

Before touching anything, a release refuses a repository that is not on `main`, has a dirty tree, or
sits behind its remote — and runs each plugin's own `verify` command. A release nobody tested is the
thing this exists to prevent.

Pushing is separate. A tag on the remote is not withdrawn quietly.
