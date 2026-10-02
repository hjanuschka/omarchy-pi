// omarchy-pi daemon: one long-lived pi agent driven by the pi SDK with the
// user's ~/.pi config (settings, auth, models, skills, extensions, prompts,
// AGENTS.md). Every chat lives in its own dated workspace under ~/lab/chatty
// (a la tobi/try). Clients attach over a unix socket speaking JSONL; closing a
// client never touches the agent.
//
// client -> daemon:
//   {op:"sync"} {op:"prompt",text} {op:"abort"} {op:"commands"}
//   {op:"pick",kind:"sessions"|"models"|"folders",query}
//   {op:"resume",path} {op:"new",name} {op:"newin",dir}
//   {op:"model",provider,id} {op:"thinking",level}
// daemon -> client:
//   {ev:"snapshot",...} {ev:"start"} {ev:"delta",text} {ev:"html",html}
//   {ev:"end",text,html,ts} {ev:"recent",list}
//   {ev:"tool",name,detail} {ev:"busy",value} {ev:"info",text} {ev:"error",text}
//   {ev:"commands",list} {ev:"pick",kind,query,items} {ev:"view",kind,query}
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
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { renderMarkdown } from "./render.mjs";

const HOME = os.homedir();
const CHATTY = process.env.OMARCHY_PI_ROOT || path.join(HOME, "lab/chatty");
const SOCKET = path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), "omarchy-pi.sock");
const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(HOME, ".local/state"), "omarchy-pi");
const LAST_FILE = path.join(STATE_DIR, "last.json");
const HISTORY_LIMIT = 80;
const TEXT_LIMIT = 20000;

// Slash commands pi's TUI owns; everything else goes through session.prompt(),
// which already expands extension commands, /skill:name and prompt templates.
const BUILTINS = [
  { name: "model", description: "switch model, e.g. /model sonnet" },
  { name: "thinking", description: "set thinking level, e.g. /thinking high" },
  { name: "new", description: "new chat workspace, e.g. /new redis-pool" },
  { name: "sessions", description: "find and resume a chat" },
  { name: "compact", description: "compact the context" },
  { name: "name", description: "rename this session" },
];

// Same built-in extensions the pi CLI loads; the SDK leaves them out.
const builtinExtensions = [
  { name: "codemode", factory: createCodemodeExtension(), replaceable: true, builtin: true },
  { name: "tool-search", factory: createToolSearchExtension(), replaceable: true, builtin: true },
  { name: "mcp", factory: createMcpExtension(), replaceable: true, builtin: true },
];

const createRuntime = async ({ cwd, sessionManager, sessionStartEvent }) => {
  const services = await createAgentSessionServices({
    cwd,
    agentDir: getAgentDir(),
    resourceLoaderOptions: { extensionFactories: builtinExtensions },
  });
  const created = await createAgentSessionFromServices({ services, sessionManager, sessionStartEvent });
  return { ...created, services, diagnostics: services.diagnostics };
};

const clients = new Set();
let runtime;
let unsubscribe;
let partial = null; // text of the assistant reply currently streaming
let renderTimer = null;
let recent = [];

const send = (client, msg) => client.write(JSON.stringify(msg) + "\n");
const broadcast = (msg) => clients.forEach((c) => send(c, msg));
const info = (text) => broadcast({ ev: "info", text });
const session = () => runtime.session;
const cwdOf = (s) => s.sessionManager.getCwd();

// ------------------------------------------------------------- workspaces

function slug(name) {
  return String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48) || "chat";
}

