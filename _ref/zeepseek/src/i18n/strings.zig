const std = @import("std");

pub const Locale = enum(u8) {
    en,
    ja,
    zh_Hans,
    pt_BR,
};

pub const Strings = struct {
    status_ready: []const u8,
    status_streaming: []const u8,
    status_error: []const u8,
    status_cache_hit: []const u8,
    status_cache_miss: []const u8,
    status_connected: []const u8,
    status_disconnected: []const u8,
    msg_no_api_key: []const u8,
    msg_welcome: []const u8,
    msg_thinking: []const u8,
    msg_tool_call: []const u8,
    msg_tool_result: []const u8,
    msg_session_cleared: []const u8,
    msg_session_forked: []const u8,
    cmd_palette_hint: []const u8,
    cmd_approve_tool: []const u8,
    cmd_deny_tool: []const u8,
    err_network: []const u8,
    err_rate_limit: []const u8,
    err_timeout: []const u8,
    err_api_key: []const u8,
    err_context_full: []const u8,
    err_unknown: []const u8,
    tool_shell: []const u8,
    tool_file_read: []const u8,
    tool_file_write: []const u8,
    tool_git_status: []const u8,
    tool_git_commit: []const u8,
    tool_git_push: []const u8,
    tool_web_search: []const u8,
    tool_web_fetch: []const u8,
    prompt_placeholder: []const u8,
    prompt_queue: []const u8,
    prompt_api_key: []const u8,
    prompt_tool_approval: []const u8,
    subagent_panel_title: []const u8,
    subagent_no_tasks: []const u8,
};

const en_strings = Strings{
    .status_ready = "Ready",
    .status_streaming = "Streaming...",
    .status_error = "Error",
    .status_cache_hit = "Cache hit",
    .status_cache_miss = "Cache miss",
    .status_connected = "Connected",
    .status_disconnected = "Disconnected",
    .msg_no_api_key = "No API key. Set DEEPSEEK_API_KEY.",
    .msg_welcome = "Welcome to Zeepseek! Type your message and press Enter.",
    .msg_thinking = "Thinking...",
    .msg_tool_call = "Calling tool",
    .msg_tool_result = "Tool result",
    .msg_session_cleared = "Session cleared",
    .msg_session_forked = "Session forked",
    .cmd_palette_hint = "Ctrl+K for commands",
    .cmd_approve_tool = "Approve",
    .cmd_deny_tool = "Deny",
    .err_network = "Network error",
    .err_rate_limit = "Rate limit exceeded",
    .err_timeout = "Request timeout",
    .err_api_key = "Invalid API key",
    .err_context_full = "Context window full",
    .err_unknown = "Unknown error",
    .tool_shell = "Shell Command",
    .tool_file_read = "Read File",
    .tool_file_write = "Write File",
    .tool_git_status = "Git Status",
    .tool_git_commit = "Git Commit",
    .tool_git_push = "Git Push",
    .tool_web_search = "Web Search",
    .tool_web_fetch = "Web Fetch",
    .prompt_placeholder = "Type a message, or / for commands",
    .prompt_queue = "Type to queue… (auto-sends when done)",
    .prompt_api_key = "Enter API key...",
    .prompt_tool_approval = "Tool awaiting approval — Enter allow / Esc deny",
    .subagent_panel_title = "SubAgents",
    .subagent_no_tasks = "(no tasks)",
};

const ja_strings = Strings{
    .status_ready = "準備完了",
    .status_streaming = "ストリーミング中...",
    .status_error = "エラー",
    .status_cache_hit = "キャッシュヒット",
    .status_cache_miss = "キャッシュミス",
    .status_connected = "接続済み",
    .status_disconnected = "未接続",
    .msg_no_api_key = "APIキーが設定されていません。DEEPSEEK_API_KEY を設定してください。",
    .msg_welcome = "Zeepseekへようこそ！メッセージを入力してEnterを押してください。",
    .msg_thinking = "思考中...",
    .msg_tool_call = "ツール呼び出し中",
    .msg_tool_result = "ツール結果",
    .msg_session_cleared = "セッションをクリアしました",
    .msg_session_forked = "セッションをフォークしました",
    .cmd_palette_hint = "Ctrl+K でコマンドパレット",
    .cmd_approve_tool = "承認",
    .cmd_deny_tool = "拒否",
    .err_network = "ネットワークエラー",
    .err_rate_limit = "レート制限を超えました",
    .err_timeout = "リクエストタイムアウト",
    .err_api_key = "APIキーが無効です",
    .err_context_full = "コンテキストウィンドウがいっぱいです",
    .err_unknown = "不明なエラー",
    .tool_shell = "シェルコマンド",
    .tool_file_read = "ファイル読み取り",
    .tool_file_write = "ファイル書き込み",
    .tool_git_status = "Git ステータス",
    .tool_git_commit = "Git コミット",
    .tool_git_push = "Git プッシュ",
    .tool_web_search = "Web 検索",
    .tool_web_fetch = "Web 取得",
    .prompt_placeholder = "メッセージを入力、または / でコマンド",
    .prompt_queue = "入力すると待機キューに追加… (完了時に自動送信)",
    .prompt_api_key = "APIキーを入力...",
    .prompt_tool_approval = "ツール承認待ち — Enter で許可 / Esc で拒否",
    .subagent_panel_title = "サブエージェント",
    .subagent_no_tasks = "(タスクなし)",
};

