/** `files.browser` namespace dictionaries. */

/** Dictionary namespace owned by this plugin. */
export const NS = 'files.browser'

export type FilesBrowserKey =
  | 'trigger.label'
  | 'trigger.aria'
  | 'picked.adopt'

/** Simplified Chinese dictionary (the key-set source of truth). */
export const zh = {
  'trigger.label': '浏览文件夹',
  'trigger.aria': '打开文件夹浏览器',
  'picked.adopt': '在工作区中打开',
} as const

/** English dictionary, key-identical to the Chinese source of truth. */
export const en: Record<FilesBrowserKey, string> = {
  'trigger.label': 'Browse folders',
  'trigger.aria': 'Open the folder browser',
  'picked.adopt': 'Open in workspaces',
} as const
