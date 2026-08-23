#!/usr/bin/env bash
# Self-test for the zed-patches tooling.
#
# Runs entirely against temporary fixtures: it never reads the real distfile,
# never touches the overlay, and never needs network access.
#
# Override the repository under test with ZP_REPO_ROOT (used while the scripts
# are still being written).

set -uo pipefail

SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ZP_REPO_ROOT:-$(cd "${SELFTEST_DIR}/.." && pwd)}"
SCRIPTS="${REPO_ROOT}/scripts"

PASS=0
FAIL=0
CURRENT=""

FIXTURE_COMMIT="1111111111111111111111111111111111111111"
FIXTURE_PV="zed-9.9.9_pre20260101"

case_start() {
	CURRENT="$1"
}

ok() {
	PASS=$((PASS + 1))
	printf 'ok   %s\n' "${CURRENT}"
}

no() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n       %s\n' "${CURRENT}" "$1"
}

assert_status() {
	local expected="$1" actual="$2"
	[[ "${expected}" == "${actual}" ]] || {
		no "expected exit ${expected}, got ${actual}"
		return 1
	}
	return 0
}

assert_contains() {
	local haystack="$1" needle="$2"
	[[ "${haystack}" == *"${needle}"* ]] || {
		no "output did not mention: ${needle}"
		return 1
	}
	return 0
}

assert_equal() {
	local expected="$1" actual="$2"
	[[ "${expected}" == "${actual}" ]] || {
		no "expected [${expected}], got [${actual}]"
		return 1
	}
	return 0
}

tree_checksum() {
	find "$1" -path '*/.git' -prune -o -type f -print0 |
		sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

# --- fixture builders -------------------------------------------------------

# make_ebuild <dir> <commit|-> — an ebuild carrying (or missing) EGIT_COMMIT.
make_ebuild() {
	local dir="$1" commit="$2"
	mkdir -p "${dir}/app-editors/zed/files"
	{
		echo 'EAPI=8'
		[[ "${commit}" == "-" ]] || echo "EGIT_COMMIT=\"${commit}\""
		echo 'SRC_URI="https://example.invalid/${EGIT_COMMIT}.tar.gz -> ${PF}.tar.gz"'
	} >"${dir}/app-editors/zed/${FIXTURE_PV}.ebuild"
}

# make_distfile <distdir> <root-dir-name> — a tarball with a known root.
make_distfile() {
	local distdir="$1" root="$2" stage
	mkdir -p "${distdir}"
	stage="$(mktemp -d)"
	mkdir -p "${stage}/${root}/src"
	printf 'fn main() {\n    println!("one");\n}\n' >"${stage}/${root}/src/main.rs"
	printf 'fn helper() {\n    let x = 1;\n}\n' >"${stage}/${root}/src/lib.rs"
	tar -czf "${distdir}/${FIXTURE_PV}.tar.gz" -C "${stage}" "${root}"
	rm -rf "${stage}"
}

# make_patch <out.patch> <relative-file> <old-text> <new-text>
make_patch() {
	local out="$1" rel="$2" old="$3" new="$4" work
	work="$(mktemp -d)"
	mkdir -p "${work}/a/$(dirname "${rel}")" "${work}/b/$(dirname "${rel}")"
	printf '%s' "${old}" >"${work}/a/${rel}"
	printf '%s' "${new}" >"${work}/b/${rel}"
	(cd "${work}" && diff -Nur a b >"${out}")
	rm -rf "${work}"
}

# --- lib.sh: environment resolution (R2.3) ----------------------------------

test_lib_resolves_commit() {
	case_start "lib: resolves the packaged commit from the ebuild"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	out="$(ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_COMMIT}\"" 2>&1)"
	assert_equal "${FIXTURE_COMMIT}" "${out}" && ok
	rm -rf "${tmp}"
}

test_lib_rejects_ebuild_without_commit() {
	case_start "lib: dies with status 2 when the ebuild declares no commit"
	local tmp out status
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "-"
	out="$(ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" ".ebuild" && ok
	rm -rf "${tmp}"
}

test_lib_falls_back_to_default_distdir() {
	case_start "lib: falls back to the default distdir when portageq is unavailable"
	local tmp out
	tmp="$(mktemp -d)"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	out="$(PATH="/nonexistent" ZP_OVERLAY="${tmp}/overlay" bash -c "source '${SCRIPTS}/lib.sh'; resolve_version '${FIXTURE_PV}'; printf '%s' \"\${ZP_DISTFILE}\"" 2>&1)"
	assert_contains "${out}" "/var/cache/distfiles" && ok
	rm -rf "${tmp}"
}

# --- lib.sh: series parsing (R3.1, R3.2, R3.3) ------------------------------

