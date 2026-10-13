// Kullanım: node render.mjs [önizleme saniyeleri...]  — argümansız tüm videoyu kareler hâlinde ffmpeg'e verir.
import { chromium } from 'playwright-core';
import { spawn } from 'node:child_process';
import { homedir } from 'node:os';
import path from 'node:path';

const exe = path.join(homedir(), 'Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell');
const browser = await chromium.launch({ executablePath: exe });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto('file://' + path.resolve(process.env.HTML || 'reklam.html'));
await page.waitForTimeout(300);
const times = process.argv.slice(2).map(Number);
if (times.length) {
  for (const t of times) {
    await page.evaluate(t => window.seek(t), t);
    await page.screenshot({ path: `onizleme-${t}.png` });
  }
} else {
  const fps = 30, dur = await page.evaluate(() => window.DURATION);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '17', '-preset', 'slow', 'video.mp4'], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let i = 0; i < dur * fps; i++) {
    await page.evaluate(t => window.seek(t), i / fps);
    const buf = await page.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 150 === 0) console.log(`kare ${i}/${dur * fps}`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
await browser.close();
