// Renders the README banners (light and dark) with headless Chromium, from the brand repo's own
// tokens, fonts, chrome stills and the Flow sign.
//
//   IONIAN_BRAND=../brand PLAYWRIGHT_DIR=/path/to/node_modules/.. node scripts/make-banner.mjs
//
// IONIAN_BRAND defaults to ../brand. PLAYWRIGHT_DIR is a folder that has playwright installed
// (`npm i playwright && npx playwright install chromium`); it defaults to the current folder.
import { createRequire } from 'node:module'
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const brand = resolve(process.env.IONIAN_BRAND ?? join(here, '../../brand'))
const out = resolve(join(here, '../docs/images'))
const { chromium } = createRequire(join(resolve(process.env.PLAYWRIGHT_DIR ?? '.'), 'x.js'))('playwright')
const url = (p) => pathToFileURL(join(brand, p)).href
const sign = readFileSync(join(brand, 'assets/signs/flow.svg'), 'utf8').replace(/ width="300" height="300"/, '')

const html = (dark) => `<!doctype html>
<html data-theme="${dark ? 'dark' : 'light'}"><head><meta charset="utf-8">
<link rel="stylesheet" href="${url('dist/tokens.css')}">
<link rel="stylesheet" href="${url('assets/fonts/fonts.css')}">
<style>
  *{box-sizing:border-box;margin:0}
  html,body{width:2000px;height:625px;overflow:hidden}
  body{position:relative;background:var(--bg) url(${url(dark ? 'assets/chrome/night.jpg' : 'assets/chrome/breeze.jpg')}) center 60%/cover no-repeat;color:var(--ink);font-family:var(--font-sans)}
  /* CHR-05: solid for the top 40%, clear by about 78% */
  body::before{content:"";position:absolute;inset:0;background:linear-gradient(180deg,rgb(var(--fade)) 0%,rgb(var(--fade)) 40%,rgba(var(--fade),.86) 52%,rgba(var(--fade),.3) 66%,rgba(var(--fade),0) 78%)}
  .appicon{--s:132px;position:absolute;left:120px;top:104px;width:var(--s);height:var(--s);display:grid;place-items:center;border-radius:calc(var(--s)*.234);background:var(--night) url(${url('assets/chrome/tile-flow.jpg')}) center/cover no-repeat;box-shadow:var(--shadow-icon)}
  .appicon svg{width:72.6%;height:72.6%;filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.55))}
  .text{position:absolute;left:300px;top:92px}
  h1{font-family:var(--font-display);font-weight:600;font-size:112px;line-height:.96;letter-spacing:-.045em}
  p{margin-top:24px;font-size:30px;line-height:1.55;color:var(--muted)}
  .brand{position:absolute;right:120px;top:104px;display:flex;align-items:center;gap:11px;font-family:var(--t-wordmark-family);font-weight:600;font-size:var(--t-wordmark-size);letter-spacing:var(--t-wordmark-tracking)}
  .brand .appicon{position:static;--s:38px;box-shadow:var(--shadow-icon)}
  .brand i{font-style:normal;font-weight:500;color:var(--faint)}
</style></head><body>
  <div class="appicon">${sign}</div>
  <div class="text"><h1>Speak. It lands.</h1><p>Hold a key, talk, let go. The words appear where your cursor is.</p></div>
  <div class="brand"><span class="appicon">${sign}</span><span>ionian <i>/ flow</i></span></div>
</body></html>`

const dir = mkdtempSync(join(tmpdir(), 'banner-'))
const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 2000, height: 625 } })
for (const dark of [false, true]) {
  const file = join(dir, dark ? 'dark.html' : 'light.html')
  writeFileSync(file, html(dark))
  await page.goto(pathToFileURL(file).href)
  await page.evaluate(() => document.fonts.ready)
  await page.screenshot({ path: join(out, dark ? 'banner-dark.png' : 'banner.png') })
}
await browser.close()
