// Protocol-level end-to-end probe: create a session (or reuse argv[2]),
// open session.follow on /api/remote.mux, send a prompt (argv[3] or default),
// and print every journal event.
import { createRequire } from 'node:module'
const require = createRequire(new URL('../apps/web/package.json', import.meta.url))
const { WebSocket } = require('ws')
const BASE = 'http://127.0.0.1:3080'
const REUSE_SESSION = process.argv[2] ?? ''
const PROMPT = process.argv[3] ?? '用一句话介绍你自己'
let rpcId = 0
async function rpc(method, payload) {
  const res = await fetch(`${BASE}/api/${method}`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId: `probe-${++rpcId}`, method, payload }),
  })
  return res.json()
}
// 1. create session under the workspace
const sessionId = REUSE_SESSION
  ? REUSE_SESSION
  : (await rpc('session/create', { request: { workspaceId: 'ws-zharness' } }))?.result?.value?.sessionId
console.log('session:', sessionId)
if (!sessionId) process.exit(1)

// 2. open follow stream
const ws = new WebSocket(`${BASE.replace('http', 'ws')}/api/remote.mux`)
const events = []
ws.on('open', () => {
  ws.send(JSON.stringify({ type: 'open', streamId: 'f1', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId } } } } }))
  // 3. prompt
  setTimeout(async () => {
    const r = await rpc('session.prompt', { requestId: `probe-rid-${++rpcId}`, sessionId, mode: 'queue', content: [{ type: 'text', text: PROMPT }] })
    console.log('prompt:', JSON.stringify(r.result ?? r.error)?.slice(0, 100))
  }, 400)
})
ws.on('message', (d) => {
  try {
    const f = JSON.parse(d.toString())
    if (f.type === 'item' && f.value?.type === 'event') {
      const e = f.value.event
      events.push(`${e.type}#${e.seq}`)
      console.log('EVT', e.type, JSON.stringify(e.data)?.slice(0, 110))
    } else if (f.type === 'item') {
      if (f.value?.type === 'assistant-stream') {
        console.log('ASTREAM', JSON.stringify(f.value.frame)?.slice(0, 140))
      } else {
        console.log('ITEM', f.value?.type ?? '?')
      }
    } else if (f.type === 'error') {
      console.log('STREAM-ERR', JSON.stringify(f.error)?.slice(0, 120))
    }
  } catch {}
})
setTimeout(() => {
  console.log('EVENTS:', events.join(' '))
  ws.close(); process.exit(0)
}, 75000)
