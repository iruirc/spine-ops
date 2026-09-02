# spine-ops

[![license](https://img.shields.io/github/license/iruirc/spine-ops?color=555)](LICENSE)
[![last commit](https://img.shields.io/github/last-commit/iruirc/spine-ops?label=last%20commit&color=888)](https://github.com/iruirc/spine-ops/commits/main)

Maintenance for the `spine-toolkit` family: the plugins, and the marketplace that lists them.

| Repository | Released | License | Last commit | What it is |
|---|---|---|---|---|
| [**spine-toolkit**](https://github.com/iruirc/spine-toolkit) | [![](https://img.shields.io/github/v/tag/iruirc/spine-toolkit?sort=semver&label=&color=0969da)](https://github.com/iruirc/spine-toolkit/tags) | ![](https://img.shields.io/github/license/iruirc/spine-toolkit?label=&color=555) | ![](https://img.shields.io/github/last-commit/iruirc/spine-toolkit?label=&color=888) | the orchestrator, and no language of its own |
| [**swift-platform**](https://github.com/iruirc/swift-platform) | [![](https://img.shields.io/github/v/tag/iruirc/swift-platform?sort=semver&label=&color=0969da)](https://github.com/iruirc/swift-platform/tags) | ![](https://img.shields.io/github/license/iruirc/swift-platform?label=&color=555) | ![](https://img.shields.io/github/last-commit/iruirc/swift-platform?label=&color=888) | Swift and Apple knowledge, nine agents, the manifest core dispatches through |
| [**claude-marketplace**](https://github.com/iruirc/claude-marketplace) | [![](https://img.shields.io/github/v/tag/iruirc/claude-marketplace?sort=semver&label=&color=0969da)](https://github.com/iruirc/claude-marketplace/tags) | ![](https://img.shields.io/github/license/iruirc/claude-marketplace?label=&color=555) | ![](https://img.shields.io/github/last-commit/iruirc/claude-marketplace?label=&color=888) | the catalogue users add, and the only roster of what exists |

Those badges read the remote, so they say what is **published**. `scripts/status.sh` reads this disk
and says what is **here** — the two disagree exactly while something is committed and not yet pushed,
which is the window `scripts/push.sh` closes.

It carries no version and no tags of its own: it releases the three above rather than itself. What
it keeps instead is `notes/`, where the body of every release it has written stays after the commit
that used it.

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

## First run on a machine

Clone all four as siblings; `repos.json` addresses the others relatively, so nothing else needs
configuring. `jq` and `python3` are the only requirements.

```
git clone git@github.com:iruirc/spine-ops.git
scripts/check.sh          # says at once whether the layout is right
```

## Commands

Every command takes `-h`. The two read-only ones take nothing else.

| | | |
|---|---|---|
| `scripts/status.sh` | — | one table: version, highest tag, branch, ahead/behind, tree, and unreleased commits |
| `scripts/check.sh` | — | the invariants nobody was checking. Exit 0 clean, 1 on a breach — the one to run in a hook or before a release |
| `scripts/release.sh` | `<targets…> [--dry-run]` | bump, commit, tag. Stops there. Exit 2 means the release notes are missing and names them |
| `scripts/push.sh` | `[--dry-run]` | publish what release prepared: commits and tags, per repository |

Two files under `scripts/` are not commands:

- `lib.sh` — sourced by all four: the config, the roster, semver, the git guards. Never executed.
- `set-version.py` — rewrites one `"version"` line in place. A `jq` round-trip would reformat these
  manifests, and a release diff has to show one changed line rather than a reflow. Called by
  `release.sh`; usable alone as `set-version.py FILE 1.4.0 [--plugin NAME]`.

## repos.json

```json
{
  "marketplace": { "path": "../claude-marketplace" },
  "checkouts": {
    "spine-toolkit": { "path": "../spine-toolkit", "verify": "scripts/test-foundation.sh" }
  }
}
```

`path` is relative to this repository. `verify` runs from the checkout's own root and must exit 0
for that plugin to be released; leave it out and the release says the plugin was not verified rather
than pretending it was. Which plugins exist is not written here — see above.

## Releasing

```
scripts/release.sh minor                        every repo with work since its last tag
scripts/release.sh minor swift-platform=patch   same, one overridden
scripts/release.sh spine-toolkit=minor          only that one
scripts/release.sh spine-toolkit=1.3.0          an explicit version
scripts/release.sh minor --dry-run              the plan, the guards, and nothing else
```

The marketplace is never released alone and never skipped: any plugin bump rewrites its listing, so
it goes along at the highest increment of the release unless `marketplace=<kind|version>` says
otherwise. A version named outright is measured against the current one for its increment, so
`spine-toolkit=1.4.0` and `spine-toolkit=minor` reach the same marketplace version — how you spell a
release never changes where it lands.

**The release body of each plugin is a file**, `notes/<plugin>-<version>.md`. Its path depends on the
version, which the increment only decides at run time — so the first run prints the plan and the
paths, and the second one releases. That file becomes the commit body, and since no repository in
this family keeps a CHANGELOG, `notes/` is the only place these accumulate.

Before touching anything, a release refuses a repository that is not on `main`, has a dirty tree, or
sits behind its remote — and runs each plugin's own `verify` command. A release nobody tested is the
thing this exists to prevent.

Pushing is separate. A tag on the remote is not withdrawn quietly.
