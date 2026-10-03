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
# The tarball is published as an asset of the Zeo GitHub release tagged
# v<PVR> (zeo-workspace/zeo), which the zeo-bin ebuild's SRC_URI names. A name
# that release already serves is checked first: identical bytes end the run with
# nothing to upload, different bytes are refused (ZP_RELEASE_URL overrides the
# download base, for testing). It never uploads or tags: publishing is a remote,
# outward-facing step that a human authorizes each time.
#
# Refuses to package a binary that is not portable: one built with a target CPU
# other than x86-64-v3, or one carrying AVX-512 instructions.
#
# Exit: 0 written or already published · 1 the build is not releasable, or its
# name is already published with other bytes · 2 environment problem.

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

	# AVX-512, on the unstripped binary so each instruction has a function name.
	# Assembly kernels that choose an AVX-512 path at run time (dav1d, aws-lc)
	# are fine; compiler-generated Rust or C++ code is not, because it never
	# checks the CPU. The disassembly is read whole: the old
	# `objdump | grep -q` exited 141 from SIGPIPE under pipefail and so passed
	# every release until 0.1.0_p20261003-r1, which carried 85 such functions
	# from this host's Rust standard library (built for znver5). zeo-bin is
	# built by release-portable.sh since -r2; this check keeps this path honest.
	local unstripped
	unstripped="$(find "${builddir}/work" -path '*/target/release/zeo' -type f 2>/dev/null | head -1)"
	[[ -n "${unstripped}" ]] || die 2 "no unstripped target/release/zeo under ${builddir}/work"
	printf 'scanning %s for compiler-generated AVX-512\n' "${unstripped}"
	local avx512_fns
	avx512_fns="$(objdump -d --no-show-raw-insn "${unstripped}" | awk '
		/^[0-9a-f]+ <.*>:$/ { fn = $2 }
		/%zmm[0-9]|\{%k[1-7]\}/ { if (fn ~ /^<_R/ || fn ~ /^<_ZN/) bad[fn] = 1 }
		END { for (f in bad) n++; print n + 0 }')"
	(( avx512_fns == 0 )) ||
		die 1 "${avx512_fns} compiler-generated functions use AVX-512; the binary would SIGILL below AVX-512"

	# The revision stays in the name. A zeo revbump changes the binary, so it is a
	# different artefact: dropping -rN would put new bytes under a name a release
	# already serves and a Manifest already pins. zeo-bin mirrors zeo's PVR, and its
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

	# A name the release already serves is a published artefact. Identical bytes
	# mean there is nothing to upload; different bytes mean this build must not
	# take that name, because the zeo-bin Manifest pins the published ones.
	# -L: GitHub answers a release download with a redirect to its asset store.
	local base="${ZP_RELEASE_URL:-https://github.com/zeo-workspace/zeo/releases/download}"
	local url="${base}/v${pv}/${name}-amd64.tar.xz" remote_sum local_sum
	local_sum="$(sha256sum "${out}" | cut -d' ' -f1)"
	if curl -sfIL "${url}" >/dev/null 2>&1; then
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

next, once publishing is authorized (zeo-workspace/zeo releases):
  1. tag v${pv}: in zed-patches on the commit that holds patches/${pf}/, and in zeo
     on its HEAD -- annotated, then git push origin v${pv} in each
  2. in a scratch directory:
     tar -xOJf ${out} ${name}/PROVENANCE.txt > PROVENANCE-${pv}.txt
     sha256sum ${out##*/} PROVENANCE-${pv}.txt > SHA256SUMS-${pv}   # with the tarball copied beside them
     gh release create v${pv} -R zeo-workspace/zeo --verify-tag -t "Zeo ${pv}" -F <notes.md> \\
       ${name}-amd64.tar.xz PROVENANCE-${pv}.txt SHA256SUMS-${pv}
  3. curl -sfL ${url} | sha256sum   # expect ${local_sum}
  4. ebuild <overlay>/app-editors/zeo-bin/${name}.ebuild manifest
EOF
}

main "$@"
