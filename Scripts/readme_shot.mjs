// node shot.mjs <url> <out.png> <width> <height> [readyExpression] [beforeShotExpression]
import { spawn } from 'node:child_process'
import { writeFile, rm } from 'node:fs/promises'

const [url, out, w = '1440', h = '1000', ready = 'document.readyState === "complete"', before = ''] = process.argv.slice(2)
const port = 9400 + Math.floor(Math.random() * 400)
const profile = `${process.env.TMPDIR ?? '/tmp'}/cdp-${port}`
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, `--window-size=${w},${h}`, 'about:blank',
], { stdio: 'ignore' })
const sleep = ms => new Promise(r => setTimeout(r, ms))
async function targets() {
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/json`); return await r.json() } catch { await sleep(200) }
  }
  throw new Error('Chrome did not start')
}
const page = (await targets()).find(t => t.type === 'page')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
const errors = []
ws.onmessage = e => {
  const m = JSON.parse(e.data)
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text)
  if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(m.params.args.map(a => a.value ?? a.description).join(' '))
}
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })) })
const evaluate = async expression => (await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })).result?.result?.value
await send('Runtime.enable')
await send('Page.enable')
await send('Emulation.setDeviceMetricsOverride', { width: +w, height: +h, deviceScaleFactor: Number(process.env.SCALE) || 1, mobile: +w < 600 })
if (process.env.TRANSPARENT) await send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } })
if (process.env.COLOR_SCHEME) await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: process.env.COLOR_SCHEME }] })
await send('Page.navigate', { url })
const deadline = Date.now() + 150000
let readyNow = false
while (Date.now() < deadline) {
  try { readyNow = !!(await evaluate(ready)) } catch { readyNow = false }
  if (readyNow) break
  await sleep(500)
}
if (before) { await evaluate(before); await sleep(900) }
await sleep(1200)
const docHeight = await evaluate('Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)')
const height = Math.min(docHeight || +h, 4000)
const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width: +w, height, scale: 1 } })
await writeFile(out, Buffer.from(shot.result.data, 'base64'))
const overflow = await evaluate('JSON.stringify({ scrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth })')
await writeFile(`${out}.json`, JSON.stringify({ out, ready: readyNow, height, overflow: JSON.parse(overflow), errors }, null, 1))
ws.close()
chrome.kill('SIGKILL')
await sleep(300)
await rm(profile, { recursive: true, force: true })
process.exit(0)
