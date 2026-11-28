// The lazy sweep (x86/COLLECTOR.md, "Lazy sweep, as built"): a collection
// marks, and each page is swept when its size class next needs a block; a
// block is zeroed when it is handed out, not when it dies. Small enough for
// the torture tier, which collects at every allocation, so every block here
// is handed out again from a page swept lazily, its old contents still in it.

// Garbage in every size class, from 16 bytes to a large block of its own
// pages: strings of each length, made and dropped, each checked as it is
// made.
let lengths = 0;
let bad = 0;
for (let n = 1; n <= 80000; n = n * 2 + 1) {
  for (let r = 0; r < 3; r++) {
    let s = "ab" + r;
    while (s.length < n) s = s + s;
    s = s.slice(0, n);
    if (s.length !== n || s[n - 1] !== "ab0ab1ab2"[(n - 1) % 3 + 3 * r]) bad++;
    lengths += s.length;
  }
}
console.log("strings", lengths, bad);

// Arrays and objects of each size, dropped, their blocks handed out again:
// every new one must read as new, holes and missing keys included.
let fresh = 0;
for (let n = 0; n < 70; n += 3) {
  const a = [];
  for (let i = 0; i < n; i++) a.push({ i, tag: "t" + i, more: [i, i + 1] });
  const b = [];
  for (let i = 0; i < n; i++) b.push(i);
  const o = {};
  if (o.i === undefined && o.tag === undefined && Object.keys(o).length === 0) fresh++;
  const c = [];
  let holes = 0;
  for (let i = 0; i < n; i++) if (c[i] === undefined) holes++;
  if (holes === n && b.length === n && a.length === n) fresh++;
}
console.log("fresh", fresh);

// Long-lived objects among the churn: a ring of 50 kept, one replaced each
// turn, each holding strings and an array the next turn checks.
const ring = [];
for (let i = 0; i < 50; i++) ring.push({ id: i, name: "n" + i, items: [i, i * 2] });
let checked = 0;
for (let turn = 0; turn < 400; turn++) {
  const k = (turn * 7) % 50;
  const old = ring[k];
  if (old.name === "n" + old.id && old.items[1] === old.id * 2) checked++;
  const id = old.id + 50;
  ring[k] = { id, name: "n" + id, items: [id, id * 2] };
  const junk = [{ a: turn }, "x" + turn, [turn, turn]];
  if (junk[0].a !== turn) checked = -1000;
}
let total = 0;
for (const r of ring) total += r.id + r.items[1];
console.log("ring", checked, total);

// A dead object whose block holds the only pointers to other dead blocks:
// those blocks are handed out again while the stale pointers still sit in
// the dead block, which nothing may read.
let reused = 0;
for (let turn = 0; turn < 60; turn++) {
  let holder = { left: { v: turn }, right: [turn, "s" + turn], text: "h" + turn };
  holder = null;
  const left = { v: -1 };
  const right = [-1, "fresh"];
  if (left.v === -1 && right[1] === "fresh" && right.length === 2) reused++;
}
console.log("reused", reused);

// Maps and Sets past their hashed index's threshold, rebuilt as they grow
// and shrink across collections.
const m = new Map();
const s = new Set();
for (let i = 0; i < 300; i++) {
  m.set("k" + i, i);
  s.add(i % 37);
  if (i % 3 === 0) m.delete("k" + (i - 30));
}
let found = 0;
for (let i = 0; i < 300; i++) if (m.get("k" + i) === i) found++;
console.log("map", m.size, found, s.size, s.has(36), s.has(37));
for (let i = 0; i < 300; i++) m.delete("k" + i);
for (let i = 0; i < 20; i++) m.set(i, "v" + i);
console.log("map again", m.size, m.get(7), m.get("k7"), [...m.keys()].slice(0, 5));

// One-byte strings and literals among strings built from them.
const words = [];
for (let i = 0; i < 200; i++) {
  const ch = "abcdefghij"[i % 10];
  words.push(ch + ch.toUpperCase() + "-" + i);
}
let joined = "";
for (const w of words) if (w[0] === "c") joined += w[1];
console.log("letters", joined, words[123], words.length, "q" === "qq"[1]);
