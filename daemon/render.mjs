// Markdown -> the HTML subset Qt rich text understands, with inline colors
// from the current Omarchy theme (Qt honors inline styles, not stylesheets).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import hljs from "highlight.js/lib/common";
import { Marked } from "marked";

const THEME = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "omarchy/current/theme/colors.toml");
const FALLBACK = {
  foreground: "#cacccc", muted: "#707880", accent: "#7aa2f7", darker_background: "#0c0e10",
  red: "#f7768e", green: "#9ece6a", yellow: "#e0af68", blue: "#7aa2f7", magenta: "#bb9af7", cyan: "#7dcfff", orange: "#ff9e64",
};

let cached = { mtime: 0, palette: FALLBACK };
function palette() {
  try {
    const { mtimeMs } = fs.statSync(THEME);
    if (mtimeMs !== cached.mtime) {
      const p = { ...FALLBACK };
      for (const [, k, v] of fs.readFileSync(THEME, "utf8").matchAll(/^(\w+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm)) p[k] = v;
      cached = { mtime: mtimeMs, palette: p };
    }
  } catch {}
  return cached.palette;
}

const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function highlight(code, lang, p) {
  const syntax = {
    keyword: p.magenta, "selector-tag": p.magenta, built_in: p.cyan, type: p.cyan,
    string: p.green, regexp: p.green, "template-variable": p.green, addition: p.green,
    number: p.orange, literal: p.orange, symbol: p.orange,
    title: p.blue, "title.function_": p.blue, "title.class_": p.yellow, section: p.blue,
    attr: p.yellow, attribute: p.yellow, property: p.yellow, params: p.foreground,
    variable: p.red, deletion: p.red, meta: p.muted, comment: p.muted, quote: p.muted,
  };
  let html;
  try {
    html = lang && hljs.getLanguage(lang) ? hljs.highlight(code, { language: lang }).value : escape(code);
  } catch {
    html = escape(code);
  }
  return html.replace(/<span class="hljs-([\w.-]+)[^"]*">/g, (_, cls) => {
    const color = syntax[cls] ?? syntax[cls.split(".")[0]];
    const italic = cls === "comment" ? ";font-style:italic" : "";
    return color ? `<span style="color:${color}${italic}">` : "<span>";
  });
}

function makeMarked(p) {
  const md = new Marked({ gfm: true, breaks: false });
  md.use({
    renderer: {
      // Raw HTML from the model is shown, never interpreted.
      html: ({ text }) => escape(text),
      code({ text, lang }) {
        const label = lang ? `<span style="color:${p.muted};font-size:small">${escape(lang)}</span>` : "";
        return `<table width="100%" cellspacing="0" cellpadding="10" bgcolor="${p.darker_background}"><tr><td>${label}`
          + `<pre style="white-space:pre-wrap;font-family:monospace;margin-top:2px;margin-bottom:0">${highlight(text, (lang || "").split(/\s/)[0], p)}</pre></td></tr></table><br>`;
      },
      codespan: ({ text }) => `<code style="background-color:${p.darker_background};color:${p.magenta}">&nbsp;${text}&nbsp;</code>`,
      heading({ tokens, depth }) {
        const inner = this.parser.parseInline(tokens);
        return depth <= 2 ? `<p><big><b>${inner}</b></big></p>` : `<p><b>${inner}</b></p>`;
      },
      blockquote({ tokens }) {
        return `<blockquote style="color:${p.muted}">${this.parser.parse(tokens)}</blockquote>`;
      },
      link({ href, tokens }) {
        return `<a href="${escape(href)}" style="color:${p.accent}">${this.parser.parseInline(tokens)}</a>`;
      },
      hr: () => `<hr style="color:${p.muted}">`,
      table(token) {
        const cell = (c, tag) => `<${tag} style="padding:4px 8px" align="${c.align || "left"}">${this.parser.parseInline(c.tokens)}</${tag}>`;
        const head = `<tr>${token.header.map((c) => cell(c, "th")).join("")}</tr>`;
        const rows = token.rows.map((r) => `<tr>${r.map((c) => cell(c, "td")).join("")}</tr>`).join("");
        return `<table cellspacing="0" border="1" style="border-collapse:collapse;border-color:${p.muted}">${head}${rows}</table><br>`;
      },
    },
  });
  return md;
}

let markedFor = { palette: null, md: null };

export function renderMarkdown(text) {
  const p = palette();
  if (markedFor.palette !== p) markedFor = { palette: p, md: makeMarked(p) };
  return markedFor.md.parse(text || "").replace(/(<br>|\n)+$/, "");
}
