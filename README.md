# zed-patches

Source of truth for the downstream patches the `bentoo` overlay applies to
`app-editors/zeo`, plus the tooling that answers one question mechanically:

> **Do the patches still apply to the packaged source?**

Before this repository the patches lived only in `app-editors/zed/files/`, and the
only way to validate a version bump was to start a compile and watch it fail.

**The series moved from `app-editors/zed` to `app-editors/zeo` on 2026-10-01.** Since
then `zed` builds upstream's tagged releases with no patches, and the snapshot plus
this series ships as Zeo — rebranded, versioned on its own (`0.1.0_p<date>`), and
also prebuilt as `zeo-bin`. Directories under `patches/` named `zed-*` are the history
from before the move; new ones are named after the Zeo `PF`.

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
| `scripts/bump.sh [--from <PF>] [--to <PF>] [--apply]` | carry the series onto the version the overlay now packages: refresh, verify, sync, check — stopping at the ebuild |
| `scripts/prepare-tree.sh <PF> [--force]` | extract the Zed distfile the ebuild's `SRC_URI` names (`zed-<commit>.tar.gz` for zeo) into `work/zed-<commit>/` and give it a baseline commit |
| `scripts/verify.sh <PF> [--feature=<flag>]` | apply the whole series cumulatively, in a throwaway worktree cut from the prepared tree's baseline -- never in the tree itself |
| `scripts/sync-overlay.sh <PF> [--dry-run]` | copy the verified series into the overlay's `files/`, reporting orphans |
| `scripts/refresh.sh --from <PF_old> --to <PF_new>` | carry the series onto a new packaged commit, regenerating each patch |
| `scripts/check-sync.sh [<PF>]` | verify the series against the ebuild, the overlay and the packaged source, in one pass |
| `scripts/release-portable.sh <PF> [--skip-build] [--no-flatpak]` | the release build since `-r2`: compile the series in a Debian 12 container and package `zeo-bin`, `.deb`, `.rpm`, AppImage, Flatpak and a tarball; never uploads — see [Releasing zeo-bin](#releasing-zeo-bin) |
| `scripts/release-zeo-bin.sh <PF> [--fresh]` | the Gentoo-host `zeo-bin` build used up to `-r1`, unprivileged: compile and install under `release/configroot`, then `make-bin-release.sh` |
| `scripts/make-bin-release.sh <PF> <builddir>` | package a finished `x86-64-v3` build of zeo as the `zeo-bin` distfile, with `PROVENANCE.txt`; refuses a non-portable binary and never uploads — see [Releasing zeo-bin](#releasing-zeo-bin) |
| `scripts/patch-branches.sh <PF> [--force]` | rebuild one branch per patch in the prepared tree, so a patch can be fixed as code |
| `scripts/selftest.sh` | unit coverage, entirely on temporary fixtures — never touches the overlay or the real distfile |
| `scripts/live-proof.py script <steps.json>` | drive a running Zed through the desktop portal and capture what a patch renders — the half `verify.sh` cannot answer |
| `scripts/kwin-window.sh active\|list\|focus\|desktop\|setdesktop` | query or switch KWin windows and virtual desktops without injecting input |

Exit codes are uniform: `0` success · `1` a patch did not apply · `2` environment
problem (missing distfile, missing tree, unparseable ebuild, malformed series).

### Proving a patch in a running editor

`verify.sh` proves a patch *applies*; `live-proof.py` proves it *renders*. It is
the only script here that touches the desktop, so it carries guards the others do
not need:

- **It refuses to inject into the window hosting the session that calls it.** When
  the agent runs inside the Zed being driven — which it does, through the ACP
  adapter — an unguarded keystroke lands in its own composer.
- **It refuses to run against a locked session**, and **verifies every capture
  decodes at a sane size**. Both come from `zeo`'s `scripts/shot.sh`, which found
  the first the hard way: a locked session yields perfectly well-formed pictures
  of nothing. A 1x1 PNG once sat among committed proofs looking exactly like
  evidence.
- **Windows are matched by project, never by caption.** A caption is
  `<project> — <open file>` and the file half changes when a tab does.

Captures belong under `docs/assets/` in the orchestration repository, versioned
beside the report that cites them — never under `.epic/`, which is gitignored, and
where evidence commits are silent no-ops.

`EGIT_COMMIT` is always parsed from the ebuild, never hardcoded — the ebuild is the one
place that already knows which commit is packaged.

## Workflow for a version bump

Once Portage has fetched the new distfile and the overlay carries the new ebuild:

```sh
scripts/bump.sh            # refresh, verify, sync (dry run), check — writes nothing
scripts/bump.sh --apply    # the same, and the sync writes for real
```

Both versions are discovered when not given: `--to` from the overlay's single zed
ebuild, `--from` as the newest series in `patches/` that is not `--to`. Each step gates
the next, so a run either reaches the end or stops where a human is needed.

**It never edits the ebuild.** Which patches apply, and under which USE flag, is the one
part of a bump encoding intent no script can infer. When the refreshed series stops
matching `PATCHES+=()`, `bump.sh` says exactly that and exits 1 — the handoff, not a
failure.

The steps individually, which is also what to reach for when a run stops:

```sh
# 1. Regenerate. Stops at the first conflict, keeping the .rej files: a patch that no
#    longer applies is a decision, not a mechanical fix. See "Fixing a patch as code".
scripts/refresh.sh --from zed-1.18.0_pre20260822 --to zed-1.19.0_pre20260901

# 2. Confirm the regenerated set applies, from a restored baseline.
scripts/verify.sh zed-1.19.0_pre20260901

# 3. Copy into the overlay. Verification runs again here as a gate.
scripts/sync-overlay.sh zed-1.19.0_pre20260901 --dry-run
scripts/sync-overlay.sh zed-1.19.0_pre20260901

# 4. Update PATCHES+=() by hand, then confirm all three relations agree.
scripts/check-sync.sh zed-1.19.0_pre20260901
```

`bump.sh` re-running `verify` inside `sync-overlay.sh` is deliberate duplication: the
sync's own gate is what guarantees `files/` never receives an unchecked patch, and
skipping it to save one `patch` run would trade that guarantee for nothing.

Step 3 works straight after step 1 because `verify.sh` never reads the prepared
tree's working files. It cuts a throwaway worktree from that tree's baseline
commit and applies the series there, for real and in order. `refresh.sh` finishes
with one commit per patch in the prepared tree, and checking against that would be
checking the series against its own output -- cutting from the baseline sidesteps
that entirely, and the prepared tree's build output is never in reach of a patch.

Applying **cumulatively** is the point of the exercise. Each patch is handed the
source with every earlier one already in place, which is how `eapply` will read it.
Checking each patch against pristine source answers a weaker question, and on a
stacked pair it can report a false pass or a false failure. This series has such a
pair: `0010` expects the hunks `0007` adds.

`verify.sh` still puts the prepared tree back on its baseline, because the rest of
the tooling expects to find it there. The restore moves `HEAD` only: the refresh
commits stay on their branch, so `patch-branches.sh` and a half-finished fix survive
it. Uncommitted edits to tracked files are the one thing it will not touch -- those
exit 2 and name the way out, because discarding somebody's work to answer a question
is never worth it.

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

With no `<PF>` the version comes from the overlay when it holds exactly one zeo
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

## Releasing zeo-bin

`zeo-bin` is the same Zed commit and patch series as `zeo` at the same `PV`, compiled
once here and published as an asset of the Zeo GitHub release tagged `v<PVR>`
([`zeo-workspace/zeo` releases](https://github.com/zeo-workspace/zeo/releases)), beside
its `PROVENANCE` and `SHA256SUMS`; the `zeo-bin` ebuild's `SRC_URI` points there. Until
2026-10-03 the tarballs were served from the overlay's R2 bucket
(`distfiles.obentoo.org`), which still holds the three published before the move.

### Since `-r2`: the portable build

```bash
scripts/release-portable.sh <PF>                # build + package everything
scripts/release-portable.sh <PF> --skip-build   # repackage the staged tree
scripts/release-portable.sh <PF> --no-flatpak   # skip the host flatpak-builder step
```

It compiles inside `release/portable/Containerfile` — Debian 12 (glibc 2.36), the
official `rustup` toolchain the Zed commit pins, `x86-64-v3` — and writes to
`${ZP_PORTABLE_DIR:-~/.cache/zeo-portable}/<PF>/out/dist`: the `zeo-bin` tarball under
the name and layout the ebuild unpacks, a plain tarball, `.deb`, `.rpm`, AppImage,
Flatpak bundle and `SHA256SUMS-portable-<PVR>`. Before packaging it refuses a binary
needing a glibc newer than 2.36 or carrying compiler-generated AVX-512, and writes
`PROVENANCE.txt` naming the real toolchain.

**Why `zeo-bin` moved here.** Every `zeo-bin` up to `-r1` can die with *illegal
instruction* on an `x86-64-v3` CPU without AVX-512: this host's Rust standard library is
built for `znver5`, and the precompiled `std` ignores the `RUSTFLAGS` of the build, so
`-r1` carried 85 AVX-512 functions. The check meant to refuse that never worked —
`objdump | grep -q` under `pipefail` exited 141 from `SIGPIPE`, which read as "no
match". Both scanners now read the whole disassembly and only flag Rust/C++ symbols:
hand-written assembly kernels (dav1d, aws-lc) pick their AVX-512 path at run time and
are fine.

**Caches.** `<PF>/work/` holds one version's source and target. `sccache/` and
`cargo-home/` beside it are shared by every version, so a new version starts warm and
downloads no crate twice. Measured on `-r2` with an empty target: 16m42s cold, 5m44s
warm, 99.9 % sccache hits. It is a cache of its own, not Portage's
`/var/cache/sccache`: sccache keys each entry on the exact `rustc`, so the Gentoo
compiler's entries can never hit this toolchain — and they are mode 0600, owned by
`portage`, unreadable from here anyway.

### Up to `-r1`: the Gentoo-host build

The host's own `make.conf` targets `znver5` and *appends* that to any `RUSTFLAGS`
passed on the command line, so this build runs under the versioned
`release/configroot/` instead, which targets `x86-64-v3`. No root is needed: `ebuild`
runs unprivileged here. It is kept as a second route, but see above: the `std` it links
is still the host's.

```bash
scripts/release-zeo-bin.sh <PF>           # build (reused if present) + package
scripts/release-zeo-bin.sh <PF> --fresh   # discard the previous build first
```

### Publishing, either way

The tarball is `zeo-bin-<PVR>-amd64.tar.xz` — the zeo revision stays in the name, since
a revbump is a different binary. Once published, its bytes are fixed, because the
`zeo-bin` Manifest pins them: `make-bin-release.sh` compares its output with what the
`v<PVR>` release already serves and refuses different bytes; `release-portable.sh` does
not, so compare `sha256sum` with the served asset by hand before any re-upload. The
release steps: tag `v<PVR>` in this repository (on the commit holding
`patches/<PF>/`) and in `zeo`, then `gh release create` with the assets. Publishing
waits for an explicit go-ahead every time. Then the `zeo-bin` ebuild's `Manifest` is
regenerated against the published file. The archives are deterministic — the same
build gives the same sha256 — so a rerun does not invalidate a Manifest already made
from it.

What this does not prove: the binary has never run on a CPU below this host's. Its
portability rests on the flags and on the absence of compiler-generated AVX-512, not on
an execution.
