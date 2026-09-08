window.__ModuleLoader__.load({
	id: "@deepseek-ai/dsh-client-ui-zharness-general",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react_jsx_runtime = require("react/jsx-runtime");
		let react = require("react");
		//#region ../../../node_modules/.pnpm/clsx@2.1.1/node_modules/clsx/dist/clsx.mjs
		function r(e) {
			var t, f, n = "";
			if ("string" == typeof e || "number" == typeof e) n += e;
			else if ("object" == typeof e) if (Array.isArray(e)) {
				var o = e.length;
				for (t = 0; t < o; t++) e[t] && (f = r(e[t])) && (n && (n += " "), n += f);
			} else for (f in e) e[f] && (n && (n += " "), n += f);
			return n;
		}
		function clsx() {
			for (var e, t, f = 0, n = "", o = arguments.length; f < o; f++) (e = arguments[f]) && (t = r(e)) && (n && (n += " "), n += t);
			return n;
		}
		//#endregion
		//#region \0dsh-css:/Users/n0x/w4_proj/dev_machine/zharness/webui/dsh/packages/client/ui-zharness-general/src/client/AgentGeneralRow.module.css.mjs
		const css = ".uSF-6a_group{gap:var(--dsw-spacing-2,8px);padding:var(--dsw-spacing-4,16px);border:1px solid var(--dsw-border-secondary,#00000014);border-radius:var(--dsw-radius-lg,12px);flex-direction:column;display:flex}.uSF-6a_title{font-size:var(--dsw-font-size-md,14px);color:var(--dsw-text-primary);font-weight:600}.uSF-6a_hint{font-size:var(--dsw-font-size-xs,12px);color:var(--dsw-text-tertiary);margin:0}.uSF-6a_fields{gap:var(--dsw-spacing-3,12px) var(--dsw-spacing-4,16px);grid-template-columns:repeat(auto-fill,minmax(180px,1fr));display:grid}.uSF-6a_field{gap:var(--dsw-spacing-1,4px);flex-direction:column;display:flex}.uSF-6a_label{font-size:var(--dsw-font-size-xs,12px);color:var(--dsw-text-secondary)}.uSF-6a_input{height:28px;padding:0 var(--dsw-spacing-2,8px);border:1px solid var(--dsw-border-secondary,#00000014);border-radius:var(--dsw-radius-sm,6px);background:var(--dsw-background-primary);color:var(--dsw-text-primary);font-size:var(--dsw-font-size-xs,12px)}.uSF-6a_input:focus{border-color:var(--dsw-brand-primary);outline:none}.uSF-6a_select{appearance:auto}.uSF-6a_toggle{width:16px;height:16px;padding:0}";
		const tagId = "@deepseek-ai/dsh-client-ui-zharness-general/AgentGeneralRow.module.css";
		if (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId) + "]") === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "@deepseek-ai/dsh-client-ui-zharness-general";
			tag.dataset.pluginCss = tagId;
			tag.textContent = css;
			document.head.appendChild(tag);
		}
		var AgentGeneralRow_module_css_default = {
			"field": "uSF-6a_field",
			"fields": "uSF-6a_fields",
			"group": "uSF-6a_group",
			"hint": "uSF-6a_hint",
			"input": "uSF-6a_input",
			"label": "uSF-6a_label",
			"select": "uSF-6a_select",
			"title": "uSF-6a_title",
			"toggle": "uSF-6a_toggle"
		};
		//#endregion
		//#region lib/types/client/AgentGeneralRow.js
		/**
		* The agent settings row registered into the General section: six scalar
		* knobs of the `agent` namespace rendered as plain inputs. Every value change
		* writes through the shared settings scope (`settings.mutate` under the
		* hood); the Host persists to its document and answers with the new revision.
		* Values are free-form scalars on purpose — a hand-edited document must never
		* invalidate the whole section in the browser.
		*/
		/** The fields this row owns, in render order. */
		const FIELDS = [
			{
				field: "provider",
				labelKey: "agent.provider"
			},
			{
				field: "model",
				labelKey: "agent.model"
			},
			{
				field: "maxTurns",
				labelKey: "agent.maxTurns"
			},
			{
				field: "reasoningEffort",
				labelKey: "agent.reasoningEffort",
				choices: [
					"low",
					"medium",
					"high"
				]
			},
			{
				field: "stream",
				labelKey: "agent.stream",
				toggle: true
			},
			{
				field: "sandboxMode",
				labelKey: "agent.sandboxMode",
				choices: [
					"native",
					"process",
					"none"
				]
			}
		];
		/**
		* Render the Agent row.
		* @param props - composed slot props.
		* @returns the row element tree.
		*/
		function AgentGeneralRow({ t, useAgentScope, setField, clearField }) {
			const snapshot = useAgentScope((s) => s);
			const value = snapshot.value ?? {};
			const [drafts, setDrafts] = (0, react.useState)({});
			const revision = snapshot.revision;
			(0, react.useEffect)(() => {
				setDrafts({});
			}, [revision]);
			const draftOf = (field) => drafts[field] ?? (value[field] === void 0 || value[field] === null ? "" : String(value[field]));
			const setDraft = (field, raw) => setDrafts((current) => ({
				...current,
				[field]: raw
			}));
			if (snapshot.status !== "ready") return (0, react_jsx_runtime.jsxs)("div", {
				className: AgentGeneralRow_module_css_default.group,
				children: [(0, react_jsx_runtime.jsx)("div", {
					className: AgentGeneralRow_module_css_default.title,
					children: t("agent.title")
				}), (0, react_jsx_runtime.jsx)("p", {
					className: AgentGeneralRow_module_css_default.hint,
					children: t("agent.unavailable")
				})]
			});
			return (0, react_jsx_runtime.jsxs)("div", {
				className: AgentGeneralRow_module_css_default.group,
				children: [
					(0, react_jsx_runtime.jsx)("div", {
						className: AgentGeneralRow_module_css_default.title,
						children: t("agent.title")
					}),
					(0, react_jsx_runtime.jsx)("p", {
						className: AgentGeneralRow_module_css_default.hint,
						children: t("agent.restartHint")
					}),
					(0, react_jsx_runtime.jsx)("div", {
						className: AgentGeneralRow_module_css_default.fields,
						children: FIELDS.map(({ field, labelKey, choices, toggle }) => (0, react_jsx_runtime.jsxs)("label", {
							className: AgentGeneralRow_module_css_default.field,
							children: [(0, react_jsx_runtime.jsx)("span", {
								className: AgentGeneralRow_module_css_default.label,
								children: t(labelKey)
							}), toggle ? (0, react_jsx_runtime.jsx)("input", {
								type: "checkbox",
								className: clsx(AgentGeneralRow_module_css_default.input, AgentGeneralRow_module_css_default.toggle),
								checked: value[field] === true,
								disabled: !snapshot.writable,
								onChange: (event) => {
									setField(field, event.target.checked);
								}
							}) : choices ? (0, react_jsx_runtime.jsxs)("select", {
								className: clsx(AgentGeneralRow_module_css_default.input, AgentGeneralRow_module_css_default.select),
								value: String(value[field] ?? ""),
								disabled: !snapshot.writable,
								onChange: (event) => {
									if (event.target.value === "") clearField(field);
									else setField(field, event.target.value);
								},
								children: [!choices.includes(String(value[field] ?? "")) ? (0, react_jsx_runtime.jsx)("option", { value: "" }) : null, choices.map((choice) => (0, react_jsx_runtime.jsx)("option", {
									value: choice,
									children: choice
								}, choice))]
							}) : (0, react_jsx_runtime.jsx)("input", {
								type: field === "maxTurns" ? "number" : "text",
								min: field === "maxTurns" ? 1 : void 0,
								className: AgentGeneralRow_module_css_default.input,
								value: draftOf(field),
								placeholder: "默认",
								disabled: !snapshot.writable,
								onChange: (event) => {
									const raw = event.target.value;
									setDraft(field, raw);
									if (raw === "") return clearField(field);
									setField(field, field === "maxTurns" ? Number(raw) : raw);
								}
							})]
						}, field))
					})
				]
			});
		}
		//#endregion
		//#region lib/types/client/locales.js
		/** Dictionaries for the agent settings row (zh + en). */
		/** Simplified Chinese dictionary (the key-set source of truth). */
		const zh = {
			"agent.title": "Agent 运行参数",
			"agent.restartHint": "写入 ~/.zharness/config.toml，重启 zharness 后生效",
			"agent.unavailable": "设置服务不可用（无法读取配置文档）",
			"agent.provider": "模型供应商",
			"agent.model": "模型",
			"agent.maxTurns": "最大轮数",
			"agent.reasoningEffort": "推理力度",
			"agent.stream": "流式输出",
			"agent.sandboxMode": "沙箱模式"
		};
		/** English dictionary, checked complete against the zh key set. */
		const en = {
			"agent.title": "Agent runtime",
			"agent.restartHint": "Persisted to ~/.zharness/config.toml; applies to your next message (hot reload).",
			"agent.unavailable": "Settings service unavailable (cannot read the document).",
			"agent.provider": "Provider",
			"agent.model": "Model",
			"agent.maxTurns": "Max turns",
			"agent.reasoningEffort": "Reasoning effort",
			"agent.stream": "Streaming",
			"agent.sandboxMode": "Sandbox mode"
		};
		//#endregion
		//#region lib/types/client/index.js
		/** Dictionary namespace owned by this plugin. */
		const NS = "zharness-general";
		/**
		* Settings namespace this row owns a view of (the Host registers the section;
		* the schema lives with the zharness settings provider).
		*/
		const AGENT_NAMESPACE = "agent";
		/**
		* Required services (cordis fiber inject). The target slot is declared by
		* ui-settings-general's apply; activation order is unconstrained, so the
		* registration waits on the slot through `slots.inject()`.
		*/
		const inject = [
			"slots",
			"locale",
			"settingsScope"
		];
		/**
		* Register the dictionaries and the agent row once its slot declaration is on
		* the ledger. The injected face carries plain data and callbacks only: the
		* bound scope rides the reserved hooks compartment (the renderer binds it as
		* useAgentScope), and writes go through scope.set/unset closures.
		* @param ctx - client root context.
		*/
		function apply(ctx) {
			ctx.effect(() => ctx.locale.register(NS, {
				zh,
				en
			}), "ui-zharness-general: dictionaries");
			const scope = ctx.settingsScope.bind({ namespace: AGENT_NAMESPACE });
			const injected = () => ({
				hooks: { agentScope: scope },
				setField: (field, value) => {
					scope.set(field, value);
				},
				clearField: (field) => {
					scope.unset(field);
				}
			});
			ctx.slots.inject("settings.general.item", () => ctx.slots.register({
				name: "settings.general.item",
				id: "zharness-agent",
				order: 20,
				locale: NS,
				inject: injected
			}, AgentGeneralRow));
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map