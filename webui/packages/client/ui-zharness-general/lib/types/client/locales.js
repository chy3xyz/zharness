/** Dictionaries for the agent settings row (zh + en). */
/** Simplified Chinese dictionary (the key-set source of truth). */
export const zh = {
    'agent.title': 'Agent 运行参数',
    'agent.restartHint': '写入 ~/.zharness/config.toml，重启 zharness 后生效',
    'agent.unavailable': '设置服务不可用（无法读取配置文档）',
    'agent.provider': '模型供应商',
    'agent.model': '模型',
    'agent.maxTurns': '最大轮数',
    'agent.reasoningEffort': '推理力度',
    'agent.stream': '流式输出',
    'agent.sandboxMode': '沙箱模式',
};
/** English dictionary, checked complete against the zh key set. */
export const en = {
    'agent.title': 'Agent runtime',
    'agent.restartHint': 'Persisted to ~/.zharness/config.toml; applies to your next message (hot reload).',
    'agent.unavailable': 'Settings service unavailable (cannot read the document).',
    'agent.provider': 'Provider',
    'agent.model': 'Model',
    'agent.maxTurns': 'Max turns',
    'agent.reasoningEffort': 'Reasoning effort',
    'agent.stream': 'Streaming',
    'agent.sandboxMode': 'Sandbox mode',
};
//# sourceMappingURL=locales.js.map