#!/usr/bin/env bash
# Answer whether the patch series still applies to the packaged source.
#
#     verify.sh <PF> [--feature=<use-flag>]
#
# The series is applied CUMULATIVELY, in series order, with the flags eapply
# itself uses (patch -p1 -f -g0). Each patch therefore reads the source as the
# ebuild will hand it over, with every earlier patch already in place.
#
# That is the whole point. Checking each patch against the pristine source
# instead answers a weaker question, and on a stacked series -- one patch
# building on a file an earlier one already changed -- it can report either a
# false failure or a false pass. This series has such a pair: 0010 expects the
# hunks 0007 added, and against pristine source it only "passes" because
# patch -f absorbs their absence with fuzz.
#
# Application is real, not a dry run, and happens in a throwaway git worktree
# cut from the prepared tree's baseline commit. The prepared tree is never
# written to: immutability there is by construction, and the Rust build output
# it carries -- tens of gigabytes -- is never in reach of a patch or a cleanup.
#
# Exit: 0 every patch applies · 1 a patch did not apply · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s <PF> [--feature=<use-flag>]\n' "${0##*/}" >&2
	exit 2
}

# discard_scratch <prepared-tree> <scratch> -- remove the throwaway worktree.
#
# Runs from a trap, so it must stay silent and must not fail: a cleanup that
# dies takes the exit status of the verification with it.
discard_scratch() {
	local tree="$1" scratch="$2"
	[[ -n "${scratch}" && -d "${scratch}" ]] || return 0
	if [[ -d "${scratch}/tree" ]]; then
		git -C "${tree}" worktree remove --force "${scratch}/tree" >/dev/null 2>&1 || true
	fi
	rm -rf "${scratch}"
	git -C "${tree}" worktree prune >/dev/null 2>&1 || true
	return 0
}

# restore_baseline <tree> -- put the tree back on its baseline commit when doing
# so discards nothing, and refuse outright when somebody is mid-edit in it.
#
# The verification itself no longer depends on this: it reads the baseline
# commit through a scratch worktree, so whatever HEAD happens to be does not
# change the answer. Two things still earn it its place.
#
# refresh.sh finishes with one commit per patch in the tree, and the documented
# workflow runs a sync straight afterwards; the rest of the tooling -- and the
# README -- expect to find the prepared tree sitting on its baseline. Moving
# HEAD back keeps that promise. The later commits stay reachable from the branch
# they were made on, so patch-branches.sh and a half-finished fix survive.
#
# Uncommitted work is the other, and it is never touched. Verifying the baseline
# while somebody is midway through editing a patch would answer a question they
# did not ask, and answer it green. This refuses instead, and names the way out.
restore_baseline() {
	local tree="$1" baseline head dirty
	[[ -d "${tree}/.git" ]] || return 0
	head="$(git -C "${tree}" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 0
	[[ -n "${head}" ]] || return 0
	baseline="$(git -C "${tree}" rev-list --max-parents=0 HEAD 2>/dev/null | tail -n1)"
	[[ -n "${baseline}" ]] || return 0

	# Tracked-file edits are checked first and on every run, baseline or not:
	# source somebody is midway through editing invalidates the answer exactly
	# as leftover commits do, and is the one state that must never be discarded.
	# Untracked files are left out -- .rej leftovers and a cargo target/ do not
	# change what a patch reads.
	dirty="$(git -C "${tree}" status --porcelain --untracked-files=no 2>/dev/null)"
	[[ -z "${dirty}" ]] ||
		die 2 "the prepared tree at ${tree} carries uncommitted changes, so a verification there would not describe the packaged source -- commit them, or re-extract with: prepare-tree.sh ${ZP_PV} --force"

	[[ "${head}" != "${baseline}" ]] || return 0

	git -C "${tree}" checkout -q --detach "${baseline}" ||
		die 2 "cannot restore the baseline commit in ${tree} -- re-extract with: prepare-tree.sh ${ZP_PV} --force"
	printf 'restored the baseline commit in %s (later commits are untouched on their branch)\n\n' "${tree}"
}

