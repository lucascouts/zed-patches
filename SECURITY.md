# Security Policy

This repository is the source of truth for the downstream patches that the `bentoo`
overlay applies to Zed to build Zeo (`app-editors/zeo`, prebuilt as
`app-editors/zeo-bin`), together with the tooling that verifies them and builds the
prebuilt release.

The project-wide policy — supported versions, where a report belongs, how releases
are pinned — is in [`zeo-workspace/zeo`'s SECURITY.md](https://github.com/zeo-workspace/zeo/blob/main/SECURITY.md).
What follows is specific to this repository.

## Reporting a vulnerability

Report privately via GitHub **Private vulnerability reporting** (Security tab →
_Report a vulnerability_) or by email to the maintainer (`lucascs@proton.me`).
Please do not open a public issue for a security report. Name the patch (its file
name under `patches/<PF>/`) or the script involved, the reproduction and the impact.

## What this repository controls

- **The patches.** Each one is a `git format-patch` file against the packaged Zed
  commit, and `scripts/verify.sh` proves the whole series applies, in order, before
  it reaches the overlay. The overlay's copies are generated from here
  (`scripts/sync-overlay.sh`) and `scripts/check-sync.sh` proves they are identical.
- **The prebuilt release.** `scripts/release-zeo-bin.sh` builds `zeo-bin` without
  root under a versioned Portage configuration (`release/configroot`), refuses a
  binary that is not x86-64-v3 or that carries AVX-512 instructions, and writes
  `PROVENANCE.txt` into the tarball. It never uploads: publishing is a separate,
  human-authorised step, after which the `zeo-bin` Manifest pins the checksum.
- **No secrets.** The scripts take credentials from the environment of the person
  running them and never write one to the repository.