series_fixture() {
	local dir="$1"
	mkdir -p "${dir}"
	: >"${dir}/0001-first.patch"
	: >"${dir}/0002-second.patch"
	: >"${dir}/0005-third.patch"
	cat >"${dir}/series" <<-EOS
		# a plain comment

		# @feature: group-a
		0001-first.patch
		# 0003/0004 retired upstream
		0005-third.patch

		# @feature: group-b
		0002-second.patch
	EOS
}

test_series_preserves_order() {
	case_start "series: preserves order and ignores blanks and plain comments"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series'" 2>&1 | tr '\n' ' ')"
	assert_equal "0001-first.patch 0005-third.patch 0002-second.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_group_carries_forward() {
	case_start "series: a feature group carries forward until redeclared"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series' group-a" 2>&1 | tr '\n' ' ')"
	assert_equal "0001-first.patch 0005-third.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_filter_returns_only_its_group() {
	case_start "series: filtering returns only the requested group"
	local tmp out
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series' group-b" 2>&1 | tr '\n' ' ')"
	assert_equal "0002-second.patch " "${out}" && ok
	rm -rf "${tmp}"
}

test_series_lists_every_missing_entry() {
	case_start "series: lists every missing entry at once with status 2"
	local tmp out status
	tmp="$(mktemp -d)"
	series_fixture "${tmp}"
	rm "${tmp}/0001-first.patch" "${tmp}/0002-second.patch"
	out="$(bash -c "source '${SCRIPTS}/lib.sh'; read_series '${tmp}/series'" 2>&1)"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "0001-first.patch" &&
		assert_contains "${out}" "0002-second.patch" && ok
	rm -rf "${tmp}"
}

# --- prepare-tree.sh (R2.1, R2.2, R2.4, R2.5, R2.6) -------------------------

prepare_env() {
	local tmp="$1" root="${2:-zed-${FIXTURE_COMMIT}}"
	make_ebuild "${tmp}/overlay" "${FIXTURE_COMMIT}"
	make_distfile "${tmp}/distfiles" "${root}"
	mkdir -p "${tmp}/repo/scripts"
}

