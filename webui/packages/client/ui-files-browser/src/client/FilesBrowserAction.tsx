import { useCallback, useState, type ReactNode } from 'react'
import { IconBrowseOutline16, Tooltip } from '@deepseek-ai/dsh-client-ui-primitives'
import {
  DirectoryBrowser, type DirectoryListing,
} from '@deepseek-ai/dsh-client-ui-directory-picker-browse/client'
import type {
  InjectFace, PropsLocale, PropsRuntime,
} from '@deepseek-ai/dsh-client-ui-slots'
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import type { UiWorkspace } from '@deepseek-ai/dsh-client-ui-workspace/client'
import { NS } from './locales.ts'
import css from './FilesBrowserAction.module.css'

/** Browser operations injected from the workspace services. */
export interface FilesBrowserInjected {
  hooks: {
    /** Directory browse + session navigation capability. */
    uiWorkspace: UiWorkspace
    /** Adopt a directory path as a Workspace (workspace.create). */
    createWorkspace: (input: { path: string }) => Promise<{ workspaceId: string }>
  }
}

/** Full props for the Session-header files-browser action. */
export type FilesBrowserActionProps =
  PropsRuntime<'conversation.session.header.utilities'>
  & PropsLocale<typeof NS>
  & InjectFace<FilesBrowserInjected>

/**
 * Session-header folder browser: one trigger button opening the vendored
 * Miller-columns DirectoryBrowser over the same browse primitives the
 * workspace picker uses. Confirming a directory adopts it as a workspace
 * (workspace.create) and opens a session there; dismissal just closes.
 * @param props - session runtime, injected workspace face, localized copy.
 * @returns the trigger button and dialog, or null outside a session.
 */
export function FilesBrowserAction(props: FilesBrowserActionProps): ReactNode {
  const { sessionId, t } = props
  const { uiWorkspace, createWorkspace } = props.hooks
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)

  const onOpen = useCallback((path: string): void => {
    setBusy(true)
    // Adopt the confirmed directory as a workspace, then open a session in
    // it. A blank session already parked in that directory is reused by the
    // navigation policy (connectWorkspace's summary scan).
    createWorkspace({ path }).then((view) => {
      setBusy(false)
      setOpen(false)
      return uiWorkspace.openWorkspace(view.workspaceId as never)
    }, () => { setBusy(false) })
  }, [uiWorkspace, createWorkspace])

  // The header control serves live sessions; the blank-session hero owns
  // workspace selection already. No session id → not a session surface.
  if (sessionId === undefined) return null

  const listing = (path?: string, signal?: AbortSignal): Promise<DirectoryListing> =>
    uiWorkspace.listDirectory(path, signal)

  return (
    <>
      <Tooltip label={t('trigger.label')} side="bottom" delayMs={500}>
        <button
          type="button"
          className={css.button}
          aria-label={t('trigger.aria')}
          data-active={open || undefined}
          disabled={busy}
          onClick={() => { setOpen(true) }}
        >
          <IconBrowseOutline16 className={css.icon} />
        </button>
      </Tooltip>
      <DirectoryBrowser
        open={open}
        busy={busy}
        listDirectory={listing}
        createDirectory={(path, name) => uiWorkspace.createDirectory(path, name)}
        t={t as never}
        onOpen={onOpen}
        onClose={() => { if (!busy) setOpen(false) }}
      />
    </>
  )
}
