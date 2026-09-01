#!/usr/bin/env bash
# Answer whether the Claude Code CLI still speaks the protocol patch 0002 implements.
#
#     check-protocol.sh [--no-live]
#
# Patch 0002 runs on two clocks. Zed's Rust API is watched by verify.sh and fails
# loudly -- the patch stops applying. The CLI's wire protocol is watched by nothing
# and fails silently: the patch applies, Zed builds, every other check is green, and
# `/ide` reports no IDE. That is not hypothetical. It is what happened between
# 2026-08-12, when the breakage was reported publicly, and 2026-08-29, when it was
# found here.
#
# So this script asks a question the rest of the tooling cannot: does the CLI on
# this machine still want what we send it? It answers from the shipped binary --
# there is no specification, and the CLI is a Bun executable whose JavaScript
# survives as string literals -- and, when a patched Zed is running, from the wire.
#
# The contract itself is documented in terminal-ide/CLAUDE.md; this is its gate.
# Run it at every dev-util/claude-code bump, not at every Zed bump.
#
# --no-live skips the probe against a running Zed, leaving only the static checks.
#
# Exit: 0 contract intact (or not askable) · 1 drift · 2 environment problem.

set -euo pipefail

# --- what the CLI required when this was last derived --------------------------
#
# Anchored on string literals, never on minified identifiers: the literals are
# part of the protocol and survive a rebuild, the identifiers are renamed by the
# bundler on every release.

readonly EXPECT_PARSER='return{workspaceFolders:'
readonly EXPECT_FIELD='useWebSocket'
readonly EXPECT_TRANSPORT='if(u.useWebSocket)K=`ws://'
readonly EXPECT_SUBPROTOCOL='protocols:["mcp"]'
readonly EXPECT_AUTH_HEADER='X-Claude-Code-Ide-Authorization'

# Derived against claude 2.1.251 on 2026-08-29; re-confirmed unchanged on 2.1.252.
readonly DERIVED_AGAINST='2.1.251'

drift=0
strings_file=""

cleanup() { [[ -z "${strings_file}" ]] || rm -f "${strings_file}"; }
trap cleanup EXIT

line() { printf '  %-11s %s\n' "$1" "$2"; }
ok() { line ok "$1"; }
skip() { line skipped "$1"; }
bad() {
	line DRIFT "$1"
	drift=1
}

usage() {
	printf 'usage: %s [--no-live]\n' "${0##*/}" >&2
	exit 2
}

# --- static: what the CLI asks for ---------------------------------------------

# expect <needle> <description> -- one contract clause, present or gone.
expect() {
	local needle="$1" description="$2"
	if grep -qF -- "${needle}" "${strings_file}"; then
		ok "${description}"
	else
		bad "${description} -- '${needle}' is gone from the CLI"
	fi
}

check_cli() {
	local cli resolved
	cli="$(command -v claude 2>/dev/null || true)"
	if [[ -z "${cli}" ]]; then
		skip 'no claude on PATH -- the contract cannot be read'
		return 0
	fi
	resolved="$(readlink -f "${cli}")"

	local version
	version="$(claude --version 2>/dev/null | awk '{print $1}')" || version="unknown"
	if [[ "${version}" == "${DERIVED_AGAINST}" ]]; then
		line version "${version} (the version this was derived against)"
	else
		line version "${version} -- derived against ${DERIVED_AGAINST}; clauses re-checked below"
	fi

	strings_file="$(mktemp)"
	strings -n 4 "${resolved}" >"${strings_file}" 2>/dev/null ||
		{ skip 'cannot read strings from the CLI binary'; return 0; }

	expect "${EXPECT_PARSER}" 'lock file is still parsed field-by-field'
	expect "${EXPECT_FIELD}" "lock file is still read for '${EXPECT_FIELD}'"
	expect "${EXPECT_TRANSPORT}" 'useWebSocket still selects the ws:// URL'
	expect "${EXPECT_SUBPROTOCOL}" 'the CLI still offers the mcp subprotocol'
	expect "${EXPECT_AUTH_HEADER}" 'the auth header name is unchanged'

	# A field the CLI reads and we never write is a silent default, not an error --
	# but it is how the useWebSocket bug looked right up until it was found.
	local parsed field
	parsed="$(grep -oF -m1 -- "${EXPECT_PARSER}" "${strings_file}" >/dev/null &&
		grep -o "${EXPECT_PARSER}[^}]*}" "${strings_file}" | head -n1)" || parsed=""
	if [[ -n "${parsed}" ]]; then
		for field in $(printf '%s' "${parsed}" | grep -oE '[a-zA-Z]+:' | tr -d ':'); do
			case "${field}" in
			workspaceFolders | port | pid | ideName | useWebSocket | runningInWindows | authToken | parseInt) ;;
			*) line note "the CLI now also reads '${field}' -- check whether we should write it" ;;
			esac
		done
	fi
}

