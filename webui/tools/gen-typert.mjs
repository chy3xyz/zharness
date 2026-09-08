#!/usr/bin/env node
/**
 * zharness vendored-build helper: run Typert generation over the pruned
 * frontend closure without the upstream host tsdown pass.
 *
 * Upstream order is: tsc -b tsconfig.host.json (no client projects) →
 * tsdown host pass (typertPlugin writes lib/typert.* artifacts) →
 * tsc -b tsconfig.client.json (client files resolve ./remote subpaths).
 *
 * This helper replaces the middle step: it analyzes only the packages that
 * declare a "./typert" export (the contributor roster, enumerated from
 * package.json manifests), using tsconfig.vendor.json as the registration
 * aggregate, and writes the same artifacts upstream's host pass writes
 * (lib/typert.host.js/.d.ts + lib/typert.remote-client.*).
 *
 * Diagnostics are off here because client-face files legitimately fail
 * before generation (chicken-and-egg on ./remote subpaths); the follow-up
 * `tsc -b tsconfig.vendor.json` provides the equivalent whole-graph check.
 *
 * Usage: node ../tools/gen-typert.mjs   (cwd must be webui)
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { WorkspaceAnalyzer } from '../packages/typert/generator/lib/types/analyzer.js'
import { FaceModelEmitter } from '../packages/typert/generator/lib/types/emitter.js'

const root = process.cwd()
if (!existsSync(join(root, 'tsconfig.vendor.json')) || !existsSync(join(root, 'packages/typert/generator/package.json'))) {
  console.error('gen-typert: run with cwd = webui')
  process.exit(1)
}

/** Package dirs (packages/<group>/<pkg>) declaring a ./typert export. */
const contributors = []
for (const group of readdirSync(join(root, 'packages'))) {
  const groupDir = join(root, 'packages', group)
  let leaves
  try { leaves = readdirSync(groupDir) } catch { continue }
  for (const leaf of leaves) {
    const manifestPath = join(groupDir, leaf, 'package.json')
    if (!existsSync(manifestPath)) continue
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    if (manifest.exports && Object.hasOwn(manifest.exports, './typert')) {
      contributors.push(manifest.name)
    }
  }
}
console.log(`gen-typert: ${contributors.length} contributor package(s)`)

const analyzer = new WorkspaceAnalyzer({
  root,
  hostConfig: 'tsconfig.vendor.json',
  clientConfig: 'tsconfig.vendor.json',
  faces: ['host'],
  packages: contributors,
  checkDiagnostics: false,
  mode: 'write',
})
const face = analyzer.analyze().faces[0]
if (face === undefined) {
  console.error('gen-typert: no face model produced')
  process.exit(1)
}
const emitter = new FaceModelEmitter(face)

let written = 0
const remotes = []
for (const packageModel of face.packages) {
  const artifact = { ...emitter.emit(packageModel.name), packageRoot: packageModel.root }
  const out = join(root, artifact.packageRoot, 'lib')
  mkdirSync(out, { recursive: true })
  writeFileSync(join(out, 'typert.host.js'), artifact.js)
  writeFileSync(join(out, 'typert.host.d.ts'), artifact.dts)
  if (artifact.remote !== undefined) {
    writeFileSync(join(out, 'typert.remote-client.js'), artifact.remote.js)
    writeFileSync(join(out, 'typert.remote-client.d.ts'), artifact.remote.dts)
    writeFileSync(join(out, 'typert.remote-client.d.ts.map'), artifact.remote.dtsMap)
    remotes.push(artifact.package)
  } else {
    // Upstream parity: a host-face artifact without remote contribution removes stale remote files.
    for (const f of ['typert.remote-client.js', 'typert.remote-client.d.ts', 'typert.remote-client.d.ts.map']) {
      rmSync(join(out, f), { force: true })
    }
  }
  written++
}
console.log(`gen-typert: wrote typert.host artifacts for ${written} package(s); ./remote for:`)
for (const name of remotes.sort()) console.log(`  ${name}`)
