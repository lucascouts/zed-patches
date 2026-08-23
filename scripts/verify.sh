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