run_prepare() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		bash "${SCRIPTS}/prepare-tree.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_prepare_refuses_missing_distfile() {
	case_start "prepare: missing distfile exits 2, names the path, creates no tree"
	local tmp out status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	rm "${tmp}/distfiles/${FIXTURE_PV}.tar.gz"
	out="$(run_prepare "${tmp}")"
	status=$?
	assert_status 2 "${status}" &&
		assert_contains "${out}" "${tmp}/distfiles" &&
		{ [[ ! -d "${tmp}/work" ]] || {
			no "a work tree was created anyway"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_prepare_refuses_mismatched_root() {
	case_start "prepare: archive root mismatching the commit exits 2 and extracts nothing"
	local tmp out status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}" "zed-deadbeef"
	out="$(run_prepare "${tmp}")"
	status=$?
	assert_status 2 "${status}" &&
		{ [[ ! -d "${tmp}/work/zed-deadbeef" ]] || {
			no "the mismatched archive was extracted"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_prepare_is_idempotent() {
	case_start "prepare: a second run reuses the tree; --force re-extracts"
	local tmp before after forced
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	printf 'marker\n' >"${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt"
	before="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	run_prepare "${tmp}" >/dev/null
	after="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	run_prepare "${tmp}" --force >/dev/null
	forced="$(cat "${tmp}/work/zed-${FIXTURE_COMMIT}/marker.txt" 2>/dev/null)"
	assert_equal "marker" "${before}" &&
		assert_equal "${before}" "${after}" &&
		assert_equal "" "${forced}" && ok
	rm -rf "${tmp}"
}

test_prepare_leaves_pristine_baseline() {
	case_start "prepare: the tree carries one baseline commit and a clean status"
	local tmp tree commits status_out
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	commits="$(git -C "${tree}" rev-list --count HEAD 2>&1)"
	status_out="$(git -C "${tree}" status --porcelain 2>&1)"
	assert_equal "1" "${commits}" &&
		assert_equal "" "${status_out}" && ok
	rm -rf "${tmp}"
}

test_prepare_regenerates_a_patch() {
	case_start "prepare: an edit to the tree can be regenerated as a reappliable patch"
	local tmp tree patch status
	tmp="$(mktemp -d)"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	printf 'fn main() {\n    println!("two");\n}\n' >"${tree}/src/main.rs"
	patch="${tmp}/edit.patch"
	git -C "${tree}" diff >"${patch}" 2>&1
	git -C "${tree}" checkout -- . 2>/dev/null
	(cd "${tree}" && patch -p1 -f -g0 --dry-run <"${patch}" >/dev/null 2>&1)
	status=$?
	assert_status 0 "${status}" && ok
	rm -rf "${tmp}"
}

# --- verify.sh (R4.1 - R4.6) ------------------------------------------------

verify_env() {
	local tmp="$1" broken="${2:-no}"
	prepare_env "${tmp}"
	run_prepare "${tmp}" >/dev/null
	mkdir -p "${tmp}/repo/patches/${FIXTURE_PV}"
	local pdir="${tmp}/repo/patches/${FIXTURE_PV}"
	make_patch "${pdir}/0001-first.patch" "src/main.rs" \
		'fn main() {
    println!("one");
}
' 'fn main() {
    println!("two");
}
'
	if [[ "${broken}" == "broken" ]]; then
		make_patch "${pdir}/0002-second.patch" "src/lib.rs" \
			'fn helper() {
    let x = 99;
}
' 'fn helper() {
    let x = 100;
}
'
	else
		make_patch "${pdir}/0002-second.patch" "src/lib.rs" \
			'fn helper() {
    let x = 1;
}
' 'fn helper() {
    let x = 2;
}
'
	fi
	cat >"${pdir}/series" <<-EOS
		# @feature: group-a
		0001-first.patch
		# @feature: group-b
		0002-second.patch
	EOS
}

run_verify() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/verify.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_verify_passes_whole_series() {
	case_start "verify: a fully applying series exits 0 and reports the count"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "2" && ok
	rm -rf "${tmp}"
}

test_verify_reports_failing_patch() {
	case_start "verify: a broken patch exits 1 naming patch, position and file"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 1 "${status}" &&
		assert_contains "${out}" "0002-second.patch" &&
		assert_contains "${out}" "src/lib.rs" && ok
	rm -rf "${tmp}"
}

test_verify_requires_prepared_tree() {
	case_start "verify: a missing prepared tree exits 2"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	rm -rf "${tmp}/work"
	out="$(run_verify "${tmp}")"
	status=$?
	assert_status 2 "${status}" && ok
	rm -rf "${tmp}"
}

test_verify_leaves_tree_untouched() {
	case_start "verify: the tree is byte-identical after passing and failing runs"
	local tmp tree before after_pass after_fail pass_status fail_status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	before="$(tree_checksum "${tree}")"
	run_verify "${tmp}" >/dev/null
	pass_status=$?
	after_pass="$(tree_checksum "${tree}")"
	rm -rf "${tmp}"

	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	tree="${tmp}/work/zed-${FIXTURE_COMMIT}"
	run_verify "${tmp}" >/dev/null
	fail_status=$?
	after_fail="$(tree_checksum "${tree}")"
	assert_status 0 "${pass_status}" &&
		assert_status 1 "${fail_status}" &&
		assert_equal "${before}" "${after_pass}" &&
		assert_equal "${before}" "${after_fail}" && ok
	rm -rf "${tmp}"
}

test_verify_feature_filter() {
	case_start "verify: --feature verifies only its group; unknown group exits 2"
	local tmp out status unknown_status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_verify "${tmp}" "--feature=group-a")"
	status=$?
	run_verify "${tmp}" "--feature=nope" >/dev/null
	unknown_status=$?
	assert_status 0 "${status}" &&
		assert_status 2 "${unknown_status}" &&
		assert_contains "${out}" "0001-first.patch" && ok
	rm -rf "${tmp}"
}

# --- sync-overlay.sh (R6.1 - R6.5) ------------------------------------------

run_sync() {
	local tmp="$1"
	shift
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/sync-overlay.sh" "${FIXTURE_PV}" "$@" 2>&1
}

test_sync_refuses_unverified() {
	case_start "sync: failing verification copies nothing and exits non-zero"
	local tmp out status count
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_sync "${tmp}")"
	status=$?
	count="$(find "${tmp}/overlay/app-editors/zed/files" -name '*.patch' | wc -l)"
	[[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		rm -rf "${tmp}"
		return
	}
	assert_equal "0" "${count}" &&
		assert_contains "${out}" "${FIXTURE_PV}" && ok
	rm -rf "${tmp}"
}

test_sync_copies_verified_series() {
	case_start "sync: a verified series is copied in full and the ebuild is untouched"
	local tmp status count before after
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	before="$(sha256sum "${tmp}/overlay/app-editors/zed/${FIXTURE_PV}.ebuild" | cut -d' ' -f1)"
	run_sync "${tmp}" >/dev/null
	status=$?
	after="$(sha256sum "${tmp}/overlay/app-editors/zed/${FIXTURE_PV}.ebuild" | cut -d' ' -f1)"
	count="$(find "${tmp}/overlay/app-editors/zed/files" -name '*.patch' | wc -l)"
	assert_status 0 "${status}" &&
		assert_equal "2" "${count}" &&
		assert_equal "${before}" "${after}" && ok
	rm -rf "${tmp}"
}

