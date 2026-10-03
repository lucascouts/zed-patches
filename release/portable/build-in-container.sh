#!/usr/bin/env bash
# Runs inside the portable build image (Containerfile). Mirrors what the
# app-editors/zeo ebuild does in src_prepare/src_compile/src_install, minus the
# Portage-only parts (offline git-crate rewrites: cargo fetches here).
#
# Inputs (read-only mounts):  /in/zed.tar.gz  /in/patches/{series,*.patch}
#                             /in/icons/app-icon-zeo{,@2x}.png  /in/webrtc.zip
# Cache (read-write):         /work   -- source tree, cargo target, cargo registry
# Output:                     /out/zeo-<PVR>/usr/...
# Environment:                ZEO_PV (e.g. 0.1.0_p20261003), ZEO_PVR (+ -rN)
set -euo pipefail

: "${ZEO_PV:?}" "${ZEO_PVR:?}"
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
export CARGO_TARGET_DIR=/work/target CARGO_HOME=/work/cargo-home
log "building (cargo build --release --locked)"
cargo build --release --locked --package zed --package cli --features zed/mimalloc

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
# oldest distribution it claims, or that carries AVX-512 (x86-64-v3 has none).
for bin in "${stage}/usr/bin/zeo" "${stage}/usr/libexec/zeo-editor"; do
	need="$(objdump -T "${bin}" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
	if [[ "$(printf '%s\n%s\n' "${need}" "${max_glibc}" | sort -V | tail -1)" != "${max_glibc}" ]]; then
		echo "error: ${bin##*/} needs glibc ${need}, above ${max_glibc}" >&2
		exit 1
	fi
	log "${bin##*/}: highest glibc symbol ${need}"
done
if objdump -d --no-show-raw-insn "${stage}/usr/libexec/zeo-editor" | grep -qE '%zmm[0-9]|\{%k[1-7]\}'; then
	echo "error: zeo-editor carries AVX-512 instructions" >&2
	exit 1
fi
log "done"
