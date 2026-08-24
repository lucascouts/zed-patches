#!/usr/bin/env bash
# Answer whether every copy of the patch set still agrees with every other.
#
#     check-sync.sh [<PF>]
#
# Three relations, checked in the order a drift would travel:
#
#   1. series  <-> ebuild   the ebuild's PATCHES+=() list against the series
#   2. patches <-> overlay  this repository's files against the overlay's files/
#   3. patches <-> source   every patch still applies to the packaged tree
#
# 1 is the one no other script checks: sync-overlay.sh copies what the series
# names and reports what the overlay has spare, but neither side reads the
# ebuild, so a patch the ebuild stopped applying stays in both and looks fine.
#
# With no <PF>, the version is taken from the overlay when it holds exactly one
# zed ebuild — the common case, and unambiguous when it holds.
#
# Exit: 0 everything agrees · 1 a relation drifted · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s [<PF>]\n' "${0##*/}" >&2
	exit 2
}

DRIFT=0

report() {
	local verdict="$1" label="$2"
	printf '%-8s %s\n' "${verdict}" "${label}"
	[[ "${verdict}" == "ok" ]] || DRIFT=1
}

# _sole_pf — the PF of the only zed ebuild in the overlay, or a refusal naming
# the candidates. Guessing between two ebuilds would pick a version the caller
# did not mean, and a check that silently checks the wrong thing is worse than
# no check.
_sole_pf() {
	local dir="${ZP_OVERLAY}/app-editors/zed"
	local -a found=()
	local f
	for f in "${dir}"/*.ebuild; do
		[[ -e "${f}" ]] || continue
		f="${f##*/}"
		found+=("${f%.ebuild}")
	done
	((${#found[@]} > 0)) || die 2 "no zed ebuild in ${dir}"
	((${#found[@]} == 1)) || die 2 "more than one zed ebuild — name one: ${found[*]}"
	printf '%s' "${found[0]}"
}

# check_ebuild — every patch the ebuild applies is in the series, and vice
# versa. Reads the PATCHES+=() lines, which name files under ${FILESDIR}.
check_ebuild() {
	local -n _series_ref="$1"
	local -a from_ebuild=()
	local line
	while IFS= read -r line; do
		[[ -n "${line}" ]] && from_ebuild+=("${line}")
	done < <(grep -oE '\$\{FILESDIR\}/[^"]+\.patch' "${ZP_EBUILD}" | sed 's|.*/||' | sort -u)

	((${#from_ebuild[@]} > 0)) || {
		report "SKIP" "series <-> ebuild: the ebuild names no \${FILESDIR} patches"
		return 0
	}

	local -a sorted_series=()
	mapfile -t sorted_series < <(printf '%s\n' "${_series_ref[@]}" | sort -u)

	local only_ebuild only_series
	only_ebuild="$(comm -23 <(printf '%s\n' "${from_ebuild[@]}") <(printf '%s\n' "${sorted_series[@]}") | tr '\n' ' ')"
	only_series="$(comm -13 <(printf '%s\n' "${from_ebuild[@]}") <(printf '%s\n' "${sorted_series[@]}") | tr '\n' ' ')"
	only_ebuild="${only_ebuild% }"
	only_series="${only_series% }"

	if [[ -z "${only_ebuild}" && -z "${only_series}" ]]; then
		report "ok" "series <-> ebuild: ${#from_ebuild[@]} patches, both lists agree"
		return 0
	fi
	report "DRIFT" "series <-> ebuild"
	[[ -z "${only_ebuild}" ]] || printf '           applied by the ebuild, absent from the series: %s\n' "${only_ebuild}"
	[[ -z "${only_series}" ]] || printf '           in the series, never applied by the ebuild:    %s\n' "${only_series}"
}

# check_overlay — the series' files, byte for byte, against the overlay's.
check_overlay() {
	local -n _series_ref2="$1"
	local dir="$2"
	local files="${ZP_OVERLAY}/app-editors/zed/files"
	[[ -d "${files}" ]] || {
		report "DRIFT" "patches <-> overlay: no files/ directory at ${files}"
		return 0
	}

	local name differing=0 absent=0
	local -a bad=()
	for name in "${_series_ref2[@]}"; do
		if [[ ! -f "${files}/${name}" ]]; then
			absent=$((absent + 1))
			bad+=("${name} (absent)")
		elif ! cmp -s "${dir}/${name}" "${files}/${name}"; then
			differing=$((differing + 1))
			bad+=("${name} (differs)")
		fi
	done

	local -a orphans=()
	local f base
	for f in "${files}"/*.patch; do
		[[ -e "${f}" ]] || continue
		base="${f##*/}"
		printf '%s\n' "${_series_ref2[@]}" | grep -qxF "${base}" || orphans+=("${base}")
	done

	if ((differing == 0 && absent == 0 && ${#orphans[@]} == 0)); then
		report "ok" "patches <-> overlay: ${#_series_ref2[@]} identical, 0 orphans"
		return 0
	fi
	report "DRIFT" "patches <-> overlay"
	local b
	for b in "${bad[@]}"; do printf '           %s\n' "${b}"; done
	((${#orphans[@]} == 0)) || printf '           in the overlay, not in the series: %s\n' "${orphans[*]}"
}

# check_source — delegate to verify.sh, which owns the dry-run. A tree that was
# never prepared is reported as unchecked, not as a failure: nothing drifted,
# the question simply was not asked.
check_source() {
	local pf="$1" here
	here="$(dirname "${BASH_SOURCE[0]}")"
	if [[ ! -d "${ZP_WORKTREE}" ]]; then
		report "SKIP" "patches <-> source: no prepared tree — run: prepare-tree.sh ${pf}"
		return 0
	fi
	local out status=0
	out="$("${here}/verify.sh" "${pf}" 2>&1)" || status=$?
	if ((status == 0)); then
		report "ok" "patches <-> source: every patch applies to ${ZP_COMMIT:0:12}"
		return 0
	fi
	report "DRIFT" "patches <-> source (verify.sh exited ${status})"
	printf '%s\n' "${out}" | sed 's/^/           /'
}

main() {
	local pf="" arg
	for arg in "$@"; do
		case "${arg}" in
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and ${arg}"
			pf="${arg}"
			;;
		esac
	done

	if [[ -z "${pf}" ]]; then
		ZP_OVERLAY="$(_zp_overlay)"
		pf="$(_sole_pf)"
	fi
	resolve_version "${pf}"

	local dir="${ZP_REPO}/patches/${ZP_PV}"
	local series="${dir}/series"
	[[ -f "${series}" ]] || die 2 "no series for ${ZP_PV}: ${series}"

	local listing status=0
	listing="$(read_series "${series}")" || status=$?
	((status == 0)) || exit "${status}"
	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"
	((${#patches[@]} > 0)) || die 2 "the series selected no patches (series: ${series})"

	printf 'checking %s\n' "${ZP_PV}"
	printf '  patches  %s\n' "${dir}"
	printf '  overlay  %s\n\n' "${ZP_OVERLAY}"

	check_ebuild patches
	check_overlay patches "${dir}"
	check_source "${ZP_PV}"

	printf '\n'
	if ((DRIFT == 0)); then
		printf 'in sync\n'
		return 0
	fi
	printf 'out of sync — see the lines marked DRIFT above\n'
	return 1
}

main "$@"
