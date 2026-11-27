// canvas_shots -- the book's pictures of the playground, taken in headless
// Chromium: three samples' canvases as they stand once each has drawn, and
// the memory view's chart of the garbage sample's heap. Each is written as a
// PNG into js-book/shots/, where js-book/book.shale finds the ones the
// manuscript's ```shot fences name and puts them beside the pages.
//
//   node js-book/canvas_shots.mjs <page-url> <shots-dir>
//
// A canvas is taken as its own pixels (`toDataURL`), 400 by 400, so a shot
// holds the drawing alone; the memory view's top chart is taken as a clip of
// the page. The shots are checked in: run this again when a sample's drawing
// changes, read the pictures, and commit them with the change. It prints one
// line a shot, and exits 1 when a sample is missing, the page threw, or a
// canvas came out one color.
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { evaluate, load, sleep, tab, withBrowser } from "../tools/chromium.mjs";

const [url, dir] = process.argv.slice(2);
if (!url || !dir) {
  console.error("usage: node js-book/canvas_shots.mjs <page-url> <shots-dir>");
  process.exit(2);
}

// Each shot: the sample by words of its title, how long it runs before the
// shot, and the points (canvas units) clicked once it has started.
const CANVASES = [
  { file: "turtle-spiral.png", words: "turtle spiral", wait: 4000, clicks: [] },
  { file: "fractal-tree.png", words: "fractal tree", wait: 3000, clicks: [] },
  { file: "click-dots.png", words: "Click to place", wait: 1500, clicks: [[90, 110], [300, 80], [200, 220], [120, 320], [320, 300], [250, 150]] },
];
const MEMORY = { file: "garbage-memory.png", words: "garbage collection", wait: 6000 };

const pick = (words) => `(() => {
  const select = document.querySelector("select");
  const o = [...select.options].find((o) => o.textContent.includes(${JSON.stringify(words)}));
  if (!o) return null;
  select.value = o.value;
  select.dispatchEvent(new Event("change"));
  const speed = document.querySelectorAll("select")[1];
  if (speed) speed.value = "0";
  [...document.querySelectorAll("button")].find((b) => b.textContent === "Run").click();
  return o.textContent;
})()`;

const COLORS = `(() => {
  const c = document.querySelector("canvas");
  const d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
  const seen = new Set();
  for (let i = 0; i < d.length; i += 4) seen.add((d[i] << 16) | (d[i + 1] << 8) | d[i + 2]);
  return seen.size;
})()`;

let bad = false;
await withBrowser(async (link) => {
  for (const s of CANVASES) {
    const page = await tab(link, { width: 1280, height: 900 });
    await load(link, page, url);
    const picked = await evaluate(page, pick(s.words));
    if (!picked) { console.log(`no sample's title holds \`${s.words}\``); bad = true; continue; }
    await sleep(500);
    for (const [cx, cy] of s.clicks) {
      const box = await evaluate(page, `(() => { const b = document.querySelector("canvas").getBoundingClientRect(); return { left: b.left, top: b.top, width: b.width }; })()`);
      const x = box.left + (cx * box.width) / 400;
      const y = box.top + (cy * box.width) / 400;
      for (const type of ["mousePressed", "mouseReleased"]) {
        await page.send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
      }
      await sleep(200);
    }
    await sleep(s.wait);
    const data = await evaluate(page, `document.querySelector("canvas").toDataURL("image/png")`);
    const file = join(dir, s.file);
    writeFileSync(file, Buffer.from(data.slice(data.indexOf(",") + 1), "base64"));
    const colors = await evaluate(page, COLORS);
    console.log(`${file}: ${picked}, ${colors} colors`);
    if (colors < 2) bad = true;
    for (const t of page.thrown) { console.log(`thrown: ${t}`); bad = true; }
  }

  const page = await tab(link, { width: 900, height: 1100 });
  await load(link, page, url);
  const picked = await evaluate(page, pick(MEMORY.words));
  if (!picked) { console.log(`no sample's title holds \`${MEMORY.words}\``); bad = true; return; }
  await sleep(MEMORY.wait);
  await evaluate(page, `[...document.querySelectorAll("button")].find((b) => b.textContent === "memory").click()`);
  await sleep(800);
  const box = await evaluate(page, `(() => { const b = document.querySelector(".memory .chart").getBoundingClientRect(); return { x: b.left, y: b.top, width: b.width, height: b.height }; })()`);
  const { data } = await page.send("Page.captureScreenshot", { format: "png", clip: { ...box, scale: 1 } });
  const file = join(dir, MEMORY.file);
  writeFileSync(file, Buffer.from(data, "base64"));
  console.log(`${file}: ${picked}, the memory view's chart, ${Math.round(box.width)} by ${Math.round(box.height)}`);
  for (const t of page.thrown) { console.log(`thrown: ${t}`); bad = true; }
}, { args: ["--window-size=1280,1100"] });
process.exit(bad ? 1 : 0);
