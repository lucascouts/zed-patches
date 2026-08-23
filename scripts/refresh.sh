#!/usr/bin/env bash
# Carry the patch series onto a new packaged commit after a version bump.
#
#     refresh.sh --from <PF_old> --to <PF_new>
#
# Copies the old patch directory forward, prepares the new source tree, then
# applies each patch for real and regenerates it so its context lines match the
# new source. The source version's directory is read-only throughout: a refresh
# that rewrote it would destroy the only known-good set.
#
# On conflict the run stops, the .rej files are left for inspection, and the
# conflicting patch plus the ones not yet processed are named. Resolution is
# manual by design -- a patch that no longer applies is a decision.
#
# Exit: 0 refreshed · 1 a patch conflicted · 2 environment problem.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s --from <PF_old> --to <PF_new>\n' "${0##*/}" >&2
	exit 2
}

# report_unprocessed <index> <total> <patches...> — name what never got looked at,
# so a stopped refresh says how much of the series is still unknown.
report_unprocessed() {
	local index="$1" total="$2"
	shift 2
	local -a all=("$@")
	local -a rest=()
	local i
	for ((i = index; i < total; i++)); do
		rest+=("${all[i]}")
	done
	if ((${#rest[@]} == 0)); then
		printf 'no patches left unprocessed\n' >&2
	else
		printf '%d patch(es) not processed: %s\n' "${#rest[@]}" "${rest[*]}" >&2
	fi
}

# regenerate <original> <diff> <out> — write the fresh diff under the original's
# format-patch header, so authorship, date and Subject survive a refresh. A patch
# that is a bare diff is simply replaced.
regenerate() {
	local original="$1" diff="$2" out="$3"
	local first
	IFS= read -r first <"${original}" || first=""
	if [[ "${first}" =~ ^From\ [0-9a-f]{7,40}\  ]]; then
		{
			local line
			while IFS= read -r line; do
				printf '%s\n' "${line}"
				[[ "${line}" == "---" ]] && break
			done <"${original}"
			printf '\n'
			cat "${diff}"
		} >"${out}"
	else
		cat "${diff}" >"${out}"
	fi
}

main() {
	local from="" to="" arg expect=""
	for arg in "$@"; do
		case "${expect}" in
		from)
			from="${arg}"
			expect=""
			continue
			;;
		to)
			to="${arg}"
			expect=""
			continue
			;;
		esac
		case "${arg}" in
		--from) expect="from" ;;
		--to) expect="to" ;;
		--from=*) from="${arg#--from=}" ;;
		--to=*) to="${arg#--to=}" ;;
		-h | --help) usage ;;
		*) die 2 "unexpected argument: ${arg}" ;;
		esac
	done
	[[ -z "${expect}" ]] || die 2 "--${expect} needs a version"
	[[ -n "${from}" && -n "${to}" ]] || usage
	[[ "${from}" != "${to}" ]] || die 2 "--from and --to are the same version: ${from}"

	# The repository is resolved without a version: the copy must happen before
	# anything needs the new version's ebuild or distfile.
	ZP_REPO="${ZP_REPO:-$(_zp_repo_root)}"
	local src_dir="${ZP_REPO}/patches/${from}"
	local dst_dir="${ZP_REPO}/patches/${to}"

	[[ -d "${src_dir}" ]] || die 2 "no patch directory for ${from}: ${src_dir}"
	[[ ! -e "${dst_dir}" ]] ||
		die 2 "patches/${to} already exists (${dst_dir}) — refusing to clobber a partial refresh; remove it first"

	cp -a "${src_dir}" "${dst_dir}"
	printf 'copied %s -> %s\n' "${src_dir}" "${dst_dir}"

	local listing status=0
	listing="$(read_series "${dst_dir}/series")" || status=$?
	((status == 0)) || exit "${status}"
	local -a patches=()
	[[ -z "${listing}" ]] || mapfile -t patches <<<"${listing}"
	local total="${#patches[@]}"
	((total > 0)) || die 2 "the series for ${to} names no patches"

	# Prepare the new tree. A failure here is reported like a conflict: nothing
	# has been regenerated, so the whole series is still unknown.
	local here prep_out prep_status=0
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	prep_out="$("${here}/prepare-tree.sh" "${to}" 2>&1)" || prep_status=$?
	if ((prep_status != 0)); then
		printf '%s\n' "${prep_out}" >&2
		printf '\ncannot prepare the source tree for %s (status %d); %s holds the unrefreshed copy\n' \
			"${to}" "${prep_status}" "${dst_dir}" >&2
		report_unprocessed 0 "${total}" "${patches[@]}"
		exit "${prep_status}"
	fi
	printf '%s\n' "${prep_out}"

	resolve_version "${to}"
	local tree="${ZP_WORKTREE}"

	local name index=0 rc diff_file
	diff_file="$(mktemp)"
	# shellcheck disable=SC2064  # the path is fixed at trap time, deliberately
	trap "rm -f '${diff_file}'" EXIT

	for name in "${patches[@]}"; do
		rc=0
		# --no-backup-if-mismatch: a hunk that applies with fuzz or an offset
		# otherwise leaves a .orig beside the file, which the regenerated diff
		# would then carry as a spurious new file.
		(cd "${tree}" && patch -p1 -f -g0 --no-backup-if-mismatch <"${dst_dir}/${name}") || rc=$?
		if ((rc != 0)); then
			printf '\n%s conflicts against %s (patch exited %d); .rej files kept under %s\n' \
				"${name}" "${to}" "${rc}" "${tree}" >&2
			report_unprocessed $((index + 1)) "${total}" "${patches[@]}"
			exit 1
		fi

		git -C "${tree}" add -A -f -- . ':!*.orig' ':!*.rej'
		git -C "${tree}" diff --cached --no-renames HEAD >"${diff_file}"
		regenerate "${dst_dir}/${name}" "${diff_file}" "${dst_dir}/${name}.new"
		mv "${dst_dir}/${name}.new" "${dst_dir}/${name}"
		git -C "${tree}" commit -q -m "refresh: ${name}"

		index=$((index + 1))
		printf 'refreshed [%d/%d] %s\n' "${index}" "${total}" "${name}"
	done

	printf '\nall %d patches refreshed onto %s in %s\n' "${total}" "${to}" "${dst_dir}"
	printf 'next: verify.sh %s\n' "${to}"
}

main "$@"
