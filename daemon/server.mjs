// omarchy-pi daemon: one long-lived pi agent session, driven by the pi SDK
// with the user's ~/.pi config (settings, auth, models, skills, extensions,
// prompts, AGENTS.md). Clients (the Omarchy panel) attach over a unix socket
// speaking JSONL; closing a client never touches the agent.
//
// client -> daemon: {op:"prompt",text} {op:"abort"} {op:"new"}
//                   {op:"resume",path} {op:"sessions",query} {op:"sync"}
// daemon -> client: {ev:"snapshot",...} {ev:"start"} {ev:"delta",text}
//                   {ev:"end",text} {ev:"tool",name,detail} {ev:"busy",value}
//                   {ev:"error",text} {ev:"sessions",list}
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import {
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  getAgentDir,
  SessionManager,
} from "@earendil-works/pi-coding-agent";

const SOCKET = path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), "omarchy-pi.sock");
const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "omarchy-pi");
const LAST_FILE = path.join(STATE_DIR, "last-session");
const HISTORY_LIMIT = 80;
const TEXT_LIMIT = 20000;

// Same built-ins the pi CLI loads; the SDK leaves them out by default.
const builtins = [
  { name: "codemode", factory: createCodemodeExtension(), replaceable: true, builtin: true },
  { name: "tool-search", factory: createToolSearchExtension(), replaceable: true, builtin: true },
  { name: "mcp", factory: createMcpExtension(), replaceable: true, builtin: true },
];

const createRuntime = async ({ cwd, sessionManager, sessionStartEvent }) => {
  const services = await createAgentSessionServices({
    cwd,
    agentDir: getAgentDir(),
    resourceLoaderOptions: { extensionFactories: builtins },
  });
  const created = await createAgentSessionFromServices({ services, sessionManager, sessionStartEvent });
  return { ...created, services, diagnostics: services.diagnostics };
};

const clients = new Set();
let runtime;
let unsubscribe;
let partial = null; // text of the assistant reply currently streaming

const send = (client, msg) => client.write(JSON.stringify(msg) + "\n");
const broadcast = (msg) => clients.forEach((c) => send(c, msg));

function textOf(message) {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (!Array.isArray(c)) return "";
  return c.filter((b) => b?.type === "text").map((b) => b.text).join("");
}

function snapshot() {
  const s = runtime.session;
  const messages = s.messages
    .filter((m) => m.role === "user" || m.role === "assistant")
    .map((m) => ({ role: m.role, text: textOf(m).slice(0, TEXT_LIMIT) }))
    .filter((m) => m.text)
    .slice(-HISTORY_LIMIT);
  return {
    ev: "snapshot",
    name: s.sessionName || "",
    cwd: s.sessionManager?.getCwd?.() || "",
    model: s.model?.name || s.model?.id || "",
    busy: s.isStreaming,
    partial,
    messages,
  };
}

function onEvent(e) {
  switch (e.type) {
    case "agent_start":
      broadcast({ ev: "busy", value: true });
      break;
    case "agent_settled":
      partial = null;
      broadcast({ ev: "busy", value: false });
      break;
    case "message_start":
      if (e.message?.role === "assistant") { partial = ""; broadcast({ ev: "start" }); }
      break;
    case "message_update":
      if (e.assistantMessageEvent?.type === "text_delta") {
        partial = (partial ?? "") + e.assistantMessageEvent.delta;
        broadcast({ ev: "delta", text: e.assistantMessageEvent.delta });
      }
      break;
    case "message_end":
      if (e.message?.role === "assistant") { partial = null; broadcast({ ev: "end", text: textOf(e.message) }); }
      break;
    case "tool_execution_start": {
      const a = e.args || {};
      const detail = a.command ?? a.path ?? a.file_path ?? a.pattern ?? "";
      broadcast({ ev: "tool", name: e.toolName, detail: String(detail).slice(0, 200) });
      break;
    }
  }
}

async function bind() {
  unsubscribe?.();
  partial = null;
  const s = runtime.session;
  await s.bindExtensions({ onError: (err) => broadcast({ ev: "error", text: String(err?.error ?? err) }) });
  unsubscribe = s.subscribe(onEvent);
  if (s.sessionFile) {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(LAST_FILE, s.sessionFile);
  }
  broadcast(snapshot());
}

async function listSessions(query) {
  const q = (query || "").toLowerCase();
  const all = await SessionManager.listAll();
  return all
    .filter((i) => !q || `${i.name ?? ""} ${i.cwd} ${i.allMessagesText}`.toLowerCase().includes(q))
    .sort((a, b) => b.modified - a.modified)
    .slice(0, 100)
    .map((i) => ({
      path: i.path,
      name: i.name || i.firstMessage.replace(/\s+/g, " ").slice(0, 120) || i.id,
      cwd: i.cwd.replace(os.homedir(), "~"),
      count: i.messageCount,
      modified: i.modified.getTime(),
    }));
}

async function handle(client, msg) {
  const s = runtime.session;
  switch (msg.op) {
    case "sync":
      return send(client, snapshot());
    case "prompt":
      // Fire and forget: progress arrives as events.
      s.prompt(msg.text, s.isStreaming ? { streamingBehavior: "steer" } : undefined)
        .catch((err) => broadcast({ ev: "error", text: err.message }));
      return;
    case "abort":
      return s.abort();
    case "new":
      await runtime.newSession();
      return bind();
    case "resume":
      await runtime.switchSession(msg.path);
      return bind();
    case "sessions":
      return send(client, { ev: "sessions", list: await listSessions(msg.query) });
  }
}

function initialSessionManager() {
  try {
    const last = fs.readFileSync(LAST_FILE, "utf8").trim();
    if (last && fs.existsSync(last)) return SessionManager.open(last);
  } catch {}
  return SessionManager.create(os.homedir());
}

runtime = await createAgentSessionRuntime(createRuntime, {
  cwd: os.homedir(),
  agentDir: getAgentDir(),
  sessionManager: initialSessionManager(),
});
await bind();

fs.rmSync(SOCKET, { force: true });
net.createServer((client) => {
  clients.add(client);
  let buf = "";
  client.setEncoding("utf8");
  client.on("data", (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      handle(client, msg).catch((err) => send(client, { ev: "error", text: err.message }));
    }
  });
  client.on("close", () => clients.delete(client));
  client.on("error", () => clients.delete(client));
}).listen(SOCKET, () => console.log(`omarchy-pi listening on ${SOCKET}`));
