#!/usr/bin/env bash
# Materialize the packaged Zed source tree for one version.
#
#     prepare-tree.sh <PF> [--force]
#
# Extracts ${DISTDIR}/<PF>.tar.gz into <workroot>/zed-<EGIT_COMMIT>/ and gives it
# a baseline commit, so any later edit can be regenerated as a patch and the
# untouched source restored. The distfile is the one Portage already fetched and
# checksummed: nothing here downloads.
#
# Exit: 0 prepared or reused · 2 environment problem · tar's own status if the
# archive cannot be unpacked.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASELINE_NAME="zed-patches"
BASELINE_EMAIL="zed-patches@localhost"

usage() {
	printf 'usage: %s <PF> [--force]\n' "${0##*/}" >&2
	exit 2
}

# tree_has_baseline <dir> — true when the tree carries its own baseline commit,
# which is what makes it complete rather than half-extracted.
tree_has_baseline() {
	local tree="$1"
	[[ -d "${tree}/.git" ]] || return 1
	git -C "${tree}" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# write_baseline <dir> — git-init the tree and commit it once. Identity and diff
# format are set locally so the result does not depend on the user's global config.
write_baseline() {
	local tree="$1"
	git -C "${tree}" init -q
	git -C "${tree}" config user.name "${BASELINE_NAME}"
	git -C "${tree}" config user.email "${BASELINE_EMAIL}"
	git -C "${tree}" config commit.gpgsign false
	git -C "${tree}" config diff.noprefix false
	# -f so an upstream .gitignore cannot leave part of the source unrecorded:
	# a baseline that does not hold every file cannot regenerate every patch.
	git -C "${tree}" add -A -f
	git -C "${tree}" commit -q -m "baseline: ${ZP_PV} (${ZP_COMMIT})"
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

	[[ -f "${ZP_DISTFILE}" ]] ||
		die 2 "no distfile for ${ZP_PV}: ${ZP_DISTFILE} (let Portage fetch it; this script never downloads)"

	# Reuse before touching the archive: re-extraction is the expensive path.
	if [[ "${force}" == "no" ]] && tree_has_baseline "${ZP_WORKTREE}"; then
		printf 'reusing the prepared tree at %s (pass --force to re-extract)\n' "${ZP_WORKTREE}"
		return 0
	fi

	# Validate the archive's root against the packaged commit BEFORE creating
	# anything: an archive that unpacks somewhere else would silently have every
	# later check run against the wrong source.
	local first root
	first="$(tar -tzf "${ZP_DISTFILE}" 2>/dev/null | head -n1 || true)"
	[[ -n "${first}" ]] || die 2 "cannot read the archive: ${ZP_DISTFILE}"
	root="${first%%/*}"
	[[ "${root}" == "zed-${ZP_COMMIT}" ]] ||
		die 2 "archive root is '${root}', expected 'zed-${ZP_COMMIT}' as declared by ${ZP_EBUILD} — extracting nothing"

	rm -rf "${ZP_WORKTREE}"
	mkdir -p "${ZP_WORKROOT}"

	local status=0
	printf 'extracting %s -> %s\n' "${ZP_DISTFILE}" "${ZP_WORKTREE}"
	tar -xzf "${ZP_DISTFILE}" -C "${ZP_WORKROOT}" || status=$?
	if ((status != 0)); then
		rm -rf "${ZP_WORKTREE}"
		die "${status}" "tar failed with status ${status} unpacking ${ZP_DISTFILE} — no tree left behind"
	fi

	[[ -d "${ZP_WORKTREE}" ]] ||
		die 2 "the archive did not produce ${ZP_WORKTREE}"

	write_baseline "${ZP_WORKTREE}"
	printf 'prepared %s at %s\n' "${ZP_PV}" "${ZP_WORKTREE}"
}

main "$@"
