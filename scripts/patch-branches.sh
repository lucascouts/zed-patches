#!/usr/bin/env bash
# Materialise one branch per patch, each a single commit on the packaged source.
#
#     patch-branches.sh <PF> [--force]
#
# A patch is a diff, and a diff is an awkward thing to fix: resolving a conflict
# means editing context lines by hand and hoping the result still describes the
# change. A branch is the same change as code. Check one out, fix it with the
# compiler and the tests available, then regenerate the patch from it.
#
# Nothing here is stored. The branches live in the prepared tree under work/,
# which is disposable and gitignored, and this script rebuilds them from the
# series whenever they are wanted. That is deliberate: a second durable copy of
# the patches would be a second thing to keep in sync, and check-sync.sh already
# has three relations to police.
#
# What it does NOT do is recover intent that was never recorded. Each branch
# carries whatever message its patch file carries — a `From:`/`Subject:` header
# where the patch was made with git format-patch, and a synthesised one where it
# was not. A patch that arrived as a bare diff becomes a commit with a bare
# subject, and no branch can invent the reasoning nobody wrote down.
#
# Exit: 0 every branch built · 1 a patch would not apply · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s <PF> [--force]\n' "${0##*/}" >&2
	exit 2
}

# _branch_name — patches/0007-manual-mode-badge.patch -> patch/0007-manual-mode-badge
_branch_name() {
	local name="${1%.patch}"
	printf 'patch/%s' "${name}"
}

main() {
	local pf="" force="no" arg
	for arg in "$@"; do
		case "${arg}" in
		--force) force="yes" ;;
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and ${arg}"
			pf="${arg}"
			;;
		esac
	done
	[[ -n "${pf}" ]] || usage

	resolve_version "${pf}"

	local dir="${ZP_REPO}/patches/${ZP_PV}"
	local series="${dir}/series"
	[[ -f "${series}" ]] || die 2 "no series for ${ZP_PV}: ${series}"
	[[ -d "${ZP_WORKTREE}" ]] ||
		die 2 "no prepared tree at ${ZP_WORKTREE} — run: prepare-tree.sh ${ZP_PV}"

	local listing status=0
	listing="$(read_series "${series}")" || status=$?
	((status == 0)) || exit "${status}"
	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"
	((${#patches[@]} > 0)) || die 2 "the series selected no patches (series: ${series})"

	# The baseline is the tree's root commit — prepare-tree.sh makes exactly one,
	# and every branch here starts from it rather than from whatever HEAD points
	# at, so a tree left mid-refresh still produces isolated branches.
	local baseline
	baseline="$(git -C "${ZP_WORKTREE}" rev-list --max-parents=0 HEAD)" ||
		die 2 "no baseline commit in ${ZP_WORKTREE} — re-run prepare-tree.sh ${ZP_PV}"

	local -a dirty=()
	mapfile -t dirty < <(git -C "${ZP_WORKTREE}" status --porcelain)
	if ((${#dirty[@]} > 0)) && [[ "${force}" != "yes" ]]; then
		die 2 "the prepared tree has uncommitted changes — commit them, or pass --force to discard"
	fi

	printf 'building %d branches in %s\n' "${#patches[@]}" "${ZP_WORKTREE}"
	printf '  baseline %s\n\n' "${baseline:0:12}"

	local name branch built=0
	for name in "${patches[@]}"; do
		branch="$(_branch_name "${name}")"
		git -C "${ZP_WORKTREE}" checkout -q --force -B "${branch}" "${baseline}"
		git -C "${ZP_WORKTREE}" clean -qfd

		# git am carries the patch's own author, date and message across. A patch
		# with no From:/Subject: header is not an am-able mailbox, so it falls back
		# to a plain apply with a synthesised subject — the same commit, minus the
		# provenance the file never had.
		if git -C "${ZP_WORKTREE}" am -q --keep-non-patch <"${dir}/${name}" 2>/dev/null; then
			printf 'ok    %-56s %s (am)\n' "${branch}" "$(git -C "${ZP_WORKTREE}" rev-parse --short HEAD)"
		else
			git -C "${ZP_WORKTREE}" am -q --abort 2>/dev/null || true
			git -C "${ZP_WORKTREE}" checkout -q --force -B "${branch}" "${baseline}"
			if ! (cd "${ZP_WORKTREE}" && patch -p1 -f -g0 -s <"${dir}/${name}"); then
				printf 'FAIL  %s\n' "${branch}" >&2
				git -C "${ZP_WORKTREE}" checkout -q --force "${baseline}"
				die 1 "${name} did not apply to the baseline — run verify.sh ${ZP_PV}"
			fi
			git -C "${ZP_WORKTREE}" add -A -f -- . ':!*.orig' ':!*.rej'
			git -C "${ZP_WORKTREE}" commit -q -m "${name%.patch}" \
				-m "Reconstructed from ${name}, which carries no commit header."
			printf 'ok    %-56s %s (plain diff — no header in the patch)\n' \
				"${branch}" "$(git -C "${ZP_WORKTREE}" rev-parse --short HEAD)"
		fi
		built=$((built + 1))
	done

	# Leave the tree where every other script expects it: on the baseline, clean.
	git -C "${ZP_WORKTREE}" checkout -q --force "${baseline}"
	git -C "${ZP_WORKTREE}" clean -qfd

	printf '\n%d branches built; tree left on the baseline\n\n' "${built}"
	printf 'to fix a patch as code:\n'
	printf '  git -C %s checkout patch/<name>\n' "${ZP_WORKTREE}"
	printf '  # edit, build, test\n'
	printf '  git -C %s commit --amend\n' "${ZP_WORKTREE}"
	printf '  git -C %s format-patch -1 --stdout >%s/<name>.patch\n' "${ZP_WORKTREE}" "${dir}"
	printf '  scripts/check-sync.sh %s\n' "${ZP_PV}"
}

main "$@"