test_sync_dry_run_writes_nothing() {
	case_start "sync: --dry-run reports the same set and writes nothing"
	local tmp out count
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	out="$(run_sync "${tmp}" "--dry-run")"
	count="$(find "${tmp}/overlay/app-editors/zed/files" -name '*.patch' | wc -l)"
	assert_equal "0" "${count}" &&
		assert_contains "${out}" "0001-first.patch" && ok
	rm -rf "${tmp}"
}

test_sync_reports_orphans() {
	case_start "sync: an overlay-only patch is reported as an orphan and kept"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	: >"${tmp}/overlay/app-editors/zed/files/0099-orphan.patch"
	out="$(run_sync "${tmp}")"
	status=$?
	assert_status 0 "${status}" &&
		assert_contains "${out}" "0099-orphan.patch" &&
		{ [[ -f "${tmp}/overlay/app-editors/zed/files/0099-orphan.patch" ]] || {
			no "the orphan was deleted"
			false
		}; } && ok
	rm -rf "${tmp}"
}

test_sync_reports_zero_orphans_when_aligned() {
	case_start "sync: an overlay matching the series reports zero orphans"
	local tmp out
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	run_sync "${tmp}" >/dev/null
	out="$(run_sync "${tmp}")"
	assert_contains "${out}" "0 orphan" && ok
	rm -rf "${tmp}"
}

# --- refresh.sh (R7.1 - R7.3) -----------------------------------------------

run_refresh() {
	local tmp="$1" to="$2"
	shift 2
	ZP_OVERLAY="${tmp}/overlay" ZP_DISTDIR="${tmp}/distfiles" ZP_WORKROOT="${tmp}/work" \
		ZP_REPO="${tmp}/repo" bash "${SCRIPTS}/refresh.sh" --from "${FIXTURE_PV}" --to "${to}" "$@" 2>&1
}

test_refresh_preserves_source_set() {
	case_start "refresh: the source version's patch set is left byte-identical"
	local tmp before after
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	before="$(tree_checksum "${tmp}/repo/patches/${FIXTURE_PV}")"
	run_refresh "${tmp}" "zed-9.9.9_pre20260202" >/dev/null
	after="$(tree_checksum "${tmp}/repo/patches/${FIXTURE_PV}")"
	{ [[ -f "${tmp}/repo/patches/zed-9.9.9_pre20260202/series" ]] || {
		no "the refreshed patch set was not produced"
		false
	}; } &&
		assert_equal "${before}" "${after}" && ok
	rm -rf "${tmp}"
}

test_refresh_refuses_existing_destination() {
	case_start "refresh: an existing destination directory is refused"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}"
	mkdir -p "${tmp}/repo/patches/zed-9.9.9_pre20260202"
	out="$(run_refresh "${tmp}" "zed-9.9.9_pre20260202")"
	status=$?
	{ [[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		false
	}; } &&
		assert_contains "${out}" "zed-9.9.9_pre20260202" && ok
	rm -rf "${tmp}"
}

test_refresh_stops_on_conflict() {
	case_start "refresh: a conflict exits non-zero, keeps the reject and names the remainder"
	local tmp out status
	tmp="$(mktemp -d)"
	verify_env "${tmp}" "broken"
	out="$(run_refresh "${tmp}" "zed-9.9.9_pre20260202")"
	status=$?
	[[ "${status}" -ne 0 ]] || {
		no "expected a non-zero exit"
		rm -rf "${tmp}"
		return
	}
	assert_contains "${out}" "0002-second.patch" && ok
	rm -rf "${tmp}"
}

# --- runner -----------------------------------------------------------------

main() {
	if [[ ! -f "${SCRIPTS}/lib.sh" ]]; then
		printf 'scripts not found under %s — nothing implemented yet\n' "${SCRIPTS}" >&2
	fi

	test_lib_resolves_commit
	test_lib_rejects_ebuild_without_commit
	test_lib_falls_back_to_default_distdir

	test_series_preserves_order
	test_series_group_carries_forward
	test_series_filter_returns_only_its_group
	test_series_lists_every_missing_entry

	test_prepare_refuses_missing_distfile
	test_prepare_refuses_mismatched_root
	test_prepare_is_idempotent
	test_prepare_leaves_pristine_baseline
	test_prepare_regenerates_a_patch

	test_verify_passes_whole_series
	test_verify_reports_failing_patch
	test_verify_requires_prepared_tree
	test_verify_leaves_tree_untouched
	test_verify_feature_filter

	test_sync_refuses_unverified
	test_sync_copies_verified_series
	test_sync_dry_run_writes_nothing
	test_sync_reports_orphans
	test_sync_reports_zero_orphans_when_aligned

	test_refresh_preserves_source_set
	test_refresh_refuses_existing_destination
	test_refresh_stops_on_conflict

	printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
	[[ "${FAIL}" -eq 0 ]]
}

main "$@"
