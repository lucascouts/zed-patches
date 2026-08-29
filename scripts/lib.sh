#!/usr/bin/env bash
# Shared environment resolution, series parsing and the advisory step for the
# zed-patches tooling.
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

# The chain's npm lockfiles, relative to the chain root — the directory holding
# all five projects, one level above this repository.
#
# The fifth lockfile the advisory step reads, the packaged Zed's Cargo.lock, is
# deliberately absent from this list: it is not a fixed path. It lives in the
# prepared tree of whichever commit the ebuild names, so it is resolved at run
# time. The overlay autoupdates, and any version written down here would be
# stale before it was read.
ZP_NPM_LOCKFILES=(
	"claude-agent-fork/fork/package-lock.json"
	"claude-agent-fork/claude-agent-acp-plus/package-lock.json"
	"claude-agent-tui/fork/package-lock.json"
	"claude-agent-tui/claude-agent-tui/package-lock.json"
)

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

# --- advisories --------------------------------------------------------------

# _zp_chain_root — the directory holding all five projects of the chain. This
# repository sits directly below it.
#
# ZP_CHAIN_ROOT overrides, following the convention the rest of this file already
# follows for ZP_REPO, ZP_OVERLAY, ZP_DISTDIR and ZP_WORKROOT.
_zp_chain_root() {
	if [[ -n "${ZP_CHAIN_ROOT:-}" ]]; then
		printf '%s' "${ZP_CHAIN_ROOT}"
		return 0
	fi
	(cd "$(_zp_repo_root)/.." && pwd)
}

# _zp_packaged_worktree — print the prepared tree of the packaged version, or
# nothing at all when it cannot be resolved.
#
# The body is a SUBSHELL — round brackets, not braces — on purpose. _zp_overlay
# and resolve_version answer a gap with die, which exits; wrapped this way that
# exit ends the subshell and nothing else, so an unresolvable version costs the
# advisory step one lockfile instead of taking its caller down with it. What
# resolve_version exports stays inside too, leaving a caller that resolves a
# version of its own afterwards entirely unaffected.
#
# An already-resolved ZP_WORKTREE wins: both callers resolve a version for their
# own reasons, and re-deriving it would be a second answer to one question.
_zp_packaged_worktree() (
	local overlay dir name
	local -a found=()

	if [[ -n "${ZP_WORKTREE:-}" ]]; then
		printf '%s' "${ZP_WORKTREE}"
		return 0
	fi

	overlay="$(_zp_overlay)" || return 1
	[[ -n "${overlay}" ]] || return 1

	# nullglob so a directory with no ebuild yields an empty list rather than the
	# pattern itself; set inside the subshell, so no caller sees it change.
	dir="${overlay}/${ZP_CATEGORY_PATH}"
	shopt -s nullglob
	found=("${dir}"/*.ebuild)
	shopt -u nullglob

	# Exactly one, as status.sh and check-sync.sh both insist: with two ebuilds
	# there is no single packaged version, and guessing would scan another one.
	((${#found[@]} == 1)) || return 1

	name="${found[0]##*/}"
	resolve_version "${name%.ebuild}" || return 1
	[[ -n "${ZP_WORKTREE:-}" ]] || return 1
	printf '%s' "${ZP_WORKTREE}"
)

# _zp_advisory_line <verdict> <subject> — one line of the report, the verdict in
# a cell wide enough for the longest of the four so they line up under one
# another. status.sh's mark() does the same for the two verdicts it knows.
_zp_advisory_line() {
	printf '  %-11s %s\n' "$1" "$2"
}

# _zp_advisory_detail <text> — the scanner's own words, indented under the
# subject column, the way check-sync.sh indents what verify.sh told it.
_zp_advisory_detail() {
	local line
	[[ -n "$1" ]] || return 0
	while IFS= read -r line; do
		printf '              %s\n' "${line}"
	done <<<"$1"
}

