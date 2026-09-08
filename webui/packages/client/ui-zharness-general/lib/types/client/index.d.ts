/**
 * zharness General-section plugin, browser half. One registration: the agent
 * runtime row into `settings.general.item`, reading the `agent` namespace
 * through the shared settings scope and writing scalar overrides through it.
 * Export discipline: packages/client/AGENTS.md.
 */
import type { ClientContext } from '@deepseek-ai/dsh-client-runtime/client';
import { type ZharnessGeneralKey } from './locales.ts';
export type { AgentGeneralRowComponentProps, AgentGeneralRowInjected } from './AgentGeneralRow.tsx';
export type { ZharnessGeneralKey } from './locales.ts';
declare module '@deepseek-ai/dsh-client-ui-slots' {
    interface LocaleNamespaceMap {
        /** Agent runtime row copy. */
        'zharness-general': ZharnessGeneralKey;
    }
}
/**
 * Required services (cordis fiber inject). The target slot is declared by
 * ui-settings-general's apply; activation order is unconstrained, so the
 * registration waits on the slot through `slots.inject()`.
 */
export declare const inject: string[];
/**
 * Register the dictionaries and the agent row once its slot declaration is on
 * the ledger. The injected face carries plain data and callbacks only: the
 * bound scope rides the reserved hooks compartment (the renderer binds it as
 * useAgentScope), and writes go through scope.set/unset closures.
 * @param ctx - client root context.
 */
export declare function apply(ctx: ClientContext): void;
//# sourceMappingURL=index.d.ts.map