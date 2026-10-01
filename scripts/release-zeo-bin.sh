#!/usr/bin/env bash
# Build app-editors/zeo for x86-64-v3 and package it as the zeo-bin distfile.
#
#     release-zeo-bin.sh <PF> [--fresh]
#
# One command for the whole release build, unprivileged:
#
#   1. `ebuild <zeo ebuild> compile install` under release/configroot, which
#      replaces /etc/portage for this build -- the host's make.conf appends
#      target-cpu=znver5 to any RUSTFLAGS, so flags on the command line are not
#      enough. PORTAGE_INST_UID/GID are the caller's, because install(1) cannot
#      chown to root without root; the tarball resets ownership to 0:0 anyway.
#   2. make-bin-release.sh, which refuses a non-v3 or AVX-512 binary and writes
#      ${DISTDIR}/zeo-bin-<PV>-amd64.tar.xz with PROVENANCE.txt.
#
# A build directory left by an earlier run of the same PF is reused, so a failed
# install does not cost the 20-minute compile again; --fresh discards it.
#
# It never uploads and never touches the zeo-bin Manifest: the Manifest must
# describe the bytes on R2, so it is regenerated only after the upload, which a
# human authorizes each time. The steps are printed at the end.
#
# Environment: ZP_RELEASE_TMPDIR (default ~/.cache/zeo-release) and the ZP_*
# overrides lib.sh honours, ZP_OVERLAY among them.
#
# Exit: 0 written · 1 the build or the binary is not releasable · 2 environment.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The package's default USE set, spelled out so the binary does not depend on
# whatever profile the build host happens to use.
RELEASE_USE="X wayland mimalloc claude-agent-acp-plus claude-agent-acp-tui claude-code-ide -test"

usage() {
	sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 2
}

main() {
	local pf="" fresh=0 arg
	for arg in "$@"; do
		case "${arg}" in
		--fresh) fresh=1 ;;
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*) [[ -z "${pf}" ]] || die 2 "more than one PF given"; pf="${arg}" ;;
		esac
	done
	[[ -n "${pf}" ]] || usage
	resolve_version "${pf}"

	local configroot="${ZP_REPO}/release/configroot"
	[[ -f "${configroot}/etc/portage/make.conf" ]] || die 2 "no release configuration at ${configroot}"

	local tmpdir="${ZP_RELEASE_TMPDIR:-${HOME}/.cache/zeo-release}"
	local builddir="${tmpdir}/portage/app-editors/${pf}"
	mkdir -p "${tmpdir}"
	if ((fresh)) && [[ -d "${builddir}" ]]; then
		printf 'discarding %s\n' "${builddir}"
		rm -rf "${builddir}"
	fi

	printf 'building %s for x86-64-v3 in %s\n' "${pf}" "${builddir}"
	env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
		PORTAGE_CONFIGROOT="${configroot}" \
		PORTAGE_TMPDIR="${tmpdir}" \
		PORTAGE_INST_UID="$(id -u)" \
		PORTAGE_INST_GID="$(id -g)" \
		USE="${RELEASE_USE}" \
		ebuild "${ZP_EBUILD}" compile install ||
		die 1 "the build failed; log: ${builddir}/temp/build.log"

	bash "${ZP_REPO}/scripts/make-bin-release.sh" "${pf}" "${builddir}"
}

main "$@"
