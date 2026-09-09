#!/usr/bin/env bash
# Query or activate a KWin window without injecting any input.
#
#     kwin_window.sh active                 print the active window's caption
#     kwin_window.sh list                   print every Zed window's caption
#     kwin_window.sh focus "<caption>"      activate the window with that exact caption
#
# KWin scripts have no return channel, so each run prints through a unique
# marker and the answer is read back out of the journal. The marker is what
# makes a stale line from an earlier run impossible to mistake for this one.
#
# Exit: 0 ok · 1 no such window · 2 environment problem.

set -euo pipefail

mode="${1:-}"
[[ -n "${mode}" ]] || { printf 'usage: %s active|list|focus <caption>\n' "${0##*/}" >&2; exit 2; }

marker="kwq$$_$(date +%s%N)"
tmp="$(mktemp --suffix=.js)"
trap 'rm -f "${tmp}"' EXIT

case "${mode}" in
	active)
		cat >"${tmp}" <<-EOF
			var w = workspace.activeWindow;
			print("${marker}|" + (w ? String(w.resourceClass) + "|" + String(w.caption) : "none|none"));
		EOF
		;;
	list)
		cat >"${tmp}" <<-EOF
			var wins = workspace.windowList();
			for (var i = 0; i < wins.length; i++) {
			    var w = wins[i];
			    if (String(w.resourceClass || "").toLowerCase().indexOf("zed") !== -1) {
			        print("${marker}|" + w.active + "|" + String(w.caption));
			    }
			}
		EOF
		;;
	focus)
		target="${2:-}"
		[[ -n "${target}" ]] || { printf 'focus needs a caption\n' >&2; exit 2; }
		# Embedded as JSON so a caption with quotes or an em dash cannot break out.
		json_target="$(printf '%s' "${target}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
		# Each project's window lives on its own virtual desktop here, and
		# focus alone does not follow: activeWindow can point at a window the
		# screen is not showing, so a capture would photograph the wrong
		# desktop while injection went to the right one. Switch, then focus.
		cat >"${tmp}" <<-EOF
			// A caption is "<project> — <open file>", so the file half changes
			// whenever the user switches tabs and an exact match goes stale
			// mid-run. A target with no em dash is matched on the project half
			// alone, which is the part that identifies the window.
			var want = ${json_target};
			var byProject = want.indexOf("\u2014") === -1;
			var wins = workspace.windowList();
			var hit = null;
			for (var i = 0; i < wins.length; i++) {
			    var cap = String(wins[i].caption);
			    if (String(wins[i].resourceClass || "").toLowerCase().indexOf("zed") === -1) continue;
			    var key = byProject ? cap.split("\u2014")[0].trim() : cap;
			    if (key === want) { hit = wins[i]; break; }
			}
			if (hit) {
			    var from = workspace.currentDesktop.name;
			    if (hit.desktops && hit.desktops.length > 0) {
			        workspace.currentDesktop = hit.desktops[0];
			    }
			    workspace.activeWindow = hit;
			    print("${marker}|ok|" + String(hit.caption) + "|from=" + from +
			          "|to=" + workspace.currentDesktop.name);
			} else {
			    print("${marker}|miss|" + wins.length);
			}
		EOF
		;;
	desktop)
		cat >"${tmp}" <<-EOF
			print("${marker}|" + workspace.currentDesktop.name);
		EOF
		;;
	setdesktop)
		want_desk="${2:-}"
		[[ -n "${want_desk}" ]] || { printf 'setdesktop needs a name\n' >&2; exit 2; }
		json_desk="$(printf '%s' "${want_desk}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
		cat >"${tmp}" <<-EOF
			var want = ${json_desk};
			var ds = workspace.desktops;
			for (var i = 0; i < ds.length; i++) {
			    if (String(ds[i].name) === want) {
			        workspace.currentDesktop = ds[i];
			        print("${marker}|ok|" + want);
			        break;
			    }
			}
		EOF
		;;
	*)
		printf 'unknown mode: %s\n' "${mode}" >&2; exit 2 ;;
esac

since="$(date '+%Y-%m-%d %H:%M:%S')"
name="kwq${marker}"
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
	loadScript ss "${tmp}" "${name}" >/dev/null
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting start >/dev/null
sleep 0.35
busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
	unloadScript s "${name}" >/dev/null 2>&1 || true

out="$(journalctl --user --since "${since}" --no-pager 2>/dev/null \
	| grep -F "${marker}|" | sed "s/.*${marker}|//" || true)"

[[ -n "${out}" ]] || { printf 'kwin script produced no output\n' >&2; exit 2; }
printf '%s\n' "${out}"

if [[ "${mode}" == "focus" || "${mode}" == "setdesktop" ]]; then
	[[ "${out}" == ok\|* ]] || exit 1
fi
