#!/usr/bin/env node
/**
 * zharness vendored-build helper: static verification server for the built
 * DSH frontend dist.
 *
 * Mirrors the upstream hosting contract so the app boots unmodified:
 * - serves apps/web/dist statically (frontend-static semantics: index at /,
 *   correct MIME, 404 for misses);
 * - serves /plugins/<id>/client.js(.map) from <package>/lib/ with rev
 *   cache-busting left to the URL query (modules/src/index.ts serveBundle
 *   semantics: text/javascript + no-cache);
 * - renders GET / by splicing bootInjections(graph) head rows into the dist
 *   index.html — the same three-row protocol as host/webserver renderIndex:
 *   inline __ModuleLoader__ queue facade, two parser-blocking preload
 *   scripts, then globalThis.__DSH_BOOT__.
 *
 * The graph comes from build-artifacts/boot-manifest.json (trimmed 15-row
 * roster; regenerate via gen-boot-manifest.mjs).
 *
 * `?fixture` on any page URL makes the vendored connection plugin swap in its
 * in-browser FixtureApiClient — no backend needed. This server therefore
 * implements NO /api routes.
 *
 * Usage: node ../tools/serve-fixture.mjs [port]   (cwd must be webui)
 */
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { extname, join, normalize, resolve, sep } from 'node:path'

const root = process.cwd()
const distRoot = resolve(root, 'dist')
const distIndex = join(distRoot, 'index.html')
const manifestPath = resolve(root, 'build-artifacts/boot-manifest.json')
const port = Number(process.argv[2] ?? 4173)

if (!existsSync(distIndex) || !existsSync(manifestPath)) {
  console.error('serve-fixture: need dist/index.html and build-artifacts/boot-manifest.json (build first)')
  process.exit(1)
}
const { graph, injections } = JSON.parse(await readFile(manifestPath, 'utf8'))

/** Package name -> absolute lib dir, resolved once from the vendored manifests. */
const pluginLibDirs = new Map()
for (const group of ['packages/client', 'packages/typert', 'packages/api']) {
  const groupDir = join(root, ...group.split('/'))
  if (!existsSync(groupDir)) continue
  for (const leaf of readdirSync(groupDir)) {
    const manifestFile = join(groupDir, leaf, 'package.json')
    if (!existsSync(manifestFile)) continue
    try {
      const manifest = JSON.parse(readFileSync(manifestFile, 'utf8'))
      if (graph.entries.some(entry => entry.id === manifest.name)) {
        pluginLibDirs.set(manifest.name, join(groupDir, leaf, 'lib'))
      }
    } catch {}
  }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.map': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.ttf': 'font/ttf',
}
const HTML_MIME = MIME['.html']
const STATIC_MISS_CODES = new Set(['ENOENT', 'EISDIR', 'ENOTDIR'])

function escapeHtmlAttribute(value) {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

/** Render one IndexInjection row — mirrors webserver/src/injections.ts renderRow. */
function renderRow(row) {
  switch (row.kind) {
    case 'global': {
      const name = JSON.stringify(row.name).replaceAll('<', '\\u003c')
      const value = row.value === undefined ? 'undefined' : JSON.stringify(row.value).replaceAll('<', '\\u003c')
      return { placement: 'head', markup: `<script>globalThis[${name}] = ${value}</script>` }
    }
    case 'script':
      return { placement: row.placement, markup: `<script>${row.text}</script>` }
    case 'script-src':
      return { placement: row.placement, markup: `<script src="${escapeHtmlAttribute(row.src)}"></script>` }
    case 'style':
      return { placement: 'head', markup: `<style>${row.text}</style>` }
    case 'html':
      return { placement: row.placement, markup: row.html }
    default:
      throw new Error(`serve-fixture: unknown injection row ${JSON.stringify(row.kind)}`)
  }
}

function renderIndexInjections(html, rows) {
  let head = ''
  let body = ''
  for (const row of rows) {
    const rendered = renderRow(row)
    if (rendered.placement === 'head') head += rendered.markup
    else body += rendered.markup
  }
  const lower = html.toLowerCase()
  let out = html
  if (head !== '') {
    const at = lower.indexOf('<head>') + '<head>'.length
    out = out.slice(0, at) + head + out.slice(at)
  }
  if (body !== '') {
    const at = out.toLowerCase().indexOf('<body>') + '<body>'.length
    out = out.slice(0, at) + body + out.slice(at)
  }
  return out
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const pathname = decodeURIComponent(url.pathname)

    // Plugin bundles (+ source maps), served from the built lib dirs.
    const prefix = '/plugins/'
    const bundleSuffix = '/client.js'
    const mapSuffix = '/client.js.map'
    if (pathname.startsWith(prefix) && (pathname.endsWith(bundleSuffix) || pathname.endsWith(mapSuffix))) {
      const isMap = pathname.endsWith(mapSuffix)
      const id = pathname.slice(prefix.length, -(isMap ? mapSuffix : bundleSuffix).length)
      const libDir = pluginLibDirs.get(id)
      const file = libDir === undefined ? undefined : join(libDir, isMap ? 'client.js.map' : 'client.js')
      let body
      try { body = await readFile(file) } catch { body = undefined }
      if (body === undefined || libDir === undefined) {
        res.writeHead(404)
        res.end()
        return
      }
      res.writeHead(200, {
        'content-type': isMap ? 'application/json; charset=utf-8' : 'text/javascript; charset=utf-8',
        'cache-control': 'no-cache',
      })
      res.end(body)
      return
    }

    // Static dist (SPA index only at root — upstream frontend-static has no SPA fallback).
    const target = resolve(normalize(join(distRoot, pathname)))
    if (target !== distRoot && !target.startsWith(distRoot + sep)) {
      res.writeHead(403)
      res.end()
      return
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405)
      res.end()
      return
    }
    if (target === distRoot || target === distIndex) {
      const html = await readFile(distIndex, 'utf8')
      res.writeHead(200, { 'content-type': HTML_MIME })
      res.end(renderIndexInjections(html, injections))
      return
    }
    try {
      const body = await readFile(target)
      res.writeHead(200, { 'content-type': MIME[extname(target)] ?? 'application/octet-stream' })
      res.end(body)
    } catch (error) {
      if (!STATIC_MISS_CODES.has(error.code)) throw error
      res.writeHead(404)
      res.end()
    }
  } catch (error) {
    res.writeHead(500)
    res.end(String(error?.stack ?? error))
  }
})

server.listen(port, () => {
  console.log(`serve-fixture: http://localhost:${port}/?fixture`)
  console.log(`serve-fixture: ${graph.entries.length} plugin rows, graph rev ${graph.rev}`)
})
