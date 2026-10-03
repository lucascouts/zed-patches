#!/usr/bin/env bash
# Runs inside the portable build image after build-in-container.sh. Turns the
# staging tree into the four artefacts that do not need Flatpak tooling.
#
# Inputs:  /out/zeo-<PVR>/usr   the staged build
#          /pkg                 this directory (nfpm.yaml, metainfo)
# Output:  /out/dist/  zeo-<PVR>-x86_64.tar.xz  zeo_<ver>-<rel>_amd64.deb
#                      zeo-<ver>-<rel>.x86_64.rpm  Zeo-<PVR>-x86_64.AppImage
# Environment: ZEO_PV, ZEO_PVR
set -euo pipefail

: "${ZEO_PV:?}" "${ZEO_PVR:?}"
readonly stage="/out/zeo-${ZEO_PVR}" dist=/out/dist
log() { printf '[package] %s\n' "$*"; }

rm -rf "${dist}"
mkdir -p "${dist}"
install -Dm644 /pkg/dev.zeo.Zeo.metainfo.xml "${stage}/usr/share/metainfo/dev.zeo.Zeo.metainfo.xml"

# 1. The portable tarball: the staged usr/ tree, deterministic like zeo-bin's.
log "tarball"
epoch=0
[[ "${ZEO_PV}" =~ _p([0-9]{8}) ]] && epoch="$(date -u -d "${BASH_REMATCH[1]}" +%s)"
XZ_OPT=-9T0 tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${epoch}" \
	-C /out -cJf "${dist}/zeo-${ZEO_PVR}-x86_64.tar.xz" "zeo-${ZEO_PVR}"

# 2. .deb and .rpm. 0.1.0_p20261003-r1 -> version 0.1.0~p20261003, release 2.
revision=0
[[ "${ZEO_PVR}" =~ -r([0-9]+)$ ]] && revision="${BASH_REMATCH[1]}"
export ZEO_STAGE="${stage}" ZEO_VERSION="${ZEO_PV/_p/~p}" ZEO_RELEASE=$((revision + 1))
# nfpm expands the environment in a few fields only, not in contents' src paths,
# so the config is expanded here, and only for these three names.
# shellcheck disable=SC2016  # the names are for envsubst, not for this shell
envsubst '${ZEO_STAGE} ${ZEO_VERSION} ${ZEO_RELEASE}' < /pkg/nfpm.yaml > /out/nfpm.yaml
for packager in deb rpm; do
	log "${packager}"
	nfpm package --config /out/nfpm.yaml --packager "${packager}" --target "${dist}/"
done

# 3. AppImage. AppRun execs the editor binary itself, not the zeo CLI: the CLI
# spawns the editor and exits, and an AppImage unmounts when its first process
# exits, which would pull the files out from under the running editor.
# libxkbcommon(-x11) ride along, with the libxcb-xkb the -x11 half needs, because they are the two libraries the binary
# links that a minimal desktop install can lack; everything else it needs
# (glibc, glib, alsa, xcb, wayland, vulkan, X11) is on any desktop, and
# AppImage convention is to not bundle those.
log "AppImage"
appdir=/out/AppDir
rm -rf "${appdir}"
mkdir -p "${appdir}/usr/lib"
cp -a "${stage}/usr/." "${appdir}/usr/"
# libxcb-xkb comes with libxkbcommon-x11, which needs it.
for lib in libxkbcommon.so.0 libxkbcommon-x11.so.0 libxcb-xkb.so.1; do
	cp -L "/usr/lib/x86_64-linux-gnu/${lib}" "${appdir}/usr/lib/"
done
cat > "${appdir}/AppRun" <<'EOF'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${here}/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${here}/usr/libexec/zeo-editor" "$@"
EOF
chmod 755 "${appdir}/AppRun"
cp "${stage}/usr/share/applications/dev.zeo.Zeo.desktop" "${appdir}/"
cp "${stage}/usr/share/icons/hicolor/512x512/apps/dev.zeo.Zeo.png" "${appdir}/"
ln -s dev.zeo.Zeo.png "${appdir}/.DirIcon"
# -n: no AppStream validation (appstreamcli is not in the image); the metainfo
# is still shipped inside the AppDir.
ARCH=x86_64 appimagetool -n --runtime-file /opt/appimage-runtime-x86_64 \
	"${appdir}" "${dist}/Zeo-${ZEO_PVR}-x86_64.AppImage"

ls -la "${dist}"
log "done"
