#!/usr/bin/env -S node --require=module
// Run with:  NODE_PATH=$(npm root -g) node scripts/control-mac-chrome.js
// or use the wrapper at scripts/control-mac-chrome.sh
// control-mac-chrome.js — example: drive the Mac's Chrome from the VM.
// Connects over Tailscale to the CDP endpoint that mac-setup/chrome-cdp.sh
// exposes on mosess-macbook-air-3:9222.
//
// Run on the VM:   node ~/projects/dev-workspace/scripts/control-mac-chrome.js
//
// Edit CDP_URL if your Mac's Tailscale IP/hostname changes.

const puppeteer = require('puppeteer-core');

const CDP_URL = process.env.MAC_CDP_URL || 'http://100.78.207.22:9222';

(async () => {
  const browser = await puppeteer.connect({
    browserURL: CDP_URL,
    defaultViewport: null,
  });

  const version = await browser.version();
  console.log('connected to', CDP_URL, '→', version);

  // List existing pages (tabs).
  const pages = await browser.pages();
  console.log('open pages:', pages.length);
  for (const p of pages) console.log('  -', await p.title(), p.url());

  // Open a new tab and navigate somewhere.
  const page = await browser.newPage();
  await page.goto('https://example.com', { waitUntil: 'domcontentloaded' });
  console.log('new tab title:', await page.title());

  // Take a screenshot and save it on the VM so you can scp it down.
  const shotPath = '/tmp/mac-chrome-example.png';
  await page.screenshot({ path: shotPath, fullPage: true });
  console.log('screenshot saved:', shotPath);

  await browser.disconnect();
})().catch((e) => { console.error(e); process.exit(1); });
