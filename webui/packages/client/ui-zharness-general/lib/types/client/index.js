import { AgentGeneralRow } from "./AgentGeneralRow.js";
import { en, zh } from "./locales.js";
/** Dictionary namespace owned by this plugin. */
const NS = 'zharness-general';
/**
 * Settings namespace this row owns a view of (the Host registers the section;
 * the schema lives with the zharness settings provider).
 */
const AGENT_NAMESPACE = 'agent';
/**
 * Required services (cordis fiber inject). The target slot is declared by
 * ui-settings-general's apply; activation order is unconstrained, so the
 * registration waits on the slot through `slots.inject()`.
 */
export const inject = ['slots', 'locale', 'settingsScope'];
/**
 * Register the dictionaries and the agent row once its slot declaration is on
 * the ledger. The injected face carries plain data and callbacks only: the
 * bound scope rides the reserved hooks compartment (the renderer binds it as
 * useAgentScope), and writes go through scope.set/unset closures.
 * @param ctx - client root context.
 */
export function apply(ctx) {
    ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'ui-zharness-general: dictionaries');
    const scope = ctx.settingsScope.bind({ namespace: AGENT_NAMESPACE });
    const injected = () => ({
        hooks: { agentScope: scope },
        setField: (field, value) => { void scope.set(field, value); },
        clearField: (field) => { void scope.unset(field); },
    });
    ctx.slots.inject('settings.general.item', () => ctx.slots.register({
        name: 'settings.general.item',
        id: 'zharness-agent',
        order: 20,
        locale: NS,
        inject: injected,
    }, AgentGeneralRow));
}
//# sourceMappingURL=index.js.map