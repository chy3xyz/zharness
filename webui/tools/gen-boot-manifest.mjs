#!/usr/bin/env node
/**
 * zharness vendored-build helper: compose the window.__DSH_BOOT__ graph from
 * the built vendored tree.
 *
 * Mirrors ClientModuleRegistry.compose() (packages/client/modules/src/index.ts)
 * for a STATIC dist: module-graph ordered entries, bootstrap/application combo
 * batches (URL-length partitioned, rev = framedHash('combo', ...)), and the
 * graph rev = shortHash(JSON.stringify({entries, batches})). Bundle revs are
 * framedHash('plugin-artifact', [bundle]) — the same values the Zig static
 * server's `/plugins/??` combo route is keyed by. Row composition, ordering,
 * and the boot injection rows are delegated to the vendored node half itself
 * (`@deepseek-ai/dsh-client-modules` lib exports), so the output is
 * byte-compatible with what upstream's host composes for the same set.
 *
 * Roster: EVERY web client plugin in the vendored closure except
 * dsh-client-hmr (upstream's dev-server machinery; zharness serves a static
 * production dist). Plugins whose Host-facing RPC zharness does not implement
 * follow upstream's degradation rules — unknown methods answer bad-request
 * shapes and the panels idle.
 *
 * Output: webui/build-artifacts/boot-manifest.json
 *   { graph: WebBootGraph, injections: IndexInjection[], roster: string[] }
 *
 * Usage: node tools/gen-boot-manifest.mjs   (cwd must be webui)
 */
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { bootInjections, orderByModuleGraph } from '../packages/client/modules/lib/index.js'

const root = process.cwd()
if (!existsSync(join(root, 'dist/index.html'))) {
  console.error('gen-boot-manifest: dist missing — run the vite build first')
  process.exit(1)
}

const ROSTER = [
  // core: loader + connection + api faces
  '@deepseek-ai/dsh-client-modules',
  '@deepseek-ai/dsh-client-connection',
  '@deepseek-ai/dsh-typert-registry',
  '@deepseek-ai/dsh-api-gateway',
  '@deepseek-ai/dsh-api-remotes',
  '@deepseek-ai/dsh-api-session-controller',
  '@deepseek-ai/dsh-api-terminal-controller',
  '@deepseek-ai/dsh-api-workspace-controller',
  '@deepseek-ai/dsh-api-workspace-files',
  '@deepseek-ai/dsh-client-file-upload',
  '@deepseek-ai/dsh-client-resources',
  '@deepseek-ai/dsh-client-locale',
  '@deepseek-ai/dsh-session-log-export',
  // dynamic cordis browser half (zharness wire.zig delivers its packages)
  '@deepseek-ai/dsh-cordis-client-runner',
  '@deepseek-ai/dsh-client-ui-cordis',
  // ui core
  '@deepseek-ai/dsh-client-ui-theme',
  '@deepseek-ai/dsh-client-ui-layout',
  '@deepseek-ai/dsh-client-ui-renderer',
  '@deepseek-ai/dsh-client-ui-session',
  '@deepseek-ai/dsh-client-ui-sidebar',
  '@deepseek-ai/dsh-client-ui-sidebar-right',
  '@deepseek-ai/dsh-client-ui-sidebar-files',
  '@deepseek-ai/dsh-client-ui-sidebar-documentpreview',
  '@deepseek-ai/dsh-client-ui-sidebar-terminal',
  '@deepseek-ai/dsh-client-ui-settings',
  '@deepseek-ai/dsh-client-ui-settings-general',
  '@deepseek-ai/dsh-client-ui-settings-models',
  '@deepseek-ai/dsh-client-ui-settings-plugins',
  '@deepseek-ai/dsh-client-ui-settings-plugin-inventory',
  '@deepseek-ai/dsh-client-ui-settings-unarchive-sessions',
  '@deepseek-ai/dsh-client-ui-conversation',
  '@deepseek-ai/dsh-client-ui-chat',
  '@deepseek-ai/dsh-client-ui-tool',
  '@deepseek-ai/dsh-client-ui-workspace',
  '@deepseek-ai/dsh-client-ui-input-trigger',
  // zharness: General-page rows over the agent namespace (config.toml knobs)
  '@deepseek-ai/dsh-client-ui-zharness-general',
  // zharness: wave-6 feature plugins
  '@deepseek-ai/dsh-client-ui-agent-preset',
  '@deepseek-ai/dsh-client-ui-commands',
  '@deepseek-ai/dsh-client-ui-goal',
  '@deepseek-ai/dsh-client-ui-jobs',
  '@deepseek-ai/dsh-client-ui-message-feedback',
  '@deepseek-ai/dsh-client-ui-model-selection',
  '@deepseek-ai/dsh-client-ui-permission-presets',
  '@deepseek-ai/dsh-client-ui-plan',
  '@deepseek-ai/dsh-client-ui-reference',
  '@deepseek-ai/dsh-client-ui-skill',
  '@deepseek-ai/dsh-client-ui-subagent',
  '@deepseek-ai/dsh-client-ui-trajectory',
  '@deepseek-ai/dsh-client-ui-user-questions',
  '@deepseek-ai/dsh-client-ui-workflow-run',
  '@deepseek-ai/dsh-client-ui-brand-official',
  // v0.1.6 feature plugins (degrade gracefully where the RPC is zharness-absent)
  '@deepseek-ai/dsh-client-ui-approval',
  '@deepseek-ai/dsh-client-ui-attachment',
  '@deepseek-ai/dsh-client-ui-deliverables',
  '@deepseek-ai/dsh-client-ui-open-in-app',
  '@deepseek-ai/dsh-client-ui-schedule',
]

