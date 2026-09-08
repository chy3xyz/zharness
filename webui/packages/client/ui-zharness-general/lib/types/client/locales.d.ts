/** Dictionaries for the agent settings row (zh + en). */
/** Simplified Chinese dictionary (the key-set source of truth). */
export declare const zh: {
    'agent.title': string;
    'agent.restartHint': string;
    'agent.unavailable': string;
    'agent.provider': string;
    'agent.model': string;
    'agent.maxTurns': string;
    'agent.reasoningEffort': string;
    'agent.stream': string;
    'agent.sandboxMode': string;
};
/** The zharness-general namespace key union. */
export type ZharnessGeneralKey = keyof typeof zh;
/** English dictionary, checked complete against the zh key set. */
export declare const en: Record<ZharnessGeneralKey, string>;
//# sourceMappingURL=locales.d.ts.map