#!/usr/bin/env bash
# Shared environment resolution and series parsing for the zed-patches tooling.
#
# Sourced, never executed. Every other script starts with:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Resolution is deliberately implemented with bash builtins only: resolve_version
# must work when no external command is reachable, which is also how the fallback
# to the default DISTDIR is exercised.

set -euo pipefail

# --- constants ---------------------------------------------------------------

ZP_DEFAULT_DISTDIR="/var/cache/distfiles"
ZP_CATEGORY_PATH="app-editors/zed"

# --- diagnostics -------------------------------------------------------------

# die <status> <message...> — report on stderr and leave with <status>.
die() {
	local status="$1"
	shift
	printf 'error: %s\n' "$*" >&2
	exit "${status}"
}

# --- environment resolution --------------------------------------------------

# _zp_repo_root — the repository this script belongs to, via bash builtins only.
_zp_repo_root() {
	local here="${BASH_SOURCE[0]%/*}"
	[[ "${here}" == "${BASH_SOURCE[0]}" ]] && here="."
	(cd "${here}/.." && pwd)
}

# _zp_overlay — the bentoo repository to read from and write to.
#
# Precedence, most explicit first:
#   1. ZP_OVERLAY in the environment — a one-off override
#   2. .zp-overlay at the repository root — the working overlay for this machine
#   3. portageq — Portage's synced copy, the last resort
#
# 2 exists because portageq answers with the repository Portage SYNCS, and that
# copy is a generated consumer, not a place to edit: a write there is undone by
# the next sync, and until then it blocks that sync with local modifications.
# Where the overlay is edited and pushed from a checkout elsewhere, only the
# operator can name that path, so it is read from a file rather than guessed.
_zp_overlay() {
	local path="" config="" line=""
	if [[ -n "${ZP_OVERLAY:-}" ]]; then
		printf '%s' "${ZP_OVERLAY}"
		return 0
	fi
	config="${ZP_REPO:-$(_zp_repo_root)}/.zp-overlay"
	if [[ -r "${config}" ]]; then
		while IFS= read -r line || [[ -n "${line}" ]]; do
			[[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
			line="${line#"${line%%[![:space:]]*}"}"
			line="${line%"${line##*[![:space:]]}"}"
			path="${line}"
			break
		done <"${config}"
		[[ -n "${path}" ]] || die 2 "${config} names no overlay path"
		[[ -d "${path}" ]] || die 2 "${config} names ${path}, which is not a directory"
		printf '%s' "${path}"
		return 0
	fi
	if command -v portageq >/dev/null 2>&1; then
		path="$(portageq get_repo_path / bentoo 2>/dev/null || true)"
	fi
	[[ -n "${path}" ]] || die 2 "cannot locate the bentoo overlay: set ZP_OVERLAY, write .zp-overlay, or make portageq available"
	printf '%s' "${path}"
}

# _zp_distdir — Portage's DISTDIR, falling back to the default when portageq
# cannot answer (R2.2's search path must still be nameable).
_zp_distdir() {
	local path=""
	if [[ -n "${ZP_DISTDIR:-}" ]]; then
		printf '%s' "${ZP_DISTDIR}"
		return 0
	fi
	if command -v portageq >/dev/null 2>&1; then
		path="$(portageq distdir 2>/dev/null || true)"
	fi
	printf '%s' "${path:-${ZP_DEFAULT_DISTDIR}}"
}

# _zp_parse_commit <ebuild> — echo the EGIT_COMMIT assignment, or nothing.
# Pure bash: no grep, no sed, so it survives an empty PATH.
_zp_parse_commit() {
	local ebuild="$1" line
	while IFS= read -r line || [[ -n "${line}" ]]; do
		if [[ "${line}" =~ ^[[:space:]]*EGIT_COMMIT=[\"\']?([0-9a-fA-F]+)[\"\']?[[:space:]]*$ ]]; then
			printf '%s' "${BASH_REMATCH[1]}"
			return 0
		fi
	done <"${ebuild}"
	return 0
}

# resolve_version <PF> — resolve everything the tooling needs for one packaged
# version and export it. Silent on success; dies with status 2 on any gap.
#
# Exports ZP_OVERLAY ZP_EBUILD ZP_PV ZP_COMMIT ZP_DISTFILE ZP_WORKTREE
# (plus ZP_REPO, ZP_DISTDIR and ZP_WORKROOT, which callers may also override).
resolve_version() {
	local pf="${1:-}"
	[[ -n "${pf}" ]] || die 2 "resolve_version: no version given (expected a PF such as zed-1.18.0_pre20260822)"

	ZP_REPO="${ZP_REPO:-$(_zp_repo_root)}"
	ZP_OVERLAY="$(_zp_overlay)"
	ZP_DISTDIR="$(_zp_distdir)"
	ZP_WORKROOT="${ZP_WORKROOT:-${ZP_REPO}/work}"

	ZP_PV="${pf}"
	ZP_EBUILD="${ZP_OVERLAY}/${ZP_CATEGORY_PATH}/${pf}.ebuild"
	[[ -f "${ZP_EBUILD}" ]] || die 2 "no ebuild for ${pf}: ${ZP_EBUILD}"

	ZP_COMMIT="$(_zp_parse_commit "${ZP_EBUILD}")"
	[[ -n "${ZP_COMMIT}" ]] || die 2 "no EGIT_COMMIT assignment in ${ZP_EBUILD}"

	ZP_DISTFILE="${ZP_DISTDIR}/${pf}.tar.gz"
	ZP_WORKTREE="${ZP_WORKROOT}/zed-${ZP_COMMIT}"

	export ZP_REPO ZP_OVERLAY ZP_DISTDIR ZP_WORKROOT
	export ZP_PV ZP_EBUILD ZP_COMMIT ZP_DISTFILE ZP_WORKTREE
}

# --- series parsing ----------------------------------------------------------

# read_series <series-file> [feature] — print the patch filenames in apply order,
# one per line, optionally restricted to one feature group.
#
# Blank lines and plain comments are ignored. `# @feature: <flag>` opens a group
# that carries forward until the next declaration. Every entry the series names
# is checked for existence, filtered or not: a series that points at a file that
# is not there is malformed, and all missing entries are reported at once (R3.3).
read_series() {
	local series="${1:-}" want="${2:-}"
	[[ -n "${series}" ]] || die 2 "read_series: no series file given"
	[[ -f "${series}" ]] || die 2 "no series file: ${series}"

	local dir="${series%/*}"
	[[ "${dir}" == "${series}" ]] && dir="."

	local line trimmed group="" name
	local -a selected=() missing=()

	while IFS= read -r line || [[ -n "${line}" ]]; do
		trimmed="${line#"${line%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		[[ -z "${trimmed}" ]] && continue

		if [[ "${trimmed}" == '#'* ]]; then
			if [[ "${trimmed}" =~ ^#[[:space:]]*@feature:[[:space:]]*([^[:space:]]+) ]]; then
				group="${BASH_REMATCH[1]}"
			fi
			continue
		fi

		name="${trimmed}"
		[[ -f "${dir}/${name}" ]] || missing+=("${name}")
		if [[ -z "${want}" || "${group}" == "${want}" ]]; then
			selected+=("${name}")
		fi
	done <"${series}"

	if ((${#missing[@]} > 0)); then
		die 2 "series names ${#missing[@]} missing patch file(s) under ${dir}: ${missing[*]}"
	fi
	if [[ -n "${want}" ]] && ((${#selected[@]} == 0)); then
		die 2 "no patches in feature group '${want}' (series: ${series})"
	fi

	((${#selected[@]} == 0)) || printf '%s\n' "${selected[@]}"
}
