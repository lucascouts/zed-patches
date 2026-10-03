#!/usr/bin/env bash
# Runs inside the portable build image (Containerfile). Mirrors what the
# app-editors/zeo ebuild does in src_prepare/src_compile/src_install, minus the
# Portage-only parts (offline git-crate rewrites: cargo fetches here).
#
# Inputs (read-only mounts):  /in/zed.tar.gz  /in/patches/{series,*.patch}
#                             /in/icons/app-icon-zeo{,@2x}.png  /in/webrtc.zip
# Cache (read-write):         /work   -- source tree and cargo target, this version's
#                             /cargo-home, /sccache -- shared by every version
# Output:                     /out/zeo-<PVR>/usr/...
# Environment:                ZEO_PV (e.g. 0.1.0_p20261003), ZEO_PVR (+ -rN),
#                             ZEO_COMMIT and ZEO_SOURCE_SHA256 (for PROVENANCE.txt)
set -euo pipefail

: "${ZEO_PV:?}" "${ZEO_PVR:?}" "${ZEO_COMMIT:?}" "${ZEO_SOURCE_SHA256:?}"
readonly src=/work/src stage="/out/zeo-${ZEO_PVR}"
readonly max_glibc=2.36

log() { printf '[portable] %s\n' "$*"; }

log "unpacking Zed"
rm -rf "${src}"
mkdir -p "${src}"
tar -xzf /in/zed.tar.gz -C "${src}" --strip-components=1

