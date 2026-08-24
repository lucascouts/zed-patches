# zed-patches

Source of truth for the downstream patches the `bentoo` overlay applies to
`app-editors/zed`, plus the tooling that answers one question mechanically:

> **Do the patches still apply to the packaged source?**

Before this repository the patches lived only in `app-editors/zed/files/`, and the
only way to validate a version bump was to start a compile and watch it fail.

## What this repository owns

| Path | Contents |
|---|---|
| `patches/<PF>/` | one directory per packaged version, named exactly as the ebuild's `PF` |
| `patches/<PF>/series` | canonical apply order and USE-flag grouping |
| `patches/<PF>/*.patch` | the patches themselves, byte-identical to what the overlay applies |
| `scripts/` | the tooling described below |

The overlay's `files/` becomes a **generated consumer**: patches are edited here and
copied there. The ebuild keeps deciding *which* patches to apply — its `PATCHES+=()`
blocks and USE conditionals stay hand-maintained and are never written by these scripts.

The Zed source is **never vendored**. Trees are extracted on demand from the tarball
Portage already fetched into `DISTDIR`, into a gitignored `work/`, so the tracked
repository stays well under a megabyte.

## The `series` format

One patch per line, applied top to bottom. Blank lines are ignored. Two comment forms:

```
# @feature: claude-agent-acp-plus
0001-force-enable-claude-agent-acp-plus.patch
# 0003/0004 retired: upstream 950ec79 surfaces option descriptions natively
0005-elicitation-multiline-fields.patch

# @feature: claude-code-ide
0002-claude-code-ide-integration.patch
```

`# @feature: <use-flag>` opens a group and mirrors the ebuild's `src_prepare`
conditionals; the group carries forward until the next declaration. Every other `#`
line is a free comment. Grouping lets verification check one USE combination in
isolation — the default run applies **every** patch, which is the strictest case.

## Scripts

| Command | Purpose |
|---|---|
| `scripts/prepare-tree.sh <PF> [--force]` | extract `${DISTDIR}/<PF>.tar.gz` into `work/zed-<commit>/` and give it a baseline commit |
| `scripts/verify.sh <PF> [--feature=<flag>]` | sequential `patch --dry-run` of the whole series against the prepared tree |
| `scripts/sync-overlay.sh <PF> [--dry-run]` | copy the verified series into the overlay's `files/`, reporting orphans |
| `scripts/refresh.sh --from <PF_old> --to <PF_new>` | carry the series onto a new packaged commit, regenerating each patch |
| `scripts/check-sync.sh [<PF>]` | verify the series against the ebuild, the overlay and the packaged source, in one pass |
| `scripts/patch-branches.sh <PF> [--force]` | rebuild one branch per patch in the prepared tree, so a patch can be fixed as code |
| `scripts/selftest.sh` | unit coverage, entirely on temporary fixtures — never touches the overlay or the real distfile |

Exit codes are uniform: `0` success · `1` a patch did not apply · `2` environment
problem (missing distfile, missing tree, unparseable ebuild, malformed series).

`EGIT_COMMIT` is always parsed from the ebuild, never hardcoded — the ebuild is the one
place that already knows which commit is packaged.

## Workflow for a version bump

```sh
# 1. Portage has fetched the new distfile and the overlay carries the new ebuild.
scripts/refresh.sh --from zed-1.18.0_pre20260822 --to zed-1.19.0_pre20260901

# 2. Resolve any conflict by hand: refresh.sh stops at the first one and keeps
#    the .rej files. A patch that no longer applies is a decision, not a mechanical fix.

# 3. Confirm the regenerated set applies cleanly.
scripts/verify.sh zed-1.19.0_pre20260901

# 4. Push the verified patches into the overlay, then update PATCHES+=() by hand.
scripts/sync-overlay.sh zed-1.19.0_pre20260901 --dry-run
scripts/sync-overlay.sh zed-1.19.0_pre20260901
```

## Environment overrides

Every script resolves its environment through `scripts/lib.sh`, which honours these
overrides (used by `selftest.sh`, and useful for verifying a version whose ebuild is no
longer in the live overlay):

