/**
 * Package-owned invariant companion for `@deepseek-ai/dsh-client-ui-zharness-general`.
 * @module @deepseek-ai/dsh-client-ui-zharness-general/invariant
 */
const PACKAGE_NAME = '@deepseek-ai/dsh-client-ui-zharness-general';
/** Cordis companion plugin name. */
export const name = 'client-ui-zharness-general-invariant';
/** Service required before the companion can reserve package ownership. */
export const inject = ['invariants'];
/**
 * No runtime invariant: a pure-consumer plugin registering one presentational
 * row into the settings General section's item slot plus its locale
 * dictionaries — it reads the shared settings scope, emits no cordis events,
 * and owns no cross-plugin mutable state.
 */
const install = () => { };
/**
 * Register this package's invariant companion.
 * @param ctx - Cordis context carrying the invariant service.
 * @returns the installed registration's disposer after setup succeeds.
 */
export const apply = (ctx) => Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install));
/* jscpd:ignore-end */
//# sourceMappingURL=invariant.js.map