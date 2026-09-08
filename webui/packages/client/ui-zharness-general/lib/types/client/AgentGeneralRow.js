import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
/**
 * The agent settings row registered into the General section: six scalar
 * knobs of the `agent` namespace rendered as plain inputs. Every value change
 * writes through the shared settings scope (`settings.mutate` under the
 * hood); the Host persists to its document and answers with the new revision.
 * Values are free-form scalars on purpose — a hand-edited document must never
 * invalidate the whole section in the browser.
 */
import { useEffect, useState } from 'react';
import clsx from 'clsx';
import css from './AgentGeneralRow.module.css';
/** The fields this row owns, in render order. */
const FIELDS = [
    { field: 'provider', labelKey: 'agent.provider' },
    { field: 'model', labelKey: 'agent.model' },
    { field: 'maxTurns', labelKey: 'agent.maxTurns' },
    { field: 'reasoningEffort', labelKey: 'agent.reasoningEffort', choices: ['low', 'medium', 'high'] },
    { field: 'stream', labelKey: 'agent.stream', toggle: true },
    { field: 'sandboxMode', labelKey: 'agent.sandboxMode', choices: ['native', 'process', 'none'] },
];
/**
 * Render the Agent row.
 * @param props - composed slot props.
 * @returns the row element tree.
 */
export function AgentGeneralRow({ t, useAgentScope, setField, clearField }) {
    const snapshot = useAgentScope(s => s);
    const value = snapshot.value ?? {};
    // Local draft strings per text/number field: edits render optimistically so
    // a queued scope write (and its revision fold) never snaps the caret back.
    // Drafts reset whenever the HOST revision moves — after one of this row's
    // own writes that is a no-op (server echoes what was typed); after another
    // writer it is the desired refresh.
    const [drafts, setDrafts] = useState({});
    const revision = snapshot.revision;
    useEffect(() => {
        setDrafts({});
    }, [revision]);
    const draftOf = (field) => drafts[field] ?? (value[field] === undefined || value[field] === null ? "" : String(value[field]));
    const setDraft = (field, raw) => setDrafts(current => ({ ...current, [field]: raw }));
    if (snapshot.status !== 'ready') {
        return (_jsxs("div", { className: css.group, children: [_jsx("div", { className: css.title, children: t('agent.title') }), _jsx("p", { className: css.hint, children: t('agent.unavailable') })] }));
    }
    return (_jsxs("div", { className: css.group, children: [_jsx("div", { className: css.title, children: t('agent.title') }), _jsx("p", { className: css.hint, children: t('agent.restartHint') }), _jsx("div", { className: css.fields, children: FIELDS.map(({ field, labelKey, choices, toggle }) => (_jsxs("label", { className: css.field, children: [_jsx("span", { className: css.label, children: t(labelKey) }), toggle ? (_jsx("input", { type: "checkbox", className: clsx(css.input, css.toggle), checked: value[field] === true, disabled: !snapshot.writable, onChange: (event) => { setField(field, event.target.checked); } })) : choices ? (_jsxs("select", { className: clsx(css.input, css.select), value: String(value[field] ?? ''), disabled: !snapshot.writable, onChange: (event) => {
                                // The empty option means "inherit": clear rather than store ''.
                                if (event.target.value === '')
                                    clearField(field);
                                else
                                    setField(field, event.target.value);
                            }, children: [!choices.includes(String(value[field] ?? '')) ? _jsx("option", { value: "" }) : null, choices.map(choice => _jsx("option", { value: choice, children: choice }, choice))] })) : (_jsx("input", { type: field === 'maxTurns' ? 'number' : 'text', min: field === 'maxTurns' ? 1 : undefined, className: css.input, value: draftOf(field), placeholder: "\u9ED8\u8BA4", disabled: !snapshot.writable, onChange: (event) => {
                                const raw = event.target.value;
                                // A blank text field clears the override; numbers stay numeric.
                                setDraft(field, raw);
                                if (raw === '')
                                    return clearField(field);
                                setField(field, field === 'maxTurns' ? Number(raw) : raw);
                            } }))] }, field))) })] }));
}
//# sourceMappingURL=AgentGeneralRow.js.map