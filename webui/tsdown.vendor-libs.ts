/**
 * zharness vendored-build helper: build the vendored framework libraries
 * (vendor/*) exactly as upstream's host-face root tsdown defaults do, but
 * scoped to vendor only and without the Typert plugin.
 *
 * Upstream equivalent (tsdown.config.ts host face): workspace globs cover
 * `vendor/*`; each package emits lib/{index,invariant,startup}.js from its
 * tsc-emitted lib/types JavaScript. apps/web's vite build resolves these
 * through their exports maps (`./lib/index.js`) into the static seed chunk.
 *
 * Run from webui/dsh (this file lives inside the vendored tree because tsdown
 * resolves `workspace` globs relative to the config file directory):
 *   pnpm exec tsdown --config ../tools/tsdown.vendor-libs.ts
 */
export default {
  workspace: [
    'vendor/cordis',
    'vendor/cosmokit',
    'vendor/schemastery',
    'vendor/group',
    'vendor/include',
    'vendor/timer',
    'vendor/loader',
  ],
  entry: ['lib/types/{index,invariant,startup}.js'],
  outDir: 'lib',
  format: ['esm'],
  platform: 'node',
  target: 'es2024',
  fixedExtension: false,
  dts: false,
  clean: false,
}
