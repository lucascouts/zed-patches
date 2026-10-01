#!/usr/bin/env bash
# Package a finished app-editors/zeo build as the zeo-bin distfile.
#
#     make-bin-release.sh <PF> <builddir>
#
# <builddir> is Portage's build directory for that PF after `ebuild ... install`
# ran under release/configroot -- the one holding image/ and build-info/:
#
#     PORTAGE_CONFIGROOT=release/configroot PORTAGE_TMPDIR=<tmp> \
#         ebuild <overlay>/app-editors/zeo/<PF>.ebuild compile install
#     make-bin-release.sh <PF> <tmp>/portage/app-editors/<PF>
#
# Writes ${DISTDIR}/zeo-bin-<PVR>-amd64.tar.xz, whose single top directory holds
# the installed usr/ tree and PROVENANCE.txt, and prints the upload command.
# A name R2 already serves is checked first: identical bytes end the run with
# nothing to upload, different bytes are refused (ZP_DISTFILES_URL overrides the
# host, for testing). It never uploads: publishing to R2 is a remote, outward-facing step that a
# human authorizes each time.
#
# Refuses to package a binary that is not portable: one built with a target CPU
# other than x86-64-v3, or one carrying AVX-512 instructions.
#
# Exit: 0 written or already published · 1 the build is not releasable, or its
# name is taken on R2 by other bytes · 2 environment problem.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 2
}

