// Smoke test run before every deploy (.github/workflows/pages.yml): the page's script parses, and the local demo
// works end to end in English, Spanish and Portuguese without a single JavaScript error. Run locally with
//   node tests/smoke.mjs
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { createRequire } from 'node:module';

const root = new URL('..', import.meta.url).pathname;
let pw;
try { pw = await import('playwright'); } catch { pw = createRequire(import.meta.url)('/opt/node22/lib/node_modules/playwright'); }

const fail = [];
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) fail.push(what); };

// 1. the inline script parses
const html = await readFile(join(root, 'index.html'), 'utf8');
for (const [i, m] of [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].entries()) {
  try { new Function(m[1]); check(true, `inline script ${i + 1} parses`); } catch (e) { check(false, `inline script ${i + 1} parses: ${e.message}`); }
}
for (const f of ['manifest.webmanifest', 'manifest-dev.webmanifest']) {
  try { JSON.parse(await readFile(join(root, f), 'utf8')); check(true, `${f} is valid JSON`); } catch (e) { check(false, `${f}: ${e.message}`); }
}

// 2. the app in a browser, served like GitHub Pages serves it
const types = { '.html': 'text/html', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
const server = createServer(async (req, res) => {
  const p = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^\/+/, '') || 'index.html';
  try { const b = await readFile(join(root, p)); res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' }); res.end(b); }
  catch { res.writeHead(404); res.end(); }
}).listen(0);
const base = `http://localhost:${server.address().port}/index.html`;
const browser = await pw.chromium.launch();
try {
  const errors = [];
  const page = async (url, locale = 'en-GB') => {
    const ctx = await browser.newContext({ locale, timezoneId: 'Europe/Lisbon' });
    const p = await ctx.newPage(); p.setDefaultTimeout(5000);
    p.on('pageerror', e => errors.push(`${url} [${locale}]: ${e.message}`));
    await p.route(/supabase|googleapis|jsdelivr/, r => r.abort());
    await p.goto(url); await p.waitForTimeout(400);
    return p;
  };

  const p = await page(`${base}?env=local`);
  await p.click('text=Francisco'); await p.waitForTimeout(150);
  await p.click('.room'); await p.waitForTimeout(150);
  check(await p.$('.c.today, .g .c') !== null, 'local demo: the calendar renders');
  await p.click('text=valid swap'); await p.waitForTimeout(150);
  const acc = await p.$('button.pill:has-text("Accept")');
  check(!!acc, 'local demo: the swap scenario shows an offer');
  if (acc) { await acc.click(); await p.waitForTimeout(150); }
  check(/Swap confirmed/.test(await p.textContent('#app')), 'local demo: accepting the offer confirms the swap');
  for (const t of ['Feed', 'Schedule', 'Settings']) { await p.click(`.nav button:has-text("${t}")`); await p.waitForTimeout(100); }

  for (const [locale, word] of [['es-ES', 'Calendario'], ['pt-PT', 'Calendário']]) {
    const q = await page(`${base}?env=local`, locale);
    await q.click('text=Francisco'); await q.waitForTimeout(150); await q.click('.room'); await q.waitForTimeout(150);
    check((await q.textContent('body')).includes(word), `local demo in ${locale} shows "${word}"`);
  }

  // dev and prod with the backend unreachable: a clear message, no crash
  for (const env of ['dev', 'prod']) {
    const q = await page(`${base}?env=${env}`); await q.waitForTimeout(400);
    check((await q.textContent('#app')).trim().length > 0, `${env} without a backend still renders`);
  }
  check(errors.length === 0, `no JavaScript errors${errors.length ? ':\n  ' + errors.join('\n  ') : ''}`);
} finally { await browser.close(); server.close(); }

if (fail.length) { console.error(`\n${fail.length} check(s) failed`); process.exit(1); }
console.log('\nall checks passed');
