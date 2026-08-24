#!/usr/bin/env bash
# Answer whether the patch series still applies to the packaged source.
#
#     verify.sh <PF> [--feature=<use-flag>]
#
# This is the sequential dry-run the overlay's own note asks for on every bump.
# Each patch is checked in series order with the flags eapply itself uses
# (patch -p1 -f -g0) plus --dry-run, so the prepared tree is never written to:
# immutability here is by construction, not by cleanup.
#
# Exit: 0 every patch applies · 1 a patch did not apply · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s <PF> [--feature=<use-flag>]\n' "${0##*/}" >&2
	exit 2
}

# restore_baseline <tree> -- put the tree back on its baseline commit when doing
# so discards nothing.
#
# A dry-run only answers the question that was asked when the source it reads is
# the packaged source. refresh.sh finishes with one commit per patch in the tree,
# so a verify run straight after it -- the sequence the workflow documents --
# would check the series against source that already carries it and report a
# conflict describing nothing but the leftover state. Moving HEAD back to the
# baseline restores the packaged files; the later commits stay reachable from the
# branch they were made on, so patch-branches.sh and a half-finished fix survive.
#
# Uncommitted work is a different matter and is never touched: a tree someone is
# still editing is a decision, so this refuses and names the way out.
restore_baseline() {
	local tree="$1" baseline head dirty
	[[ -d "${tree}/.git" ]] || return 0
	head="$(git -C "${tree}" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 0
	[[ -n "${head}" ]] || return 0
	baseline="$(git -C "${tree}" rev-list --max-parents=0 HEAD 2>/dev/null | tail -n1)"
	[[ -n "${baseline}" ]] || return 0

	# Tracked-file edits are checked first and on every run, baseline or not:
	# source somebody is midway through editing invalidates the dry-run exactly
	# as leftover commits do, and is the one state that must never be discarded.
	# Untracked files are left out -- .rej leftovers and a cargo target/ do not
	# change what a patch reads.
	dirty="$(git -C "${tree}" status --porcelain --untracked-files=no 2>/dev/null)"
	[[ -z "${dirty}" ]] ||
		die 2 "the prepared tree at ${tree} carries uncommitted changes, so a dry-run there would not describe the packaged source -- commit them, or re-extract with: prepare-tree.sh ${ZP_PV} --force"

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
		output="$(cd "${ZP_WORKTREE}" && patch -p1 -f -g0 --dry-run <"${patch_dir}/${name}" 2>&1)" || rc=$?
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
		printf '\nall %d patches in feature group %s apply\n' "${total}" "${feature}"
	else
		printf '\nall %d patches apply\n' "${total}"
	fi
}

main "$@"
