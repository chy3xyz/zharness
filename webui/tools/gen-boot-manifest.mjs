#!/usr/bin/env node
/**
 * zharness vendored-build helper: compose the TRIMMED window.__DSH_BOOT__
 * graph (15 plugin rows) from the built vendored tree.
 *
 * Row composition, rev hashing (sha1-12 of lib/client.js), module-graph
 * ordering, and the boot injection rows are delegated to the vendored
 * node half itself (`@deepseek-ai/dsh-client-modules` lib/types exports:
 * orderByModuleGraph + bootInjections), so the output is byte-compatible
 * with what upstream's host would compose for the same package set.
 *
 * The roster is zharness's trimmed list (docs/dsh-reuse-spec.md §5.1/§6):
 * upstream ships ~40 rows; zharness serves 15. Packages with built bundles
 * that are NOT on the roster (currently ui-input-trigger) are simply not
 * listed — the supported degradation mechanism per packages/client/web/src/boot.ts.
 *
 * Output: webui/dsh/build-artifacts/boot-manifest.json
 *   { graph: WebBootGraph, injections: IndexInjection[], roster: string[] }
 *
 * Usage: node ../tools/gen-boot-manifest.mjs   (cwd must be webui/dsh)
 */
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { bootInjections, orderByModuleGraph } from '../dsh/packages/client/modules/lib/types/index.js'

const root = process.cwd()
if (!existsSync(join(root, 'apps/web/dist/index.html'))) {
  console.error('gen-boot-manifest: apps/web/dist missing — run the vite build first')
  process.exit(1)
}

/** zharness trimmed roster (spec §6 "Manifest rows (15)"). */
const ROSTER = [
  '@deepseek-ai/dsh-client-modules',
  '@deepseek-ai/dsh-client-connection',
  '@deepseek-ai/dsh-typert-registry',
  '@deepseek-ai/dsh-api-gateway',
  '@deepseek-ai/dsh-api-remotes',
  '@deepseek-ai/dsh-client-runtime',
  '@deepseek-ai/dsh-client-locale',
  '@deepseek-ai/dsh-client-ui-theme',
  '@deepseek-ai/dsh-client-ui-layout',
  '@deepseek-ai/dsh-client-ui-renderer',
  '@deepseek-ai/dsh-client-ui-sidebar',
  '@deepseek-ai/dsh-client-ui-settings',
  '@deepseek-ai/dsh-client-ui-settings-general',
  '@deepseek-ai/dsh-client-ui-settings-models',
  '@deepseek-ai/dsh-client-ui-settings-plugins',
  '@deepseek-ai/dsh-client-ui-settings-plugin-inventory',
  '@deepseek-ai/dsh-client-ui-zharness-general',
  '@deepseek-ai/dsh-client-ui-conversation',
  '@deepseek-ai/dsh-client-ui-tool',
  '@deepseek-ai/dsh-client-ui-workspace',
  // zharness: composer input-trigger plugin — previously dropped as a §7
  // non-goal, but the wave-6 feature plugins (ui-skill/ui-commands/
  // ui-reference/ui-subagent) inject it, so it is load-bearing again.
  '@deepseek-ai/dsh-client-ui-input-trigger',
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
]

/** sha1 content hash shortened to 12 hex chars — mirrors modules/src/index.ts shortHash. */
const shortHash = input => createHash('sha1').update(input).digest('hex').slice(0, 12)

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
    // Keep the export contract visible: the served path must map to the file we hashed.
    console.error(`gen-boot-manifest: ${id} exports "./client" as ${JSON.stringify(clientRel)}, expected "./lib/client.js"`)
    process.exit(1)
  }
  const rev = shortHash(readFileSync(clientPath))
  entries.push({
    id,
    url: `/plugins/${id}/client.js?rev=${rev}`,
    rev,
    ...(Array.isArray(decl.inject) && decl.inject.length > 0 ? { inject: decl.inject } : {}),
    ...(decl.immediately === true ? { immediately: true } : {}),
    ...(Array.isArray(decl.external) && decl.external.length > 0 ? { external: decl.external } : {}),
  })
}

// Inject closure check: every requested cordis service provider must either be
// a listed entry or a workspace package WITHOUT a web dsh.client declaration
// (statically linked into the vite seed — always present, no plugin row to
// list; e.g. dsh-client-ui-primitives). A client package that is built but
// deliberately unlisted still fails here.
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
  console.error('gen-boot-manifest: inject targets outside the trimmed roster:\n  ' + missing.join('\n  '))
  process.exit(1)
}

const ordered = orderByModuleGraph(entries)
const graph = { rev: shortHash(JSON.stringify(ordered)), entries: ordered }
const injections = bootInjections(graph)

const outDir = join(root, 'build-artifacts')
mkdirSync(outDir, { recursive: true })
const outFile = join(outDir, 'boot-manifest.json')
writeFileSync(outFile, JSON.stringify({ graph, injections, roster: ROSTER }, null, 2) + '\n')
console.log(`gen-boot-manifest: ${ordered.length} rows, graph rev ${graph.rev}`)
console.log(`gen-boot-manifest: wrote ${outFile}`)
for (const injection of injections) {
  console.log(`  row: ${injection.kind}${injection.kind === 'script-src' ? ` ${injection.src}` : injection.kind === 'global' ? ` ${injection.name}` : ''}`)
}