// ── ClientModuleRegistry internals (mirrored, lib-internal there) ──────────
const HASH_REVISION_LENGTH = 12
const MAX_COMBO_URL_BYTES = 3 * 1024
const COMBO_REVISION_PLACEHOLDER = '0'.repeat(HASH_REVISION_LENGTH)
/** sha1 content hash shortened to 12 hex chars (combo / graph rev). */
const shortHash = input => createHash('sha1').update(input).digest('hex').slice(0, HASH_REVISION_LENGTH)
/** Hash several response fields without allowing bytes to move across field boundaries. */
const framedHash = (domain, parts) => {
  const hash = createHash('sha1').update(domain).update('\0')
  for (const part of parts) hash.update(`${String(part.byteLength)}:`).update(part)
  return hash.digest('hex').slice(0, HASH_REVISION_LENGTH)
}
const artifactRevision = bundle => framedHash('plugin-artifact', [bundle])
/** Address one ordered plugin-file list through the shared combo route. */
const comboUrl = (ids, rev, sourceMap = false) =>
  `/plugins/??${ids.map(id => `${id}/client.js${sourceMap ? '.map' : ''}`).join(',')}&rev=${rev}`
const comboRevision = resources =>
  framedHash('combo', resources.flatMap(resource => [Buffer.from(resource.id), Buffer.from(resource.rev)]))
const projectedComboUrlBytes = ids =>
  Buffer.byteLength(comboUrl(ids, COMBO_REVISION_PLACEHOLDER, true))
/** Partition one phase in graph order without exceeding the combo URL limit. */
function partitionIds(ids) {
  const chunks = []
  let current = []
  for (const id of ids) {
    const candidate = [...current, id]
    if (projectedComboUrlBytes(candidate) <= MAX_COMBO_URL_BYTES) { current = candidate; continue }
    if (current.length === 0) throw new Error(`gen-boot-manifest: ${id} exceeds the ${MAX_COMBO_URL_BYTES}-byte combo URL limit`)
    chunks.push(current)
    current = [id]
  }
  if (current.length > 0) chunks.push(current)
  return chunks
}
const PARSER_PRELOAD_IDS = ['@deepseek-ai/dsh-client-modules']

// ── roster rows → entries ───────────────────────────────────────────────────
const nameToDir = new Map()
for (const group of ['vendor', 'packages']) {
  const groupDir = join(root, group)
  if (!existsSync(groupDir)) continue
  for (const g of readdirSync(groupDir)) {
    const sub = join(groupDir, g)
    let leaves = []
    try { leaves = readdirSync(sub) } catch { continue }
    for (const leaf of leaves) {
      const manifestPath = join(sub, leaf, 'package.json')
      if (!existsSync(manifestPath)) continue
      try { nameToDir.set(JSON.parse(readFileSync(manifestPath, 'utf8')).name, join(sub, leaf)) } catch {}
    }
  }
}

