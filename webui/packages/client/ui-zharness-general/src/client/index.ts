/**
 * zharness General-section plugin, browser half. One registration: the agent
 * runtime row into `settings.general.item`, reading the `agent` namespace
 * through the shared settings scope and writing scalar overrides through it.
 * Export discipline: packages/client/AGENTS.md.
 */
import type { Context as ClientContext } from '@deepseek-ai/cordis'
// Type-only: pulls the SlotRegistry service merge (ctx.slots) into this
// program (the old dsh-client-runtime ClientContext carried it).
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
// Type-only: pulls ctx.locale into this program.
import type {} from '@deepseek-ai/dsh-client-locale/client'
import { AgentGeneralRow, type AgentGeneralRowInjected } from './AgentGeneralRow.tsx'
import { en, zh, type ZharnessGeneralKey } from './locales.ts'

export type { AgentGeneralRowComponentProps, AgentGeneralRowInjected } from './AgentGeneralRow.tsx'
export type { ZharnessGeneralKey } from './locales.ts'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Agent runtime row copy. */
    'zharness-general': ZharnessGeneralKey
  }
}

/** Dictionary namespace owned by this plugin. */
const NS = 'zharness-general'

/**
 * Settings namespace this row owns a view of (the Host registers the section;
 * the schema lives with the zharness settings provider).
 */
const AGENT_NAMESPACE = 'agent'

/**
 * Required services (cordis fiber inject). The target slot is declared by
 * ui-settings-general's apply; activation order is unconstrained, so the
 * registration waits on the slot through `slots.inject()`.
 */
export const inject = ['slots', 'locale', 'settingsScope']

/**
 * Register the dictionaries and the agent row once its slot declaration is on
 * the ledger. The injected face carries plain data and callbacks only: the
 * bound scope rides the reserved hooks compartment (the renderer binds it as
 * useAgentScope), and writes go through scope.set/unset closures.
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'ui-zharness-general: dictionaries')

  const scope = ctx.settingsScope.bind<AgentSection>({ namespace: AGENT_NAMESPACE })
  const injected = (): AgentGeneralRowInjected => ({
    hooks: { agentScope: scope },
    setField: (field, value) => { void scope.set(field, value) },
    clearField: (field) => { void scope.unset(field) },
  })

  ctx.slots.inject('settings.general.item', () => ctx.slots.register({
    name: 'settings.general.item',
    id: 'zharness-agent',
    order: 20,
    locale: NS,
    inject: injected,
  }, AgentGeneralRow))
}

/** Section values as the row reads them (all scalars). */
type AgentSection = Record<string, string | number | boolean | undefined>