function makeWorkspace(name) {
  const d = new Date();
  const date = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const base = path.join(CHATTY, `${date}-${slug(name)}`);
  let dir = base;
  for (let n = 2; fs.existsSync(dir); n++) dir = `${base}-${n}`;
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const pretty = (dir) => (dir.startsWith(CHATTY + "/") ? path.basename(dir) : dir.replace(HOME, "~"));

function age(ms) {
  const m = Math.max(0, (Date.now() - ms) / 60000);
  if (m < 60) return `${Math.round(m)}m`;
  if (m < 1440) return `${Math.round(m / 60)}h`;
  if (m < 10080) return `${Math.round(m / 1440)}d`;
  return `${Math.round(m / 10080)}w`;
}

// try-style fuzzy score: subsequence match, rewarding consecutive characters
// and word starts. 0 means no match.
function fuzzy(query, text) {
  const q = query.toLowerCase();
  const t = text.toLowerCase();
  let score = 0;
  let ti = 0;
  let prev = -2;
  for (const ch of q) {
    const i = t.indexOf(ch, ti);
    if (i < 0) return 0;
    score += 1 + (i === prev + 1 ? 2 : 0) + (i === 0 || /[\s\-_/.]/.test(t[i - 1]) ? 1.5 : 0);
    prev = i;
    ti = i + 1;
  }
  return score / Math.sqrt(t.length + 1);
}

function rank(items, query, hay, extra = () => 0) {
  if (!query) return items;
  return items
    .map((it) => ({ it, score: fuzzy(query, hay(it)) + extra(it) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((x) => x.it);
}

async function pickSessions(query) {
  const all = (await SessionManager.listAll()).sort((a, b) => b.modified - a.modified);
  const recency = (i) => 1 / Math.sqrt((Date.now() - i.modified) / 3.6e6 + 1);
  const hay = (i) => `${pretty(i.cwd)} ${i.name ?? ""} ${i.firstMessage}`;
  // Fuzzy on title/workspace, plus a weaker full-text hit on the transcript.
  const extra = (i) => recency(i) * 0.5 + (query && i.allMessagesText.toLowerCase().includes(query.toLowerCase()) ? 0.4 : 0);
  const items = rank(all, query, hay, extra).slice(0, 60).map((i) => ({
    title: i.name || i.firstMessage.replace(/\s+/g, " ").slice(0, 120) || "(empty)",
    subtitle: `${pretty(i.cwd)} · ${i.messageCount} msgs · ${age(i.modified.getTime())}`,
    action: { op: "resume", path: i.path },
  }));
  items.push({
    title: `+ new: ${query || "chat"}`,
    subtitle: `${pretty(CHATTY)}/…-${slug(query)}`.replace(HOME, "~"),
    action: { op: "new", name: query },
  });
  return items;
}

function pickModels(query) {
  const s = session();
  const models = s.modelRuntime.getAvailableSnapshot();
  const hay = (m) => `${m.provider}/${m.id} ${m.name ?? ""}`;
  return rank(models, query, hay).slice(0, 60).map((m) => ({
    title: (m.name || m.id) + (s.model && m.provider === s.model.provider && m.id === s.model.id ? "  ✓" : ""),
    subtitle: `${m.provider}/${m.id}`,
    action: { op: "model", provider: m.provider, id: m.id },
  }));
}

// Folder candidates: zoxide's frecent dirs plus every pi session cwd. A typed
// path lists that directory's children so the picker doubles as a browser.
const execFileP = promisify(execFile);
const expand = (p) => (p.startsWith("~") ? path.join(HOME, p.slice(1)) : p);

async function pickFolders(query) {
  const typed = /^[~/]/.test(query) ? expand(query) : null;
  if (typed) {
    const base = typed.endsWith("/") ? typed : path.dirname(typed);
    const leaf = typed.endsWith("/") ? "" : path.basename(typed);
    let children = [];
    try {
      children = fs.readdirSync(base, { withFileTypes: true })
        .filter((d) => d.isDirectory() && !d.name.startsWith("."))
        .map((d) => path.join(base, d.name));
    } catch {}
    const dirs = rank(children, leaf, (d) => path.basename(d));
    if (fs.existsSync(typed) && fs.statSync(typed).isDirectory()) dirs.unshift(typed.replace(/\/$/, "") || "/");
    return dirs.slice(0, 60).map(folderItem);
  }
  let zoxide = [];
  try { zoxide = (await execFileP("zoxide", ["query", "-l"])).stdout.split("\n").filter(Boolean); } catch {}
  const cwds = (await SessionManager.listAll()).sort((a, b) => b.modified - a.modified).map((i) => i.cwd);
  const dirs = [...new Set([...cwds, ...zoxide])].filter((d) => d && fs.existsSync(d));
  return rank(dirs, query, (d) => d.replace(HOME, "~")).slice(0, 60).map(folderItem);
}

const folderItem = (dir) => ({
  title: path.basename(dir) || dir,
  subtitle: dir.replace(HOME, "~"),
  action: { op: "newin", dir },
});

function commandList() {
  const s = session();
  const list = BUILTINS.map((c) => ({ ...c, source: "builtin" }));
  for (const c of s.extensionRunner.getRegisteredCommands()) list.push({ name: c.invocationName, description: c.description ?? "", source: "extension" });
  for (const t of s.promptTemplates) list.push({ name: t.name, description: t.description ?? "", source: "prompt" });
  for (const k of s.resourceLoader.getSkills().skills) list.push({ name: `skill:${k.name}`, description: k.description ?? "", source: "skill" });
  return list;
}

// ------------------------------------------------------------- session

function textOf(message) {
  const c = message?.content;
  if (typeof c === "string") return c;
  if (!Array.isArray(c)) return "";
  return c.filter((b) => b?.type === "text").map((b) => b.text).join("");
}

// pi persists /skill:name prompts with the skill body inlined; show them the
// way they were typed (same pattern pi's own session parser uses).
function displayText(message) {
  const text = textOf(message);
  if (message.role !== "user") return text;
  const skill = text.match(/^<skill name="([^"]+)" location="[^"]+">\n[\s\S]*?\n<\/skill>(?:\n\n([\s\S]+))?$/);
  return skill ? `/skill:${skill[1]} ${skill[2] ?? ""}`.trim() : text;
}

function snapshot() {
  const s = session();
  return {
    ev: "snapshot",
    title: s.sessionName || chipTitle(cwdOf(s)) || pretty(cwdOf(s)),
    workspace: pretty(cwdOf(s)),
    name: s.sessionName || "",
    model: s.model?.name || s.model?.id || "",
    thinking: s.thinkingLevel,
    busy: s.isStreaming,
    partial,
    partialHtml: partial ? renderMarkdown(partial) : "",
    messages: s.messages
      .filter((m) => m.role === "user" || m.role === "assistant")
      .map((m) => ({ role: m.role, text: displayText(m).slice(0, TEXT_LIMIT), ts: m.timestamp }))
      .filter((m) => m.text.trim())
      .slice(-HISTORY_LIMIT)
      .map((m) => (m.role === "assistant" ? { ...m, html: renderMarkdown(m.text) } : m)),
  };
}

function onEvent(e) {
  switch (e.type) {
    case "agent_start":
      return broadcast({ ev: "busy", value: true });
    case "agent_settled":
      partial = null;
      broadcast({ ev: "busy", value: false });
      return refreshRecent();
    case "message_start":
      if (e.message?.role === "assistant") { partial = ""; broadcast({ ev: "start" }); }
      return;
    case "message_update":
      if (e.assistantMessageEvent?.type === "text_delta") {
        partial = (partial ?? "") + e.assistantMessageEvent.delta;
        broadcast({ ev: "delta", text: e.assistantMessageEvent.delta });
        // Re-render the growing reply at most every 120ms.
        renderTimer ??= setTimeout(() => {
          renderTimer = null;
          if (partial) broadcast({ ev: "html", html: renderMarkdown(partial) });
        }, 120);
      }
      return;
    case "message_end":
      if (e.message?.role === "assistant") {
        clearTimeout(renderTimer);
        renderTimer = null;
        partial = null;
        const text = textOf(e.message).trim() ? textOf(e.message) : "";
        broadcast({ ev: "end", text, html: text ? renderMarkdown(text) : "", ts: e.message.timestamp ?? Date.now() });
      }
      return;
    case "tool_execution_start": {
      const a = e.args || {};
      const detail = a.command ?? a.path ?? a.file_path ?? a.pattern ?? "";
      return broadcast({ ev: "tool", name: e.toolName, detail: String(detail).slice(0, 200) });
    }
  }
}

// Extensions get a UI that surfaces notifications in the panel. Dialogs are
// answered as cancelled; TUI-only hooks (widgets, footers, ...) are no-ops.
// The SDK copies these methods, so every ExtensionUIContext member is explicit.
const plainTheme = new Proxy({}, { get: () => (...args) => args[args.length - 1] });
const noop = () => {};
const uiContext = {
  notify: (message, type) => broadcast({ ev: type === "error" ? "error" : "info", text: String(message) }),
  select: async () => undefined,
  confirm: async () => false,
  input: async () => undefined,
  editor: async () => undefined,
  custom: async () => undefined,
  onTerminalInput: () => noop,
  addAutocompleteProvider: () => noop,
  theme: plainTheme,
  getTheme: () => plainTheme,
  getAllThemes: () => [],
  setTheme: noop,
  getEditorText: () => "",
  setEditorText: noop,
  pasteToEditor: noop,
  getEditorComponent: () => undefined,
  setEditorComponent: noop,
  getToolsExpanded: () => false,
  setToolsExpanded: noop,
  setStatus: noop,
  setWidget: noop,
  setFooter: noop,
  setHeader: noop,
  setTitle: noop,
  setHiddenThinkingLabel: noop,
  setWorkingIndicator: noop,
  setWorkingMessage: noop,
  setWorkingVisible: noop,
};

async function bind() {
  unsubscribe?.();
  partial = null;
  const s = session();
  await s.bindExtensions({ uiContext, onError: (err) => broadcast({ ev: "error", text: String(err?.error ?? err) }) });
  unsubscribe = s.subscribe(onEvent);
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(LAST_FILE, JSON.stringify({ file: s.sessionFile, cwd: cwdOf(s) }));
  broadcast(snapshot());
  broadcast({ ev: "commands", list: commandList() });
  refreshRecent();
}

// A chat is named after its workspace: the try slug, or the folder it runs in.
function chipTitle(cwd) {
  if (!cwd || cwd === HOME) return "";
  return cwd.startsWith(CHATTY + "/") ? path.basename(cwd).replace(/^\d{4}-\d{2}-\d{2}-/, "") : path.basename(cwd);
}

// Quick-switch chips: the current chat plus the most recent others.
async function refreshRecent() {
  const current = session().sessionFile;
  const all = (await SessionManager.listAll()).sort((a, b) => b.modified - a.modified);
  const chip = (i) => ({
    path: i.path,
    title: i.name || chipTitle(i.cwd) || i.firstMessage.replace(/\s+/g, " ").slice(0, 24) || "chat",
    current: i.path === current,
  });
  const others = all.filter((i) => i.path !== current).slice(0, current ? 4 : 5).map(chip);
  const mine = all.find((i) => i.path === current);
  const self = mine ? chip(mine) : { path: current, title: snapshot().title || "new", current: true };
  recent = current ? [self, ...others] : others;
  // Chats in the same folder share its name; tell them apart by their opening message.
  const byPath = new Map(all.map((i) => [i.path, i]));
  const counts = {};
  for (const c of recent) counts[c.title] = (counts[c.title] ?? 0) + 1;
  for (const c of recent) {
    const info = byPath.get(c.path);
    if (info && !info.name && counts[c.title] > 1)
      c.title = info.firstMessage.replace(/\s+/g, " ").slice(0, 24) || c.title;
  }
  broadcast({ ev: "recent", list: recent });
}

// Leaving a chat that never got a message removes its empty workspace.
function dropIfEmpty() {
  const s = runtime?.session;
  if (!s || s.messages.length) return;
  const dir = cwdOf(s);
  // Extensions may leave an empty .pi/ skeleton (e.g. .pi/plans); any file
  // means the workspace was used.
  const hasFiles = (d) => fs.readdirSync(d, { withFileTypes: true })
    .some((e) => !e.isDirectory() || hasFiles(path.join(d, e.name)));
  try {
    if (dir.startsWith(CHATTY + "/") && !hasFiles(dir)) fs.rmSync(dir, { recursive: true });
  } catch {}
}

async function start(cwd, sessionManager) {
  dropIfEmpty();
  unsubscribe?.();
  await runtime?.dispose();
  runtime = await createAgentSessionRuntime(createRuntime, { cwd, agentDir: getAgentDir(), sessionManager });
  await bind();
}

const newChat = (name) => {
  const dir = makeWorkspace(name);
  return start(dir, SessionManager.create(dir));
};

async function resume(file) {
  dropIfEmpty();
  await runtime.switchSession(file);
  await bind();
}

// ------------------------------------------------------------- commands

async function slash(text) {
  const m = /^\/(\S+)\s*([\s\S]*)$/.exec(text.trim());
  if (!m || !BUILTINS.some((b) => b.name === m[1])) return false;
  const [, cmd, rawArg] = m;
  const arg = rawArg.trim();
  const s = session();
  switch (cmd) {
    case "model": {
      const best = arg && pickModels(arg)[0];
      if (!best) { broadcast({ ev: "view", kind: "models", query: arg }); break; }
      await setModel(best.action.provider, best.action.id);
      break;
    }
    case "thinking": {
      const level = arg || s.cycleThinkingLevel();
      if (arg) s.setThinkingLevel(arg);
      info(`thinking: ${level ?? "not supported by this model"}`);
      broadcast(snapshot());
      break;
    }
    case "new":
      await newChat(arg);
      break;
    case "sessions":
      broadcast({ ev: "view", kind: "sessions", query: arg });
      break;
    case "compact":
      info("compacting…");
      await s.compact(arg || undefined);
      info("compacted");
      broadcast(snapshot());
      break;
    case "name":
      if (arg) s.setSessionName(arg);
      broadcast(snapshot());
      break;
  }
  return true;
}

async function setModel(provider, id) {
  const s = session();
  const model = s.modelRuntime.getAvailableSnapshot().find((m) => m.provider === provider && m.id === id);
  if (!model) throw new Error(`model not found: ${provider}/${id}`);
  await s.setModel(model);
  info(`model: ${model.name || model.id}`);
  broadcast(snapshot());
}

async function handle(client, msg) {
  const s = session();
  switch (msg.op) {
    case "sync":
      send(client, snapshot());
      send(client, { ev: "recent", list: recent });
      return send(client, { ev: "commands", list: commandList() });
    case "commands":
      return send(client, { ev: "commands", list: commandList() });
    case "prompt":
      if (await slash(msg.text)) return;
      // Fire and forget: progress arrives as events.
      s.prompt(msg.text, s.isStreaming ? { streamingBehavior: "steer" } : undefined)
        .catch((err) => broadcast({ ev: "error", text: err.message }));
      return;
    case "abort":
      return s.abort();
    case "pick": {
      const query = msg.query || "";
      const items = msg.kind === "models" ? pickModels(query)
        : msg.kind === "folders" ? await pickFolders(query)
        : await pickSessions(query);
      return send(client, { ev: "pick", kind: msg.kind, query, items });
    }
    case "new":
      return newChat(msg.name);
    case "newin":
      return start(msg.dir, SessionManager.create(msg.dir));
    case "resume":
      if (msg.path === session().sessionFile) return;
      return resume(msg.path);
    case "model":
      return setModel(msg.provider, msg.id);
    case "thinking":
      s.setThinkingLevel(msg.level);
      return broadcast(snapshot());
  }
}

// ------------------------------------------------------------- boot

// A misbehaving extension must not take the agent down with it.
process.on("unhandledRejection", (err) => console.error("unhandled:", err));
process.on("uncaughtException", (err) => console.error("uncaught:", err));

// Boot into the last chat; if it was never written (no messages), fall back
// to the most recent chat workspace, and only then to a fresh one.
let last = {};
try { last = JSON.parse(fs.readFileSync(LAST_FILE, "utf8")); } catch {}
const lastChat = last.file && fs.existsSync(last.file) ? last
  : (await SessionManager.listAll()).filter((i) => i.cwd.startsWith(CHATTY + "/"))
    .sort((a, b) => b.modified - a.modified).map((i) => ({ file: i.path, cwd: i.cwd }))[0];
if (lastChat) await start(lastChat.cwd, SessionManager.open(lastChat.file));
else await newChat("chat");

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
}).listen(SOCKET, () => {
  // Whoever can connect drives the agent: owner only.
  fs.chmodSync(SOCKET, 0o600);
  console.log(`omarchy-pi listening on ${SOCKET}, workspaces in ${CHATTY}`);
});
