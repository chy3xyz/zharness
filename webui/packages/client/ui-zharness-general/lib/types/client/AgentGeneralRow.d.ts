import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots';
import type { SettingsScope } from '@deepseek-ai/dsh-client-runtime/client';
/** Section values as this row reads them (all scalars; absent = inherited default). */
type AgentSection = Record<string, string | number | boolean | undefined>;
/** Injected business face: the bound scope plus the write callbacks. */
export interface AgentGeneralRowInjected {
    hooks: {
        /** The `agent` namespace scope (bound by apply; stable identity). */
        agentScope: SettingsScope<AgentSection>;
    };
    /** Queue one scalar write through the scope. */
    setField: (field: string, value: string | number | boolean) => void;
    /** Queue one override clear so the field re-inherits its default. */
    clearField: (field: string) => void;
}
/** Full component props: runtime share + locale seat + injected face. */
export type AgentGeneralRowComponentProps = PropsRuntime<'settings.general.item'> & PropsLocale<'zharness-general'> & InjectFace<AgentGeneralRowInjected>;
/**
 * Render the Agent row.
 * @param props - composed slot props.
 * @returns the row element tree.
 */
export declare function AgentGeneralRow({ t, useAgentScope, setField, clearField }: AgentGeneralRowComponentProps): import("react").JSX.Element;
export {};
//# sourceMappingURL=AgentGeneralRow.d.ts.map