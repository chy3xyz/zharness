/**
 * The agent settings row registered into the General section: six scalar
 * knobs of the `agent` namespace rendered as plain inputs. Every value change
 * writes through the shared settings scope (`settings.mutate` under the
 * hood); the Host persists to its document and answers with the new revision.
 * Values are free-form scalars on purpose — a hand-edited document must never
 * invalidate the whole section in the browser.
 */
import { useEffect, useState } from 'react'
import clsx from 'clsx'
import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
import type { SettingsScope } from '@deepseek-ai/dsh-client-runtime/client'
import type { ZharnessGeneralKey } from './locales.ts'
// Type-only: pulls the settings slot declarations into this program.
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import css from './AgentGeneralRow.module.css'

/** One scalar field descriptor driving the row's inputs. */
interface FieldSpec {
  /** Namespace field name (the mutate path). */
  field: string
  /** Copy key for the label. */
  labelKey: ZharnessGeneralKey
  /** Render as a select over these choices instead of a text input. */
  choices?: readonly string[]
  /** Render as a checkbox toggle. */
  toggle?: boolean
}

/** The fields this row owns, in render order. */
const FIELDS: readonly FieldSpec[] = [
  { field: 'provider', labelKey: 'agent.provider' },
  { field: 'model', labelKey: 'agent.model' },
  { field: 'maxTurns', labelKey: 'agent.maxTurns' },
  { field: 'reasoningEffort', labelKey: 'agent.reasoningEffort', choices: ['low', 'medium', 'high'] },
  { field: 'stream', labelKey: 'agent.stream', toggle: true },
  { field: 'sandboxMode', labelKey: 'agent.sandboxMode', choices: ['native', 'process', 'none'] },
]

/** Section values as this row reads them (all scalars; absent = inherited default). */
type AgentSection = Record<string, string | number | boolean | undefined>

/** Injected business face: the bound scope plus the write callbacks. */
export interface AgentGeneralRowInjected {
  hooks: {
    /** The `agent` namespace scope (bound by apply; stable identity). */
    agentScope: SettingsScope<AgentSection>
  }
  /** Queue one scalar write through the scope. */
  setField: (field: string, value: string | number | boolean) => void
  /** Queue one override clear so the field re-inherits its default. */
  clearField: (field: string) => void
}

/** Full component props: runtime share + locale seat + injected face. */
export type AgentGeneralRowComponentProps =
  PropsRuntime<'settings.general.item'>
  & PropsLocale<'zharness-general'>
  & InjectFace<AgentGeneralRowInjected>

/**
 * Render the Agent row.
 * @param props - composed slot props.
 * @returns the row element tree.
 */
export function AgentGeneralRow({ t, useAgentScope, setField, clearField }: AgentGeneralRowComponentProps) {
  const snapshot = useAgentScope(s => s)
  const value = snapshot.value ?? {}

  // Local draft strings per text/number field: edits render optimistically so
  // a queued scope write (and its revision fold) never snaps the caret back.
  // Drafts reset whenever the HOST revision moves — after one of this row's
  // own writes that is a no-op (server echoes what was typed); after another
  // writer it is the desired refresh.
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const revision = snapshot.revision
  useEffect(() => {
    setDrafts({})
  }, [revision])

  const draftOf = (field: string): string =>
    drafts[field] ?? (value[field] === undefined || value[field] === null ? "" : String(value[field]))
  const setDraft = (field: string, raw: string): void =>
    setDrafts(current => ({ ...current, [field]: raw }))

  if (snapshot.status !== 'ready') {
    return (
      <div className={css.group}>
        <div className={css.title}>{t('agent.title')}</div>
        <p className={css.hint}>{t('agent.unavailable')}</p>
      </div>
    )
  }

  return (
    <div className={css.group}>
      <div className={css.title}>{t('agent.title')}</div>
      <p className={css.hint}>{t('agent.restartHint')}</p>
      <div className={css.fields}>
        {FIELDS.map(({ field, labelKey, choices, toggle }) => (
          <label key={field} className={css.field}>
            <span className={css.label}>{t(labelKey)}</span>
            {toggle ? (
              <input
                type="checkbox"
                className={clsx(css.input, css.toggle)}
                checked={value[field] === true}
                disabled={!snapshot.writable}
                onChange={(event) => { setField(field, event.target.checked) }}
              />
            ) : choices ? (
              <select
                className={clsx(css.input, css.select)}
                value={String(value[field] ?? '')}
                disabled={!snapshot.writable}
                onChange={(event) => {
                  // The empty option means "inherit": clear rather than store ''.
                  if (event.target.value === '') clearField(field)
                  else setField(field, event.target.value)
                }}
              >
                {!choices.includes(String(value[field] ?? '')) ? <option value="" /> : null}
                {choices.map(choice => <option key={choice} value={choice}>{choice}</option>)}
              </select>
            ) : (
              <input
                type={field === 'maxTurns' ? 'number' : 'text'}
                min={field === 'maxTurns' ? 1 : undefined}
                className={css.input}
                value={draftOf(field)}
                placeholder="默认"
                disabled={!snapshot.writable}
                onChange={(event) => {
                  const raw = event.target.value
                  // A blank text field clears the override; numbers stay numeric.
                  setDraft(field, raw)
                  if (raw === '') return clearField(field)
                  setField(field, field === 'maxTurns' ? Number(raw) : raw)
                }}
              />
            )}
          </label>
        ))}
      </div>
    </div>
  )
}
