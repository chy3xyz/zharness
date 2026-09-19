/** Browser half of the Session-header folder browser. */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-session/client'
import type {} from '@deepseek-ai/dsh-client-ui-workspace/client'
import { FilesBrowserAction, type FilesBrowserInjected } from './FilesBrowserAction.tsx'
import { en, NS, zh, type FilesBrowserKey } from './locales.ts'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Session-header folder-browser copy. */
    'files.browser': FilesBrowserKey
  }
}

export type { FilesBrowserActionProps, FilesBrowserInjected } from './FilesBrowserAction.tsx'

/** Required services: slot seat, locale, workspace browse + create. */
export const inject = ['slots', 'locale', 'uiWorkspace', 'workspaces']

/**
 * Client plugin body: register the dictionaries and the header utility.
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  const uiWorkspace = ctx.get('uiWorkspace')
  const workspaces = ctx.get('workspaces') as unknown as {
    create: (input: { path: string }) => Promise<{ workspaceId: string }>
  }
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'ui-files-browser: dictionaries')
  ctx.slots.inject('conversation.session.header.utilities', () => ctx.slots.register({
    name: 'conversation.session.header.utilities',
    id: 'files-browser',
    order: 5,
    locale: NS,
    inject: (): FilesBrowserInjected => ({
      hooks: {
        uiWorkspace: uiWorkspace as never,
        createWorkspace: (input) => workspaces.create(input),
      },
    }),
  }, FilesBrowserAction))
}