main() {
	local pf="" feature="" arg
	for arg in "$@"; do
		case "${arg}" in
		--feature=*) feature="${arg#--feature=}" ;;
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and ${arg}"
			pf="${arg}"
			;;
		esac
	done
	[[ -n "${pf}" ]] || usage
	[[ "${feature}" != "" || "$*" != *--feature=* ]] || die 2 "--feature needs a use-flag name"

	resolve_version "${pf}"

	local patch_dir="${ZP_REPO}/patches/${ZP_PV}"
	local series="${patch_dir}/series"
	[[ -f "${series}" ]] || die 2 "no series for ${ZP_PV}: ${series}"

	[[ -d "${ZP_WORKTREE}" ]] ||
		die 2 "no prepared tree at ${ZP_WORKTREE} — run: prepare-tree.sh ${ZP_PV}"

	restore_baseline "${ZP_WORKTREE}"

	# read_series validates the whole series and dies 2 on a missing file or an
	# unknown feature group, before any patch is read.
	local listing status=0
	listing="$(read_series "${series}" "${feature}")" || status=$?
	((status == 0)) || exit "${status}"

	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"
	((${#patches[@]} > 0)) || die 2 "the series selected no patches (series: ${series})"

	# The scratch tree is cut from the baseline commit, so it holds the packaged
	# source and nothing else -- no build output, no leftover refresh commits.
	local baseline
	baseline="$(git -C "${ZP_WORKTREE}" rev-list --max-parents=0 HEAD 2>/dev/null | tail -n1)" || baseline=""
	[[ -n "${baseline}" ]] ||
		die 2 "the prepared tree at ${ZP_WORKTREE} has no baseline commit to verify against — re-extract with: prepare-tree.sh ${ZP_PV} --force"

	# Kept beside the prepared tree rather than in TMPDIR: same filesystem, and
	# work/ is already the disposable area. /tmp is tmpfs on this class of host,
	# where a checkout of the source would be held in RAM.
	local scratch
	mkdir -p "${ZP_WORKROOT}"
	scratch="$(mktemp -d "${ZP_WORKROOT}/.verify-XXXXXX")" ||
		die 2 "cannot create a scratch directory under ${ZP_WORKROOT}"
	# Expanded now, deliberately: the trap must hold the paths, not the names of
	# locals that are out of scope by the time it fires.
	# shellcheck disable=SC2064
	trap "discard_scratch '${ZP_WORKTREE}' '${scratch}'" EXIT INT TERM

	git -C "${ZP_WORKTREE}" worktree prune >/dev/null 2>&1 || true
	git -C "${ZP_WORKTREE}" worktree add --detach --quiet "${scratch}/tree" "${baseline}" ||
		die 2 "cannot cut a scratch worktree from ${baseline} in ${ZP_WORKTREE} — re-extract with: prepare-tree.sh ${ZP_PV} --force"

	if [[ -n "${feature}" ]]; then
		printf 'verifying %s, feature group %s, against %s\n\n' "${ZP_PV}" "${feature}" "${ZP_WORKTREE}"
	else
		printf 'verifying %s against %s\n\n' "${ZP_PV}" "${ZP_WORKTREE}"
	fi

	local name output index=0 rc
	local total="${#patches[@]}"
	for name in "${patches[@]}"; do
		index=$((index + 1))
		rc=0
		output="$(cd "${scratch}/tree" && patch -p1 -f -g0 <"${patch_dir}/${name}" 2>&1)" || rc=$?
		if ((rc == 0)); then
			printf 'ok    [%d/%d] %s\n' "${index}" "${total}" "${name}"
		else
			printf 'FAIL  [%d/%d] %s\n' "${index}" "${total}" "${name}"
			printf '\n%s failed at position %d of %d in the series (patch exited %d):\n\n%s\n' \
				"${name}" "${index}" "${total}" "${rc}" "${output}" >&2
			exit 1
		fi
	done

	if [[ -n "${feature}" ]]; then
		printf '\nall %d patches in feature group %s apply, each onto the one before it\n' "${total}" "${feature}"
	else
		printf '\nall %d patches apply, each onto the one before it\n' "${total}"
	fi
}

main "$@"