const entries = []
for (const id of ROSTER) {
  const dir = nameToDir.get(id)
  const clientPath = dir && join(dir, 'lib', 'client.js')
  if (!clientPath || !existsSync(clientPath)) {
    console.error(`gen-boot-manifest: roster row ${id} has no built lib/client.js — build first`)
    process.exit(1)
  }
  const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
  const decl = pkg.dsh && pkg.dsh.client
  if (!decl || decl.platform !== 'web') {
    console.error(`gen-boot-manifest: ${id} lacks a web dsh.client declaration`)
    process.exit(1)
  }
  const clientRel = typeof pkg.exports?.['./client'] === 'string'
    ? pkg.exports['./client']
    : pkg.exports?.['./client']?.default
  if (clientRel !== './lib/client.js') {
    console.error(`gen-boot-manifest: ${id} exports "./client" as ${JSON.stringify(clientRel)}, expected "./lib/client.js"`)
    process.exit(1)
  }
  const rev = artifactRevision(readFileSync(clientPath))
  entries.push({
    id,
    url: comboUrl([id], rev),
    rev,
    ...(Array.isArray(decl.inject) && decl.inject.length > 0 ? { inject: decl.inject } : {}),
    ...(decl.immediately === true ? { immediately: true } : {}),
    ...(Array.isArray(decl.external) && decl.external.length > 0 ? { external: decl.external } : {}),
  })
}

// Inject closure check: every requested cordis service provider must be a
// listed entry or a statically-linked package WITHOUT a web dsh.client
// declaration (in the vite seed — no plugin row to list).
const ids = new Set(entries.map(entry => entry.id))
const missing = []
for (const entry of entries) {
  for (const target of entry.inject ?? []) {
    if (ids.has(target)) continue
    const dir = nameToDir.get(target)
    const pkg = dir && JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    const decl = pkg && pkg.dsh && pkg.dsh.client
    if (decl && decl.platform === 'web') missing.push(`${entry.id} -> ${target}`)
  }
}
if (missing.length > 0) {
  console.error('gen-boot-manifest: inject targets outside the roster:\n  ' + missing.join('\n  '))
  process.exit(1)
}

// ── compose: mirror ClientModuleRegistry.compose() ──────────────────────────
const ordered = orderByModuleGraph(entries)
const bootstrapIds = new Set(PARSER_PRELOAD_IDS)
const bootstrap = ordered.filter(entry => bootstrapIds.has(entry.id))
const application = ordered.filter(entry => !bootstrapIds.has(entry.id))
const revOf = new Map(ordered.map(entry => [entry.id, entry.rev]))
const batches = []
for (const [phase, group] of [['bootstrap', bootstrap], ['application', application]]) {
  for (const chunk of partitionIds(group.map(entry => entry.id))) {
    const rev = comboRevision(chunk.map(id => ({ id, rev: revOf.get(id) })))
    batches.push({ phase, url: comboUrl(chunk, rev), rev, entries: chunk })
  }
}
const graph = { rev: shortHash(JSON.stringify({ entries: ordered, batches })), entries: ordered, batches }
const injections = bootInjections(graph)

const outDir = join(root, 'build-artifacts')
mkdirSync(outDir, { recursive: true })
const outFile = join(outDir, 'boot-manifest.json')
writeFileSync(outFile, JSON.stringify({ graph, injections, roster: ROSTER }, null, 2) + '\n')
console.log(`gen-boot-manifest: ${ordered.length} rows, ${batches.length} batches, graph rev ${graph.rev}`)
console.log(`gen-boot-manifest: wrote ${outFile}`)
for (const injection of injections) {
  console.log(`  row: ${injection.kind}${injection.kind === 'script-src' ? ` ${injection.src}` : injection.kind === 'global' ? ` ${injection.name}` : ''}`)
}
