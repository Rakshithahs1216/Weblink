// Records a demo video of the full user flow against the real backend.
// Usage: node record_demo.js <out.webm>
// Env: APP_URL, CHROME override defaults; SHOTS_DIR=<dir> also saves a PNG of each step.
const puppeteer = require('puppeteer-core');
const out = process.argv[2] || __dirname + '/demo.webm';
const APP_URL = process.env.APP_URL || 'http://localhost:5190';
const CHROME = process.env.CHROME || '/usr/bin/google-chrome';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SHOTS_DIR = process.env.SHOTS_DIR;
const W = 412, H = 892;

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: 'new',
    args: ['--no-sandbox', `--window-size=${W},${H}`],
    defaultViewport: { width: W, height: H, deviceScaleFactor: 2 },
  });
  const page = await browser.newPage();
  const labels = () => page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics')].map((e) => (e.getAttribute('aria-label') || e.innerText || '').trim()).filter(Boolean));
  const find = (src) => page.evaluate((src) => {
    const rx = new RegExp(src, 'i');
    const el = [...document.querySelectorAll('flt-semantics, [role=button]')].reverse()
      .find((e) => rx.test((e.getAttribute('aria-label') || e.innerText || '').trim()));
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  }, src);
  // Smooth pointer travel so the viewer can follow the clicks.
  let cursor = { x: W / 2, y: H / 2 };
  const glide = async (x, y, steps = 18) => {
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(cursor.x + ((x - cursor.x) * i) / steps, cursor.y + ((y - cursor.y) * i) / steps);
      await sleep(12);
    }
    cursor = { x, y };
  };
  const click = async (re, pause = 900) => {
    const p = await find(re.source);
    if (!p) throw new Error('not found ' + re + '\n' + (await labels()).join(' | '));
    await glide(p.x, p.y);
    await page.mouse.click(p.x, p.y);
    await sleep(pause);
  };
  const waitFor = async (re, ms = 20000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) { if ((await labels()).some((l) => new RegExp(re.source, 'i').test(l))) return; await sleep(200); }
    throw new Error('timeout ' + re + ' :: ' + (await labels()).join(' | '));
  };
  // Visible pointer overlay (headless screencasts don't draw the cursor).
  const addCursor = () => page.evaluate(() => {
    if (document.getElementById('demo-cursor')) return;
    const c = document.createElement('div');
    c.id = 'demo-cursor';
    c.style.cssText = 'position:fixed;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;' +
      'background:rgba(255,255,255,.35);border:2px solid #fff;box-shadow:0 0 8px rgba(0,0,0,.6);' +
      'pointer-events:none;z-index:2147483647;left:50%;top:50%;transition:transform .1s';
    document.documentElement.appendChild(c);
    addEventListener('pointermove', (e) => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; }, true);
    addEventListener('pointerdown', () => { c.style.transform = 'scale(.7)'; }, true);
    addEventListener('pointerup', () => { c.style.transform = ''; }, true);
  });

  // Screenshot without the demo cursor overlay.
  const shot = async (name) => {
    if (!SHOTS_DIR) return;
    require('fs').mkdirSync(SHOTS_DIR, { recursive: true });
    await page.evaluate(() => { const c = document.getElementById('demo-cursor'); if (c) c.hidden = true; });
    await page.screenshot({ path: `${SHOTS_DIR}/${name}.png` });
    await page.evaluate(() => { const c = document.getElementById('demo-cursor'); if (c) c.hidden = false; });
  };

  await page.goto(APP_URL, { waitUntil: 'networkidle0' });
  await page.waitForSelector('flt-semantics-placeholder', { timeout: 30000 });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  await waitFor(/welcome to weblink/);
  await addCursor();
  const recorder = await page.screencast({ path: out });
  try {
    await sleep(1500);
    await shot('01-login');
    // 1. Login
    await click(/use demo account/, 1200);
    await shot('02-login-demo-account');
    await click(/^log in$/, 300);
    await waitFor(/open joystick control/);
    await sleep(3500); // home telemetry over WebSocket
    await shot('03-home');
    // 2. Video stream
    await click(/start webrtc stream/, 300);
    await waitFor(/webrtc connected/);
    await sleep(5000);
    await shot('04-live-video');
    // 3. Joystick (from the video screen's app-bar shortcut)
    await click(/joystick control/, 2500);
    await shot('05-joystick-idle');
    const cx = W / 2, cy = 713, r = 150;
    await glide(cx, cy);
    await page.mouse.down();
    const path = [];
    for (let t = 0; t <= 1; t += 0.02) path.push([cx, cy - r * 0.9 * Math.min(1, t * 4)]); // push forward
    for (let a = 0; a <= Math.PI * 2; a += 0.08) path.push([cx - r * 0.8 * Math.sin(a), cy - r * 0.8 * Math.cos(a)]); // circle
    for (let i = 0; i < 30; i++) path.push([cx + r * 0.6, cy + r * 0.5]); // reverse-right hold
    for (const [i, [x, y]] of path.entries()) {
      await page.mouse.move(x, y);
      await sleep(45);
      if (i === 70) await shot('06-joystick-driving');
    }
    cursor = { x: path.at(-1)[0], y: path.at(-1)[1] };
    await page.mouse.up();
    await sleep(2000);
    // 4. Telemetry screen (back to home, then open telemetry)
    for (let i = 0; i < 4 && !(await labels()).some((l) => /open joystick control/i.test(l)); i++) {
      await click(/^back$/, 1500);
    }
    await click(/open telemetry details|^telemetry$/, 600);
    await sleep(6000);
    await shot('07-telemetry');
    await click(/^back$/, 1200);
    // 5. Logout
    await click(/log out/, 1200);
    await shot('08-logout-confirm');
    await click(/^log out$/, 400);
    await waitFor(/log in/);
    await sleep(2500);
  } catch (e) {
    console.log('ERROR', e.message.replace(/\n/g, ' // '));
  } finally {
    await recorder.stop();
    await browser.close();
  }
  console.log('saved', out);
})();