log "applying the series"
cd "${src}"
n=0
while IFS= read -r patch; do
	[[ -z "${patch}" || "${patch}" == \#* ]] && continue
	patch -p1 --no-backup-if-mismatch --quiet < "/in/patches/${patch}"
	n=$((n + 1))
done < /in/patches/series
log "${n} patches applied"

# src_prepare: icons, release channel, desktop entry -- byte for byte the edits
# the ebuild makes, so a .deb and the Gentoo package carry the same entry.
cp /in/icons/app-icon-zeo.png /in/icons/app-icon-zeo@2x.png crates/zed/resources/
echo "zeo" > crates/zed/RELEASE_CHANNEL
export APP_CLI="zeo" APP_ID="dev.zeo.Zeo" APP_ICON="dev.zeo.Zeo" APP_NAME="Zeo" \
	APP_ARGS="%U" DO_STARTUP_NOTIFY="true"
envsubst < crates/zed/resources/zed.desktop.in > "${APP_ID}.desktop"
sed -i "/^Actions=/i StartupWMClass=${APP_ID}" "${APP_ID}.desktop"
sed -i "s|x-scheme-handler/zed|x-scheme-handler/zeo|" "${APP_ID}.desktop"
sed -i "s|^Keywords=zed;|Keywords=zeo;zed;|" "${APP_ID}.desktop"
desktop-file-validate "${APP_ID}.desktop"

log "unpacking the prebuilt WebRTC the ebuild uses"
rm -rf /work/webrtc
mkdir -p /work/webrtc
unzip -q /in/webrtc.zip -d /work/webrtc

# src_compile. RUSTFLAGS replaces .cargo/config.toml's rustflags instead of adding
# to them, so Zed's own two flags are repeated here next to the CPU target.
export RELEASE_VERSION="${ZEO_PV}" RELEASE_CHANNEL="zeo"
export ZED_UPDATE_EXPLANATION="Update Zeo where you installed it: your package manager, Flatpak, or a new AppImage from https://github.com/zeo-workspace/zeo/releases"
export LK_CUSTOM_WEBRTC=/work/webrtc/linux-x64-release
export RUSTFLAGS="-C target-cpu=x86-64-v3 -C symbol-mangling-version=v0 --cfg tokio_unstable"
export CFLAGS="-O2 -march=x86-64-v3" CXXFLAGS="-O2 -march=x86-64-v3"
# clang, as upstream's script/bundle-linux uses: Debian 12's GCC 12 rejects the
# prebuilt WebRTC headers ("declaration ... changes meaning of 'Network'"), and
# the -Wno-changes-meaning that webrtc-sys passes to silence it only exists from
# GCC 13 on. The diagnostic is GCC's alone.
export CC=clang CXX=clang++
export CARGO_TARGET_DIR=/work/target CARGO_HOME=/cargo-home
# sccache keys every entry on the exact rustc, so it only ever hits entries this
# image wrote -- which is why it is a cache of its own and not Portage's
# /var/cache/sccache (also unreadable here: its entries are mode 0600, portage's).
# The paths in the key (/work/src, /cargo-home) are the same for every version.
export RUSTC_WRAPPER=sccache SCCACHE_DIR=/sccache SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-30G}"
sccache --zero-stats >/dev/null
log "building (cargo build --release --locked)"
cargo build --release --locked --package zed --package cli --features zed/mimalloc
sccache --show-stats | grep -E '^(Compile requests|Cache hits|Cache misses|Cache size)' |
	sed 's/^/[portable] sccache: /'
sccache --stop-server >/dev/null

# AVX-512, checked on the unstripped binary so each instruction has a function
# name. Hand-written assembly kernels that pick an AVX-512 path at run time
# (dav1d, aws-lc) carry it on purpose and never run it on a CPU without it;
# compiler-generated code does not check, so one Rust or C++ function using it
# means the binary dies with SIGILL on a CPU below AVX-512. That is exactly what
# Gentoo's zeo-bin shipped until 0.1.0_p20261003-r1: the host's Rust standard
# library was built for znver5. The whole disassembly is read (awk, no grep -q),
# because `objdump | grep -q` under pipefail reported 141 from SIGPIPE and the
# old check passed every time.
log "checking for compiler-generated AVX-512"
avx512_fns="$(objdump -d --no-show-raw-insn /work/target/release/zeo | awk '
	/^[0-9a-f]+ <.*>:$/ { fn = $2 }
	/%zmm[0-9]|\{%k[1-7]\}/ { if (fn ~ /^<_R/ || fn ~ /^<_ZN/) bad[fn] = 1 }
	END { for (f in bad) print f }')"
if [[ -n "${avx512_fns}" ]]; then
	echo "error: compiler-generated code uses AVX-512 (would SIGILL below AVX-512):" >&2
	printf '%s\n' "${avx512_fns}" | head -20 >&2
	exit 1
fi

# src_install, into a staging tree laid out like zeo-bin's.
log "staging ${stage}"
rm -rf "${stage}"
install -Dm755 /work/target/release/cli "${stage}/usr/bin/zeo"
install -Dm755 /work/target/release/zeo "${stage}/usr/libexec/zeo-editor"
install -Dm644 "${APP_ID}.desktop" "${stage}/usr/share/applications/${APP_ID}.desktop"
install -Dm644 crates/zed/resources/app-icon-zeo.png \
	"${stage}/usr/share/icons/hicolor/512x512/apps/${APP_ID}.png"
install -Dm644 crates/zed/resources/app-icon-zeo@2x.png \
	"${stage}/usr/share/icons/hicolor/1024x1024/apps/${APP_ID}.png"
strip --strip-unneeded "${stage}/usr/bin/zeo" "${stage}/usr/libexec/zeo-editor"

# The point of this build: refuse a binary that needs a newer glibc than the
# oldest distribution it claims.
for bin in "${stage}/usr/bin/zeo" "${stage}/usr/libexec/zeo-editor"; do
	need="$(objdump -T "${bin}" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
	if [[ "$(printf '%s\n%s\n' "${need}" "${max_glibc}" | sort -V | tail -1)" != "${max_glibc}" ]]; then
		echo "error: ${bin##*/} needs glibc ${need}, above ${max_glibc}" >&2
		exit 1
	fi
	log "${bin##*/}: highest glibc symbol ${need}"
done

# PROVENANCE.txt, in the format zeo-bin has always carried, naming this build's
# real toolchain instead of the Gentoo one.
{
	printf 'zeo %s -- provenance\n\n' "${ZEO_PVR}"
	printf 'built from     zed-patches release/portable (Debian 12 container), series zeo-%s\n' "${ZEO_PVR}"
	printf 'zed version    %s\n' "$(grep -m1 '^version' crates/zed/Cargo.toml | cut -d'"' -f2)"
	printf 'zed commit     %s\n' "${ZEO_COMMIT}"
	printf 'zed source     https://github.com/zed-industries/zed/archive/%s.tar.gz\n' "${ZEO_COMMIT}"
	printf 'source sha256  %s\n' "${ZEO_SOURCE_SHA256}"
	printf 'features       zed/mimalloc\n'
	printf 'rustc          %s (official toolchain, rustup)\n' "$(rustc --version)"
	printf 'cc / c++       %s\n' "$(clang --version | head -1)"
	printf 'CFLAGS         %s\n' "${CFLAGS}"
	printf 'RUSTFLAGS      %s\n' "${RUSTFLAGS}"
	printf 'glibc          needs %s at most (ceiling checked: %s)\n\n' \
		"$(objdump -T "${stage}/usr/libexec/zeo-editor" "${stage}/usr/bin/zeo" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)" \
		"${max_glibc}"
	printf 'patches, in apply order (sha256):\n'
	while IFS= read -r patch; do
		[[ -z "${patch}" || "${patch}" == \#* ]] && continue
		printf '  %s  %s\n' "$(sha256sum "/in/patches/${patch}" | cut -d' ' -f1)" "${patch}"
	done < /in/patches/series
	printf '\nNEEDED (usr/libexec/zeo-editor):\n'
	objdump -p "${stage}/usr/libexec/zeo-editor" | awk '/NEEDED/ { print "  " $2 }'
	printf '\nThe Corresponding Source is the zed source above plus these patches,\n'
	printf 'published in the bentoo overlay under app-editors/zeo/files/.\n'
} > "${stage}/PROVENANCE.txt"
log "done"
