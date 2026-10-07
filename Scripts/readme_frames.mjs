// node Scripts/readme_frames.mjs <page-url> <out-dir> <width> <height> <fps> <light|dark>
// Opens the page once in headless Chrome, then for every frame calls window.render(t)
// and saves a PNG. The page defines window.T, the loop length in seconds.
import { spawn } from 'node:child_process'
import { writeFile, mkdir, rm } from 'node:fs/promises'

const [url, out, w, h, fps, scheme] = process.argv.slice(2)
const port = 9800 + Math.floor(Math.random() * 150)
const profile = `${process.env.TMPDIR ?? '/tmp'}/frames-${port}`
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, `--window-size=${w},${h}`, 'about:blank',
], { stdio: 'ignore' })
const sleep = ms => new Promise(r => setTimeout(r, ms))

let targets
for (let i = 0; i < 100 && !targets; i++) {
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json() } catch { await sleep(200) }
}
const ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })) })
const evaluate = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value

await send('Emulation.setDeviceMetricsOverride', { width: +w, height: +h, deviceScaleFactor: 1, mobile: false })
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] })
await send('Page.enable')
await send('Page.navigate', { url })
for (let i = 0; i < 100 && !(await evaluate('typeof window.render === "function" && document.readyState === "complete"')); i++) await sleep(100)
await sleep(300)

await rm(out, { recursive: true, force: true })
await mkdir(out, { recursive: true })
const total = await evaluate('window.T')
const count = Math.round(total * fps)
for (let i = 0; i < count; i++) {
  await evaluate(`render(${i / fps})`)
  const shot = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: +w, height: +h, scale: 1 } })
  await writeFile(`${out}/${String(i).padStart(4, '0')}.png`, Buffer.from(shot.result.data, 'base64'))
}
console.log(`${count} frames -> ${out}`)
ws.close(); chrome.kill()
await rm(profile, { recursive: true, force: true }).catch(() => {})
process.exit(0)
