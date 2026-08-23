#!/usr/bin/env bash
# Copy the verified patch series into the bentoo overlay.
#
#     sync-overlay.sh <PF> [--dry-run]
#
# Verification is a gate, not a suggestion: verify.sh runs first and its status is
# propagated, so files/ can never receive a patch nobody checked. Writes are scoped
# to app-editors/zed/files/ and only to files the series names -- the ebuild's
# PATCHES+=() blocks encode USE logic no copy step can infer, and are never touched.
#
# Exit: 0 synchronized · verify.sh's status when verification fails · 2 environment
# problem. Orphans never change the exit status.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s <PF> [--dry-run]\n' "${0##*/}" >&2
	exit 2
}

main() {
	local pf="" dry="no" arg
	for arg in "$@"; do
		case "${arg}" in
		--dry-run) dry="yes" ;;
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

	local here patch_dir series files_dir
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	patch_dir="${ZP_REPO}/patches/${ZP_PV}"
	series="${patch_dir}/series"
	files_dir="${ZP_OVERLAY}/${ZP_CATEGORY_PATH}/files"

	[[ -f "${series}" ]] || die 2 "no series for ${ZP_PV}: ${series}"
	[[ -d "${files_dir}" ]] || die 2 "no overlay patch directory: ${files_dir}"

	# --- the gate ------------------------------------------------------------
	local verify_out verify_status=0
	verify_out="$("${here}/verify.sh" "${ZP_PV}" 2>&1)" || verify_status=$?
	if ((verify_status != 0)); then
		printf '%s\n' "${verify_out}" >&2
		die "${verify_status}" "verification failed for ${ZP_PV} (status ${verify_status}) — nothing was copied"
	fi
	printf '%s\n\n' "${verify_out}"

	local listing status=0
	listing="$(read_series "${series}")" || status=$?
	((status == 0)) || exit "${status}"
	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"

	# --- copy ----------------------------------------------------------------
	if [[ "${dry}" == "yes" ]]; then
		printf 'dry run: %s -> %s (nothing will be written)\n' "${patch_dir}" "${files_dir}"
	else
		printf 'syncing %s -> %s\n' "${patch_dir}" "${files_dir}"
	fi

	local name target state added=0 changed=0 identical=0
	for name in "${patches[@]}"; do
		target="${files_dir}/${name}"
		if [[ ! -f "${target}" ]]; then
			state="added"
			added=$((added + 1))
		elif cmp -s "${patch_dir}/${name}" "${target}"; then
			state="identical"
			identical=$((identical + 1))
		else
			state="changed"
			changed=$((changed + 1))
		fi
		printf '  %-10s %s\n' "${state}" "${name}"
		if [[ "${dry}" == "no" && "${state}" != "identical" ]]; then
			cp -p "${patch_dir}/${name}" "${target}"
		fi
	done
	printf '%d added, %d changed, %d already identical\n' "${added}" "${changed}" "${identical}"

	# --- orphans -------------------------------------------------------------
	# A patch in files/ that the series does not name is reported, never deleted:
	# the ebuild may still reference it, and that is a decision, not a cleanup.
	local -a orphans=()
	local candidate base known
	for candidate in "${files_dir}"/*.patch; do
		[[ -e "${candidate}" ]] || continue
		base="${candidate##*/}"
		known="no"
		for name in "${patches[@]}"; do
			[[ "${base}" == "${name}" ]] && {
				known="yes"
				break
			}
		done
		[[ "${known}" == "yes" ]] || orphans+=("${base}")
	done

	if ((${#orphans[@]} == 0)); then
		printf '0 orphans in %s\n' "${files_dir}"
	else
		printf '\n%d orphan(s) in %s — left in place; the ebuild may still reference them:\n' \
			"${#orphans[@]}" "${files_dir}"
		for base in "${orphans[@]}"; do
			printf '  orphan     %s\n' "${base}"
		done
	fi
}

main "$@"