# --- live: what a running Zed actually puts on the wire -------------------------

# probe_handshake <port> <token> -- the 101 must name the subprotocol back, and a
# request without the token must not get one at all.
probe_handshake() {
	local port="$1" token="$2" response=""

	# `timeout` exits 124 when it kills nc, which is the normal end of a websocket
	# probe -- the server has no reason to hang up. Under `pipefail` that status
	# would fail the substitution and throw away the bytes already read, so the
	# pipeline swallows its own status instead of the caller discarding the output.
	response="$( { printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcp\r\nX-Claude-Code-Ide-Authorization: %s\r\n\r\n' \
		"${port}" "${token}" | timeout 4 nc 127.0.0.1 "${port}" 2>/dev/null |
		head -c 512 | tr '[:upper:]' '[:lower:]'; } || true)"

	if [[ "${response}" != http/1.1\ 101* ]]; then
		bad "port ${port}: no websocket upgrade (got '${response%%$'\r'*}')"
		return 0
	fi
	if [[ "${response}" != *sec-websocket-protocol:\ mcp* ]]; then
		bad "port ${port}: the 101 named no subprotocol -- the CLI closes this with 1002"
		return 0
	fi

	local denied
	denied="$( { printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcp\r\n\r\n' \
		"${port}" | timeout 4 nc 127.0.0.1 "${port}" 2>/dev/null | head -c 64; } || true)"
	if [[ "${denied}" != HTTP/1.1\ 401* ]]; then
		bad "port ${port}: an unauthenticated upgrade was not refused"
		return 0
	fi

	ok "port ${port}: upgrade echoes mcp, unauthenticated upgrade refused"
}

check_live() {
	local dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/ide"
	if [[ ! -d "${dir}" ]]; then
		skip "no lock-file directory at ${dir} -- is a patched Zed running?"
		return 0
	fi

	local -a locks=()
	mapfile -t locks < <(find "${dir}" -maxdepth 1 -name '*.lock' -print 2>/dev/null | sort)
	if ((${#locks[@]} == 0)); then
		skip 'no lock files -- no patched Zed is running'
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1 || ! command -v nc >/dev/null 2>&1; then
		skip 'jq and nc are both needed to probe a running Zed'
		return 0
	fi

	# One window is enough: every window of one Zed writes the same shape. Probing
	# all of them would say the same thing N times and open N sockets to do it.
	local lock port token ide
	lock="${locks[0]}"
	port="$(basename "${lock}" .lock)"
	ide="$(jq -r '.ideName // ""' "${lock}" 2>/dev/null)" || ide=""
	if [[ "${ide}" != "Zed" ]]; then
		skip "${port}.lock is not ours (ideName=${ide:-none})"
		return 0
	fi

	if [[ "$(jq -r '.useWebSocket // false' "${lock}" 2>/dev/null)" == "true" ]]; then
		ok "port ${port}: lock file selects the websocket transport"
	else
		bad "port ${port}: lock file has no useWebSocket -- the CLI will try http://.../sse"
	fi

	# Read into a variable and never echo it: the token is the whole access control.
	token="$(jq -r '.authToken // ""' "${lock}" 2>/dev/null)" || token=""
	if [[ -z "${token}" ]]; then
		bad "port ${port}: lock file carries no authToken"
		return 0
	fi
	probe_handshake "${port}" "${token}"
}

main() {
	local live=1 arg
	for arg in "$@"; do
		case "${arg}" in
		--no-live) live=0 ;;
		-h | --help) usage ;;
		*) printf 'unknown option: %s\n' "${arg}" >&2 && usage ;;
		esac
	done

	printf '\n\033[1mclaude-code protocol contract\033[0m\n'
	check_cli
	if ((live == 1)); then
		check_live
	else
		skip '--no-live -- the running Zed was not probed'
	fi

	printf '\n'
	if ((drift == 0)); then
		printf 'the contract holds\n'
		return 0
	fi
	printf 'the contract drifted -- see the lines marked DRIFT above\n'
	printf 'terminal-ide/CLAUDE.md documents how to re-derive it, and discussion\n'
	printf '#58338 is where such breakage is usually reported first.\n'
	return 1
}

main "$@"