# _zp_scan_lockfile <lockfile> <chain-root> — scan one lockfile, print its
# verdict, and return 0 whatever the answer was.
_zp_scan_lockfile() {
	local path="$1" root="$2" label rc=0 out
	label="${path#"${root}/"}"

	# work/ is disposable by design, so the packaged Cargo.lock is routinely not
	# there. That is one file's answer, never the step's.
	if [[ ! -f "${path}" ]]; then
		_zp_advisory_line skipped "${label} — not there"
		return 0
	fi

	# Capture the status, then branch on it. The obvious `|| true` — the usual way
	# to keep set -e off a command that is allowed to fail — would lose the whole
	# distinction: osv-scanner exits non-zero BOTH when it finds something and
	# when it breaks, so a scanner that never ran would read exactly like a clean
	# one. This is the same rc=0; out="$(…)" || rc=$? verify.sh and check-sync.sh
	# already use. The lookup is bounded the way the tree's only other network
	# call is, npm_version's timeout 25.
	out="$(timeout 25 osv-scanner scan source --lockfile "${path}" 2>&1)" || rc=$?

	case "${rc}" in
	0)
		_zp_advisory_line clean "${label}"
		;;
	1)
		# 1 means "vulnerabilities found", and in osv-scanner 2.x only that. The
		# report is still required: a 1 with nothing to show is a broken scan.
		if [[ -n "${out}" ]]; then
			_zp_advisory_line findings "${label}"
			_zp_advisory_detail "${out}"
		else
			_zp_advisory_line 'scan failed' "${label} — exit 1 with no report"
		fi
		;;
	128)
		# "No package sources found" — a lockfile that parses but declares nothing.
		# Nothing was checked, so nothing is known; that is a skip, not a pass.
		_zp_advisory_line skipped "${label} — no packages to check"
		;;
	*)
		_zp_advisory_line 'scan failed' "${label} — osv-scanner exited ${rc}"
		_zp_advisory_detail "${out}"
		;;
	esac
	return 0
}

# report_advisories [--offline] — check the chain's five lockfiles against the
# OSV database and print one verdict per file. ALWAYS returns 0.
#
# Four outcomes, never three: clean · findings · scan failed · skipped. The
# fourth is what a step that was not run answers — no scanner on PATH, --offline,
# or a lockfile that is not there — and none of the three is a failure.
#
# Returning 0 is the contract, not an accident. Every caller runs under
# set -euo pipefail, where any other status would abort the run, and an advisory
# is not a disagreement between copies — which is the only question status.sh
# asks. A CVE is reported here and answered by a human, never by an exit code.
report_advisories() {
	local offline=0 arg
	for arg in "$@"; do
		case "${arg}" in
		--offline) offline=1 ;;
		*) printf 'report_advisories: ignoring unknown argument: %s\n' "${arg}" >&2 ;;
		esac
	done

	printf '\n\033[1madvisories (osv-scanner)\033[0m\n'

	# Two ways the question is never asked, and neither is a failure. --offline
	# must not merely discard the answer: it must not reach for the network.
	if ((offline == 1)); then
		_zp_advisory_line skipped '--offline — the OSV database is a network lookup'
		return 0
	fi
	if ! command -v osv-scanner >/dev/null 2>&1; then
		_zp_advisory_line skipped 'osv-scanner is not on PATH'
		return 0
	fi

	local root worktree rel
	root="$(_zp_chain_root)"
	worktree="$(_zp_packaged_worktree 2>/dev/null)" || worktree=""

	for rel in "${ZP_NPM_LOCKFILES[@]}"; do
		_zp_scan_lockfile "${root}/${rel}" "${root}"
	done

	if [[ -n "${worktree}" ]]; then
		_zp_scan_lockfile "${worktree}/Cargo.lock" "${root}"
	else
		_zp_advisory_line skipped 'Cargo.lock — no packaged version to resolve it from'
	fi

	return 0
}