const zh_hans_strings = Strings{
    .status_ready = "就绪",
    .status_streaming = "流式输出中...",
    .status_error = "错误",
    .status_cache_hit = "缓存命中",
    .status_cache_miss = "缓存未命中",
    .status_connected = "已连接",
    .status_disconnected = "未连接",
    .msg_no_api_key = "未设置 API 密钥，请设置 DEEPSEEK_API_KEY。",
    .msg_welcome = "欢迎使用 Zeepseek！输入消息后按回车发送。",
    .msg_thinking = "思考中...",
    .msg_tool_call = "调用工具",
    .msg_tool_result = "工具结果",
    .msg_session_cleared = "会话已清除",
    .msg_session_forked = "会话已分叉",
    .cmd_palette_hint = "Ctrl+K 打开命令面板",
    .cmd_approve_tool = "批准",
    .cmd_deny_tool = "拒绝",
    .err_network = "网络错误",
    .err_rate_limit = "请求频率超限",
    .err_timeout = "请求超时",
    .err_api_key = "API 密钥无效",
    .err_context_full = "上下文窗口已满",
    .err_unknown = "未知错误",
    .tool_shell = "Shell 命令",
    .tool_file_read = "读取文件",
    .tool_file_write = "写入文件",
    .tool_git_status = "Git 状态",
    .tool_git_commit = "Git 提交",
    .tool_git_push = "Git 推送",
    .tool_web_search = "网络搜索",
    .tool_web_fetch = "网页抓取",
    .prompt_placeholder = "输入消息，或 / 查看命令",
    .prompt_queue = "输入内容将等待… (完成后自动发送)",
    .prompt_api_key = "输入 API 密钥...",
    .prompt_tool_approval = "等待工具批准 — Enter 允许 / Esc 拒绝",
    .subagent_panel_title = "子智能体",
    .subagent_no_tasks = "(无任务)",
};

const pt_br_strings = Strings{
    .status_ready = "Pronto",
    .status_streaming = "Transmitindo...",
    .status_error = "Erro",
    .status_cache_hit = "Cache hit",
    .status_cache_miss = "Cache miss",
    .status_connected = "Conectado",
    .status_disconnected = "Desconectado",
    .msg_no_api_key = "Sem chave API. Defina DEEPSEEK_API_KEY.",
    .msg_welcome = "Bem-vindo ao Zeepseek! Digite sua mensagem e pressione Enter.",
    .msg_thinking = "Pensando...",
    .msg_tool_call = "Chamando ferramenta",
    .msg_tool_result = "Resultado da ferramenta",
    .msg_session_cleared = "Sessão limpa",
    .msg_session_forked = "Sessão bifurcada",
    .cmd_palette_hint = "Ctrl+K para comandos",
    .cmd_approve_tool = "Aprovar",
    .cmd_deny_tool = "Negar",
    .err_network = "Erro de rede",
    .err_rate_limit = "Limite de taxa excedido",
    .err_timeout = "Tempo limite da requisição",
    .err_api_key = "Chave API inválida",
    .err_context_full = "Janela de contexto cheia",
    .err_unknown = "Erro desconhecido",
    .tool_shell = "Comando Shell",
    .tool_file_read = "Ler Arquivo",
    .tool_file_write = "Escrever Arquivo",
    .tool_git_status = "Status Git",
    .tool_git_commit = "Commit Git",
    .tool_git_push = "Git Push",
    .tool_web_search = "Busca Web",
    .tool_web_fetch = "Buscar Web",
    .prompt_placeholder = "Digite uma mensagem, ou / para comandos",
    .prompt_queue = "Digite para enfileirar… (envio automático ao terminar)",
    .prompt_api_key = "Digite a chave API...",
    .prompt_tool_approval = "Aguardando aprovação — Enter permite / Esc nega",
    .subagent_panel_title = "Subagentes",
    .subagent_no_tasks = "(sem tarefas)",
};

pub const translations = [_]struct { locale: Locale, strings: Strings }{
    .{ .locale = .en, .strings = en_strings },
    .{ .locale = .ja, .strings = ja_strings },
    .{ .locale = .zh_Hans, .strings = zh_hans_strings },
    .{ .locale = .pt_BR, .strings = pt_br_strings },
};

pub fn getStrings(locale: Locale) Strings {
    for (translations) |t| {
        if (t.locale == locale) return t.strings;
    }
    return en_strings;
}

pub fn localeFromEnvlang(env_lang: []const u8) Locale {
    if (std.ascii.eqlIgnoreCase(env_lang, "ja") or std.mem.startsWith(u8, env_lang, "ja")) return .ja;
    if (std.ascii.eqlIgnoreCase(env_lang, "zh") or std.mem.startsWith(u8, env_lang, "zh")) return .zh_Hans;
    if (std.ascii.eqlIgnoreCase(env_lang, "pt") or std.mem.startsWith(u8, env_lang, "pt")) return .pt_BR;
    return .en;
}

test "locale from envlang" {
    try std.testing.expect(localeFromEnvlang("en_US.UTF-8") == .en);
    try std.testing.expect(localeFromEnvlang("ja_JP.UTF-8") == .ja);
    try std.testing.expect(localeFromEnvlang("zh_CN.UTF-8") == .zh_Hans);
    try std.testing.expect(localeFromEnvlang("pt_BR.UTF-8") == .pt_BR);
    try std.testing.expect(localeFromEnvlang("de_DE.UTF-8") == .en);
}

test "get strings" {
    const en = getStrings(.en);
    try std.testing.expectEqualStrings("Ready", en.status_ready);
    const ja = getStrings(.ja);
    try std.testing.expectEqualStrings("準備完了", ja.status_ready);
    const zh = getStrings(.zh_Hans);
    try std.testing.expectEqualStrings("就绪", zh.status_ready);
    const pt = getStrings(.pt_BR);
    try std.testing.expectEqualStrings("Pronto", pt.status_ready);
}
