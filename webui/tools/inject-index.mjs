#!/usr/bin/env node
/** Render boot injections into dist/index.injected.html.
 *  Mirrors packages/host/webserver/src/injections.ts rendering semantics,
 *  using the vendored node-half's own bootInjections() export.
 *  Run after EVERY `vite build` (vite wipes dist). static.zig serves
 *  index.injected.html for "/" when present, falling back to index.html. */
import { readFileSync, writeFileSync } from "node:fs"
import { bootInjections } from "../packages/client/modules/lib/index.js"

const webuiRoot = new URL("../", import.meta.url)
const manifest = JSON.parse(readFileSync(new URL("build-artifacts/boot-manifest.json", webuiRoot), "utf8"))
const rows = bootInjections(manifest.graph)

const escAttr = (v) => v.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
function renderRow(row) {
  switch (row.kind) {
    case "global": {
      const name = JSON.stringify(row.name).replaceAll("<", "\\u003c")
      const value = row.value === undefined ? "undefined" : JSON.stringify(row.value).replaceAll("<", "\\u003c")
      return { p: "head", m: `<script>globalThis[${name}] = ${value}</script>` }
    }
    case "script": return { p: row.placement, m: `<script>${row.text}</script>` }
    case "script-src": return { p: row.placement, m: `<script src="${escAttr(row.src)}"></script>` }
    // Advisory preload for an external classic script (upstream injections.ts).
    case "script-preload": return { p: "head", m: `<link rel="preload" as="script" href="${escAttr(row.src)}">` }
    case "style": return { p: "head", m: `<style>${row.text}</style>` }
    case "html": return { p: row.placement, m: row.html }
    default: throw new Error(`unknown injection row ${JSON.stringify(row).slice(0, 80)}`)
  }
}

let head = "", body = ""
for (const r of rows) { const { p, m } = renderRow(r); if (p === "head") head += m; else body += m }
let html = readFileSync(new URL("dist/index.html", webuiRoot), "utf8")
if (head !== "") { const o = /<head(?:\s[^>]*)?>/i.exec(html); html = o === null ? head + html : html.slice(0, o.index + o[0].length) + head + html.slice(o.index + o[0].length) }
if (body !== "") { const o = /<body(?:\s[^>]*)?>/i.exec(html); html = o === null ? html + body : html.slice(0, o.index + o[0].length) + body + html.slice(o.index + o[0].length) }
writeFileSync(new URL("dist/index.injected.html", webuiRoot), html)
console.log(`inject-index: ${rows.length} rows -> index.injected.html (${html.length} bytes)`)