| Variable | Default |
|---|---|
| `ZP_OVERLAY` | the path in `.zp-overlay`, falling back to `portageq get_repo_path / bentoo` |
| `ZP_DISTDIR` | `portageq distdir`, falling back to `/var/cache/distfiles` |
| `ZP_WORKROOT` | `<repo>/work` |
| `ZP_REPO` | the repository root |

### Fixing a patch as code

A patch is a diff, and a diff is an awkward thing to fix: resolving a conflict
means editing context lines by hand and hoping the result still describes the
change.

```bash
scripts/patch-branches.sh <PF>
```

builds one branch per patch in the prepared tree — `patch/0007-manual-mode-badge`
and so on — each a single commit on the packaged source. Check one out, fix it
with the compiler and the tests available, then regenerate:

```bash
cd work/zed-<commit>
git checkout patch/0007-manual-mode-badge
# edit, build, test
git commit --amend
git format-patch -1 --stdout >../../patches/<PF>/0007-manual-mode-badge.patch
```

The branches are not stored. They live in `work/`, which is disposable and
gitignored, and the script rebuilds them from the series on demand — a second
durable copy of the patches would be a second thing to keep in sync.

A patch made with `git format-patch` is replayed with `git am`, so its author,
date and message survive. A patch that arrived as a bare diff becomes a commit
with a bare subject: no branch can invent reasoning nobody wrote down.

### Staying in sync

```bash
scripts/check-sync.sh
```

One pass over the three relations a drift can travel along:

| Relation | Catches |
|---|---|
| series ↔ ebuild | a patch the ebuild applies but the series never names, or the reverse |
| patches ↔ overlay | a patch edited on one side only, and any overlay file the series does not name |
| patches ↔ source | a patch that stopped applying to the packaged tree |

The first is the one no other script checks. `sync-overlay.sh` copies what the
series names and reports what the overlay has spare, but neither side reads the
ebuild — so a patch the ebuild quietly stopped applying stays present in both
and looks correct from either end.

With no `<PF>` the version comes from the overlay when it holds exactly one zed
ebuild. Exit is 0 when everything agrees, 1 on drift, 2 on an environment
problem. `patches ↔ source` reports `SKIP` rather than failing when no tree has
been prepared — nothing drifted, the question simply was not asked.

### `.zp-overlay` — which checkout gets written

The scripts resolve the overlay in this order:

1. `ZP_OVERLAY` in the environment — a one-off override
2. `.zp-overlay` at the repository root — the working overlay for this machine
3. `portageq get_repo_path / bentoo` — Portage's synced copy

Step 2 exists because step 3 is the wrong answer wherever the overlay is edited
somewhere other than `/var/db/repos`. The path `portageq` reports is the copy
Portage **syncs**, which is a generated consumer: a write there is undone by the
next sync, and until then it blocks that sync with local modifications. Only the
operator knows where the real checkout lives, so it is named in a file rather
than guessed.

`.zp-overlay` holds one path; blank lines and `#` comments are ignored. It is
per-machine and gitignored:

```
# The bentoo checkout this machine edits and pushes from.
/home/you/src/bentoo
```

A file naming a path that is not a directory, or naming nothing at all, is an
error with status 2 — never a silent fallback to `portageq`, which would put the
write back on the copy this setting exists to avoid.

## Requirements

`tar`, `patch`, `git`, `portageq` and `shellcheck` — all part of a normal Gentoo system.
No new dependency is introduced: `quilt` is deliberately absent.

## License

MIT — see [`LICENSE`](LICENSE).

**What MIT covers:** everything original to this repository — `scripts/`, the `series`
files and this README.

**What it does not:** the `patches/**/*.patch` files are diffs against
[Zed](https://github.com/zed-industries/zed), so their added and removed lines are
excerpts of Zed's own source and remain under Zed's license (GPL-3.0). The MIT grant
above cannot and does not relicense that material; it applies to the tooling that
manages the patches, not to the upstream code they carry.
