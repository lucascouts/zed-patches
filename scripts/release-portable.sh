#!/usr/bin/env bash
# Build the portable Zeo artefacts -- .deb, .rpm, AppImage, Flatpak bundle and
# the plain tarball they all come from -- for one packaged version.
#
#     release-portable.sh <PF> [--skip-build] [--no-flatpak]
#
# zeo-bin cannot be repackaged for other distributions: it is linked against this
# host's glibc. This builds the same Zed commit and patch series again, inside the
# Debian 12 image in release/portable/Containerfile (glibc 2.36, x86-64-v3), then:
#
#   1. build-in-container.sh   applies the series, compiles, stages usr/, and
#                              refuses a binary needing glibc > 2.36 or AVX-512
#   2. package-in-container.sh tarball, .deb and .rpm (nfpm), AppImage
#   3. flatpak-builder (host)  the dev.zeo.Zeo bundle, from the same tarball
#   4. SHA256SUMS over every artefact
#
# Inputs come from where the zeo ebuild takes them: the Zed archive in DISTDIR,
# patches/<PF>/, the icons and the prebuilt WebRTC from the overlay. Everything
# else lives under ZP_PORTABLE_DIR (default ~/.cache/zeo-portable): <PF>/ holds
# one version's source and target, so a rerun recompiles little; sccache/ and
# cargo-home/ are shared by every version, so a new one starts warm and downloads
# no crate twice. --skip-build reuses the staged tree outright.
#
# It never publishes. The artefacts land in ${ZP_PORTABLE_DIR}/<PF>/out/dist,
# ready for `gh release upload` once a human authorises it.
#
# Exit: 0 written · 1 a step failed · 2 environment problem.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

main() {
	local pf="" skip_build=0 flatpak=1 arg
	for arg in "$@"; do
		case "${arg}" in
			--skip-build) skip_build=1 ;;
			--no-flatpak) flatpak=0 ;;
			-*) die 2 "unknown option: ${arg}" ;;
			*) pf="${arg}" ;;
		esac
	done
	[[ -n "${pf}" ]] || die 2 "usage: release-portable.sh <PF> [--skip-build] [--no-flatpak]"
	resolve_version "${pf}"

	local pvr="${pf#zeo-}" pv
	pv="${pvr%-r[0-9]*}"
	local here="${ZP_REPO}/release/portable"
	local cache="${ZP_PORTABLE_DIR:-${HOME}/.cache/zeo-portable}"
	local root="${cache}/${pf}"
	local patches="${ZP_REPO}/patches/${pf}"
	local files="${ZP_OVERLAY}/${ZP_CATEGORY_PATH}/files"
	local webrtc
	webrtc="$(grep -oE 'webrtc-[^ ]*-linux-x64-release\.zip' "$(dirname "${ZP_EBUILD}")/Manifest" | head -1)"

	[[ -f "${ZP_DISTFILE}" ]] || die 2 "Zed archive missing: ${ZP_DISTFILE} (ebuild ... fetch first)"
	[[ -f "${patches}/series" ]] || die 2 "no series: ${patches}/series"
	[[ -n "${webrtc}" && -f "${ZP_DISTDIR}/${webrtc}" ]] || die 2 "prebuilt WebRTC missing from ${ZP_DISTDIR}"
	[[ -f "${files}/app-icon-zeo.png" ]] || die 2 "icons missing from ${files}"
	command -v docker >/dev/null || die 2 "docker is required"

	local source_sha256
	source_sha256="$(sha256sum "${ZP_DISTFILE}" | cut -d' ' -f1)"
	mkdir -p "${root}/work" "${root}/out" "${cache}/sccache" "${cache}/cargo-home"
	local image
	image="zeo-portable:$(sha256sum "${here}/Containerfile" | cut -c1-12)"
	printf 'image %s\n' "${image}"
	# The tag is the Containerfile's hash, so an existing image is the one this
	# file describes; rebuilding it would only re-download the toolchain.
	if ! docker image inspect "${image}" >/dev/null 2>&1; then
		docker build -q -t "${image}" -f "${here}/Containerfile" "${here}" >/dev/null ||
			die 1 "the build image failed to build"
	fi

	local run=(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work
		-e "ZEO_PV=${pv}" -e "ZEO_PVR=${pvr}" -e "ZEO_COMMIT=${ZP_COMMIT}"
		-e "ZEO_SOURCE_SHA256=${source_sha256}"
		-v "${ZP_DISTFILE}:/in/zed.tar.gz:ro"
		-v "${patches}:/in/patches:ro"
		-v "${files}:/in/icons:ro"
		-v "${ZP_DISTDIR}/${webrtc}:/in/webrtc.zip:ro"
		-v "${here}:/pkg:ro"
		-v "${root}/work:/work"
		-v "${root}/out:/out"
		-v "${cache}/sccache:/sccache"
		-v "${cache}/cargo-home:/cargo-home"
		"${image}")

	if (( ! skip_build )); then
		"${run[@]}" bash /pkg/build-in-container.sh || die 1 "the portable build failed"
	fi
	[[ -d "${root}/out/zeo-${pvr}/usr" ]] || die 1 "no staged tree at ${root}/out/zeo-${pvr}"
	"${run[@]}" bash /pkg/package-in-container.sh || die 1 "packaging failed"

	local dist="${root}/out/dist"
	if (( flatpak )); then
		flatpak info --user org.flatpak.Builder >/dev/null 2>&1 ||
			die 2 "flatpak install --user flathub org.flatpak.Builder org.freedesktop.Sdk//25.08 first"
		local fp="${root}/flatpak"
		rm -rf "${fp}"
		mkdir -p "${fp}"
		cp "${here}/dev.zeo.Zeo.yml" "${fp}/"
		cp "${dist}/zeo-${pvr}-x86_64.tar.xz" "${fp}/zeo-portable.tar.xz"
		(cd "${fp}" &&
			flatpak run --filesystem="${fp}" org.flatpak.Builder --user --force-clean \
				--disable-rofiles-fuse --repo=repo build dev.zeo.Zeo.yml &&
			flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
				repo "${dist}/Zeo-${pvr}-x86_64.flatpak" dev.zeo.Zeo) ||
			die 1 "the Flatpak build failed"
	fi

	(cd "${dist}" && sha256sum -- * | grep -v ' SHA256SUMS' > "SHA256SUMS-portable-${pvr}")
	printf '\nartefacts in %s:\n' "${dist}"
	ls -la "${dist}"
}

main "$@"
