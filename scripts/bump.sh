#!/usr/bin/env bash
# Carry the patch series onto the version the overlay now packages.
#
#     bump.sh [--from <PF_old>] [--to <PF_new>] [--apply]
#
# The four steps a version bump has always taken, in order, each gating the next:
#
#   1. refresh      regenerate every patch against the new packaged source
#   2. verify       confirm the regenerated series applies, from a clean baseline
#   3. sync         copy it into the overlay's files/
#   4. check-sync   confirm all three relations agree afterwards
#
# Without --apply, step 3 is a dry run: the run reports what would be copied and
# writes nothing to the overlay. Step 1 does write, but only inside this
# repository, where git can undo it.
#
# What this deliberately does NOT do is edit the ebuild. Which patches apply, and
# under which USE flag, is the one part of a bump that encodes intent no script
# can infer -- so when the refreshed series no longer matches the ebuild's
# PATCHES+=() list, this stops and says so rather than guessing. That is the
# handoff, not a failure.
#
# Versions are discovered when not given: --to from the overlay's single zed
# ebuild, --from as the newest series already in patches/ that is not --to.
#
# Exit: 0 bumped · 1 a step failed or a decision is waiting · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	printf 'usage: %s [--from <PF_old>] [--to <PF_new>] [--apply]\n' "${0##*/}" >&2
	exit 2
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
say() { printf '    %s\n' "$*"; }

from=""
to=""
apply="no"
while (($# > 0)); do
	case "$1" in
		--from) [[ -n "${2:-}" ]] || usage; from="$2"; shift 2 ;;
		--to) [[ -n "${2:-}" ]] || usage; to="$2"; shift 2 ;;
		--apply) apply="yes"; shift ;;
		*) usage ;;
	esac
done

repo="$(cd "${SCRIPTS}/.." && pwd)"
overlay="$(_zp_overlay)"

# --- which versions ----------------------------------------------------------

if [[ -z "${to}" ]]; then
	shopt -s nullglob
	ebuilds=("${overlay}/${ZP_CATEGORY_PATH}"/*.ebuild)
	shopt -u nullglob
	((${#ebuilds[@]} == 1)) || die 2 "expected exactly one zed ebuild in ${overlay}/${ZP_CATEGORY_PATH}, found ${#ebuilds[@]}; name the target with --to"
	to="${ebuilds[0]##*/}"; to="${to%.ebuild}"
fi

[[ -d "${repo}/patches" ]] || die 2 "no patches/ directory in ${repo}"

if [[ -z "${from}" ]]; then
	shopt -s nullglob
	dirs=("${repo}/patches"/*/)
	shopt -u nullglob
	((${#dirs[@]} > 0)) || die 2 "patches/ holds no series to carry forward; name one with --from"
	# Newest first, excluding the target: the source of a refresh must be a
	# series that already exists and is not the one being written.
	from="$(for d in "${dirs[@]}"; do n="${d%/}"; printf '%s\n' "${n##*/}"; done | sort -Vr | grep -v "^${to}$" | head -1 || true)"
	[[ -n "${from}" ]] || die 2 "no series in patches/ other than ${to}; name the source with --from"
fi

step "bump ${from} -> ${to}"
say "overlay   ${overlay}"
say "apply     ${apply}"

if [[ "${from}" == "${to}" ]]; then
	die 2 "--from and --to are both ${to}; a series cannot be refreshed onto itself"
fi

if [[ -d "${repo}/patches/${to}" ]]; then
	say ""
	say "patches/${to} already exists — the refresh was done before."
	say "Skipping step 1; the remaining steps still run and will report the truth."
	skip_refresh="yes"
else
	skip_refresh="no"
fi

# --- 1. refresh --------------------------------------------------------------

step '1/4 refresh — regenerate each patch against the new source'
if [[ "${skip_refresh}" == "yes" ]]; then
	say 'skipped (series already present)'
else
	if ! bash "${SCRIPTS}/refresh.sh" --from "${from}" --to "${to}"; then
		printf '\n\033[1mstopped in refresh.\033[0m A patch no longer applies to %s.\n' "${to}" >&2
		printf 'The .rej files are left in the prepared tree. Resolving a conflict is a\n' >&2
		printf 'decision about the change, not a mechanical fix — see the "Fixing a patch as\n' >&2
		printf 'code" section of the README, which turns each patch back into a commit.\n' >&2
		exit 1
	fi
fi

# --- 2. verify ---------------------------------------------------------------

step '2/4 verify — the whole series against a clean baseline'
bash "${SCRIPTS}/verify.sh" "${to}" || exit 1

# --- 3. sync -----------------------------------------------------------------

if [[ "${apply}" == "yes" ]]; then
	step '3/4 sync — copy the verified series into the overlay'
	bash "${SCRIPTS}/sync-overlay.sh" "${to}" || exit 1
else
	step '3/4 sync — DRY RUN (pass --apply to write)'
	bash "${SCRIPTS}/sync-overlay.sh" "${to}" --dry-run || exit 1
fi

# --- 4. check-sync -----------------------------------------------------------

step '4/4 check-sync — do all three relations agree?'
if bash "${SCRIPTS}/check-sync.sh" "${to}"; then
	printf '\n\033[1mbump complete.\033[0m\n'
	[[ "${apply}" == "yes" ]] || printf 'Nothing was written to the overlay — re-run with --apply.\n'
	exit 0
fi

# check-sync can fail for two unrelated reasons here, and saying the wrong one
# sends the reader to edit a file that is already correct.
#
# In a dry run the overlay was deliberately not written, so "patches <-> overlay"
# drifting is this script's own doing and means nothing about the ebuild. Only a
# "series <-> ebuild" disagreement is the handoff this script exists to stop at.
if bash "${SCRIPTS}/check-sync.sh" "${to}" 2>&1 | grep -q '^DRIFT *series <-> ebuild'; then
	printf '\n\033[1mthe series is ready; the ebuild is not.\033[0m\n'
	printf '\nEdit the PATCHES+=() blocks in:\n  %s/%s/%s.ebuild\n' "${overlay}" "${ZP_CATEGORY_PATH}" "${to}"
	printf '\nso they name exactly what patches/%s/series names, under the same USE\n' "${to}"
	printf 'conditionals. Then re-run this, or check-sync.sh alone, to confirm.\n'
	exit 1
fi

if [[ "${apply}" != "yes" ]]; then
	printf '\n\033[1mthe series is ready; the overlay was not written.\033[0m\n'
	printf '\nThe ebuild and the series agree. What drifted is the overlay copy, which\n'
	printf 'this run deliberately left alone. Re-run with --apply to write it.\n'
	exit 1
fi

printf '\n\033[1mdrift remains after applying — see check-sync.sh above.\033[0m\n'
exit 1
