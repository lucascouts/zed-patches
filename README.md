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
| `ZP_OVERLAY` | the `bentoo` repository reported by `portageq get_repo_path / bentoo` |
| `ZP_DISTDIR` | `portageq distdir`, falling back to `/var/cache/distfiles` |
| `ZP_WORKROOT` | `<repo>/work` |
| `ZP_REPO` | the repository root |

## Requirements

`tar`, `patch`, `git`, `portageq` and `shellcheck` — all part of a normal Gentoo system.
No new dependency is introduced: `quilt` is deliberately absent.

## Scope

Local repository, no remote. Publication is a later decision.