main() {
	local pf="${1:-}" builddir="${2:-}"
	[[ -n "${pf}" && -n "${builddir}" ]] || usage
	resolve_version "${pf}"

	local image="${builddir}/image" info="${builddir}/build-info"
	[[ -d "${image}" ]] || die 2 "no image/ under ${builddir} -- run 'ebuild ... install' first"
	[[ -d "${info}" ]] || die 2 "no build-info/ under ${builddir}"

	local bin
	for bin in usr/bin/zeo usr/libexec/zeo-editor; do
		[[ -x "${image}/${bin}" ]] || die 1 "the image lacks ${bin}"
	done

	local rustflags cflags
	rustflags="$(cat "${info}/RUSTFLAGS" 2>/dev/null || true)"
	[[ -n "${rustflags}" ]] || rustflags="$(bzcat "${info}/environment.bz2" | sed -n 's/^declare -x RUSTFLAGS="\(.*\)"$/\1/p')"
	cflags="$(cat "${info}/CFLAGS")"
	[[ "${rustflags}" == *"target-cpu=x86-64-v3"* ]] ||
		die 1 "RUSTFLAGS does not target x86-64-v3: ${rustflags}"
	[[ "${rustflags}" != *"target-cpu=native"* && "${rustflags}" != *"target-cpu=znver"* ]] ||
		die 1 "RUSTFLAGS names a host-specific CPU: ${rustflags}"
	[[ "${cflags}" == *"-march=x86-64-v3"* ]] || die 1 "CFLAGS does not target x86-64-v3: ${cflags}"

	# AVX-512 uses the zmm registers and the k0-k7 opmask registers; neither
	# exists below it, so one occurrence is enough to refuse.
	printf 'scanning %s for AVX-512 instructions\n' "${image}/usr/libexec/zeo-editor"
	if objdump -d --no-show-raw-insn "${image}/usr/libexec/zeo-editor" | grep -qE '%zmm[0-9]|\{%k[1-7]\}'; then
		die 1 "zeo-editor carries AVX-512 instructions; it would SIGILL below AVX-512"
	fi

	# The revision stays in the name. A zeo revbump changes the binary, so it is a
	# different artefact: dropping -rN would put new bytes under a name R2 already
	# serves and a Manifest already pins. zeo-bin mirrors zeo's PVR, and its
	# SRC_URI names ${PF} for the same reason.
	local pv="${pf#zeo-}" name stage out
	name="zeo-bin-${pv}"
	out="${ZP_DISTDIR}/${name}-amd64.tar.xz"
	stage="$(mktemp -d)"
	# shellcheck disable=SC2064  # expanded now: stage is local and gone by EXIT
	trap "rm -rf '${stage}'" EXIT
	mkdir "${stage}/${name}"
	cp -a "${image}/usr" "${stage}/${name}/"

	local series="${ZP_REPO}/patches/${pf}/series" patch
	{
		printf 'zeo-bin %s -- provenance\n\n' "${pv}"
		printf 'built from     app-editors/zeo %s\n' "${pf}"
		printf 'zed version    %s\n' "$(sed -n 's/^version = "\(.*\)"$/\1/p' "${ZP_WORKTREE}/crates/zed/Cargo.toml" | head -n1)"
		printf 'zed commit     %s\n' "${ZP_COMMIT}"
		printf 'zed source     https://github.com/zed-industries/zed/archive/%s.tar.gz\n' "${ZP_COMMIT}"
		printf 'source sha256  %s\n' "$(sha256sum "${ZP_DISTFILE}" | cut -d' ' -f1)"
		printf 'USE            %s\n' "$(cat "${info}/USE")"
		printf 'CFLAGS         %s\n' "${cflags}"
		printf 'RUSTFLAGS      %s\n' "${rustflags}"
		printf 'configuration  zed-patches/release/configroot\n\n'
		printf 'patches, in apply order (sha256):\n'
		while IFS= read -r patch; do
			printf '  %s  %s\n' "$(sha256sum "${ZP_REPO}/patches/${pf}/${patch}" | cut -d' ' -f1)" "${patch}"
		done < <(read_series "${series}")
		printf '\nNEEDED (zeo-editor):\n'
		scanelf -qF '%n#F' "${image}/usr/libexec/zeo-editor" | tr ',' '\n' | sed 's/^/  /'
		printf '\nThe Corresponding Source is the zed source above plus these patches,\n'
		printf 'published in the bentoo overlay under app-editors/zeo/files/.\n'
	} >"${stage}/${name}/PROVENANCE.txt"

	# Deterministic archive: sorted names, no owner, and an mtime taken from the
	# snapshot date in the version (midnight UTC) rather than from the build --
	# the prepared tree's baseline commit is dated when the tree was prepared, so
	# it would differ between machines.
	local epoch=0
	if [[ "${pv}" =~ _p([0-9]{8}) ]]; then
		epoch="$(date -u -d "${BASH_REMATCH[1]}" +%s)"
	fi
	XZ_OPT=-9T0 tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${epoch}" \
		-C "${stage}" -cJf "${out}" "${name}"

	# A name already on R2 is a published artefact. Identical bytes mean there is
	# nothing to upload; different bytes mean this build must not take that name,
	# because the zeo-bin Manifest pins the published ones.
	local url="${ZP_DISTFILES_URL:-https://distfiles.obentoo.org}/${name}-amd64.tar.xz" remote_sum local_sum
	local_sum="$(sha256sum "${out}" | cut -d' ' -f1)"
	if curl -sfI "${url}" >/dev/null 2>&1; then
		remote_sum="$(curl -sfL "${url}" | sha256sum | cut -d' ' -f1)"
		if [[ "${remote_sum}" == "${local_sum}" ]]; then
			printf 'already published with identical bytes: %s\n' "${url}"
			return 0
		fi
		die 1 "${url} is already published with different bytes (${remote_sum:0:12} vs ${local_sum:0:12}); revbump zeo instead of reusing its name"
	fi

	cat <<EOF
wrote ${out} ($(stat -c %s "${out}") bytes)
sha256 ${local_sum}

next, once publishing is authorized:
  1. from the overlay checkout (wrangler profile 'bentoo'):
     npx --yes wrangler@<a release at least 7 days old> r2 object put obentoo-distfiles/${name}-amd64.tar.xz \\
       --file=${out} --content-type=application/x-xz --remote
  2. curl -sI https://distfiles.obentoo.org/${name}-amd64.tar.xz   # expect 200
  3. ebuild <overlay>/app-editors/zeo-bin/${name}.ebuild manifest
EOF
}

main "$@"
