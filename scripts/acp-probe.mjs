#!/usr/bin/env node
// acp-probe.mjs — drive an ACP adapter over stdio, without Zed, and print what
// crosses the wire.
//
//     acp-probe.mjs init <adapter> [args...]
//     acp-probe.mjs plan <adapter> [--cwd DIR] [--from MODE] [args...]
//     acp-probe.mjs fallback <adapter> [--notices] [args...]
//     acp-probe.mjs load <adapter> --session ID --cwd DIR [args...]
//
// <adapter> is an executable (/usr/bin/claude-agent-acp-plus) or a .js entry
// point (dist/index.js), which is run with this node.
//
//   init  send a full-capability `initialize` and print the result as JSON:
//         what the adapter ADVERTISES, read off the wire rather than argued from
//         commits. No model turn, no cost.
//   plan  put a fresh session in plan mode (optionally entering it FROM another
//         mode, e.g. bypassPermissions), ask for a one-step plan, approve it
//         without clearing context, and print the permission options offered and
//         every mode / config update that follows. ONE REAL MODEL TURN on the
//         account the adapter runs as.
//   fallback  for each model the session offers, select it and ask for Auto;
//         print every update that answers. A model without Auto support makes
//         the adapter fall back and warn -- as a `notice` when the client
//         advertised `session.notices` (--notices), as a transcript line
//         otherwise. No model turn, no cost.
//   load  session/load an existing session and count what the replay sends:
//         user and agent message chunks, and the first user text. Loading
//         APPENDS to the transcript, so point it at a copy. No model turn.
//
// Why it is versioned: every parity round from the 2026-09-11 one on wrote this
// probe fresh into /tmp (acp-probe2..6, acp-probe-plan) and lost it with the
// next cleanup, although it is the only instrument that separates an adapter
// fault from a client fault. Exit: 0 finished · 1 the adapter answered an error
// or the turn timed out · 2 usage.

import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";

const [mode, adapter, ...rest] = process.argv.slice(2);
if (!["init", "plan", "fallback", "load"].includes(mode) || !adapter) {
  console.error(
    "usage: acp-probe.mjs init|plan|fallback|load <adapter> [--cwd DIR] [--from MODE] [--notices] [--session ID] [args...]",
  );
  process.exit(2);
}

const opts = {
  cwd: process.cwd(),
  from: undefined,
  notices: false,
  session: undefined,
  args: [],
};
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === "--cwd") opts.cwd = rest[++i];
  else if (rest[i] === "--from") opts.from = rest[++i];
  else if (rest[i] === "--notices") opts.notices = true;
  else if (rest[i] === "--session") opts.session = rest[++i];
  else opts.args.push(rest[i]);
}
mkdirSync(opts.cwd, { recursive: true });

// An argument list, never a shell: the adapter path and its arguments are data.
const [command, args] = adapter.endsWith(".js")
  ? [process.execPath, [adapter, ...opts.args]]
  : [adapter, opts.args];
const child = spawn(command, args, {
  cwd: opts.cwd,
  stdio: ["pipe", "pipe", "inherit"],
});

let nextId = 1;
const pending = new Map();
const log = (tag, obj) => console.log(JSON.stringify({ tag, ...obj }));
const send = (msg) =>
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
const request = (method, params) => {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
};
const finish = (code) => {
  child.kill();
  process.exit(code);
};

const replay = { user: 0, agent: 0, firstUser: undefined };
let buffer = "";
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.id !== undefined && !msg.method) {
      const waiter = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? waiter.reject(msg.error) : waiter.resolve(msg.result);
    } else if (msg.method === "session/update") {
      const u = msg.params.update;
      if (u.sessionUpdate === "user_message_chunk") {
        replay.user++;
        replay.firstUser ??= u.content?.text?.slice(0, 60);
      } else if (u.sessionUpdate === "agent_message_chunk" && mode === "load")
        replay.agent++;
      else if (u.sessionUpdate === "current_mode_update")
        log("MODE", { mode: u.currentModeId });
      else if (u.sessionUpdate === "config_option_update")
        log("CONFIG", {
          mode: u.configOptions.find((o) => o.id === "mode")?.currentValue,
        });
      else if (u.sessionUpdate === "tool_call") log("TOOL", { title: u.title });
      else if (u.sessionUpdate === "notice")
        log("NOTICE", {
          severity: u.severity,
          title: u.title,
          description: u.description,
        });
      else if (u.sessionUpdate === "agent_message_chunk" && mode === "fallback")
        log("TRANSCRIPT", { text: u.content?.text, meta: u._meta });
    } else if (msg.method === "session/request_permission") {
      log("PERMISSION", {
        tool: msg.params.toolCall?.title,
        options: msg.params.options.map(
          (o) => `${o.optionId}:${o.kind}:${o.name}`,
        ),
      });
      // Approve without clearing context: the first allow option that names no reset.
      const pick =
        msg.params.options.find(
          (o) => o.kind.startsWith("allow") && !/clear|fresh/i.test(o.name),
        ) ?? msg.params.options[0];
      log("PICK", { optionId: pick.optionId });
      send({
        id: msg.id,
        result: { outcome: { outcome: "selected", optionId: pick.optionId } },
      });
    } else if (msg.id !== undefined && msg.method) {
      // fs/terminal requests: this probe offers none of them.
      send({
        id: msg.id,
        error: { code: -32601, message: "not supported by acp-probe" },
      });
    }
  }
});

setTimeout(() => {
  log("TIMEOUT", {});
  finish(1);
}, 240_000).unref();

try {
  const init = await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      terminal: true,
      _meta: { terminal_output: true, "terminal-auth": true },
      ...(opts.notices ? { session: { notices: {} } } : {}),
    },
  });
  if (mode === "init") {
    console.log(JSON.stringify(init, null, 2));
    finish(0);
  }

  if (mode === "load") {
    await request("session/load", {
      sessionId: opts.session,
      cwd: opts.cwd,
      mcpServers: [],
    });
    log("REPLAY", replay);
    finish(0);
  }
  const session = await request("session/new", {
    cwd: opts.cwd,
    mcpServers: [],
  });
  log("SESSION", {
    current: session.modes?.currentModeId,
    modes: session.modes?.availableModes?.map((m) => m.id),
  });
  if (mode === "fallback") {
    const models =
      session.configOptions?.find((o) => o.id === "model")?.options ?? [];
    for (const model of models) {
      const value = model.value ?? model.id;
      await request("session/set_mode", {
        sessionId: session.sessionId,
        modeId: "default",
      });
      await request("session/set_config_option", {
        sessionId: session.sessionId,
        configId: "model",
        value,
      });
      log("MODEL", { value });
      await request("session/set_mode", {
        sessionId: session.sessionId,
        modeId: "auto",
      });
      await new Promise((r) => setTimeout(r, 300));
    }
    finish(0);
  }
  for (const modeId of [opts.from, "plan"].filter(Boolean)) {
    await request("session/set_mode", { sessionId: session.sessionId, modeId });
  }
  const result = await request("session/prompt", {
    sessionId: session.sessionId,
    prompt: [
      {
        type: "text",
        text:
          "Plan only, do not explore: the plan is to create hello.txt containing 'hi'. " +
          "Write that one-step plan and call ExitPlanMode immediately. After approval, stop " +
          "without doing anything else.",
      },
    ],
  });
  log("DONE", { stopReason: result.stopReason });
  finish(0);
} catch (error) {
  log("ERROR", { error });
  finish(1);
}
