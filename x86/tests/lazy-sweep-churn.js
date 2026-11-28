// The lazy sweep at the heap's real threshold (x86/COLLECTOR.md, "Lazy
// sweep, as built"): about 60 MB of garbage, so the collector runs several
// times without the torture tier, each time leaving most pages to be swept
// when their class next needs a block. Long-lived records, a Map past its
// hashed index's threshold and strings of every class live through it; each
// is checked as it is read back. The torture tier runs it sampled
// (x86/programs.shale's TORTURE_SAMPLED).

const keep = [];
for (let i = 0; i < 300; i++) keep.push({ id: i, name: "keep" + i, tags: [i % 3, i % 5] });
const index = new Map();
for (let i = 0; i < 300; i++) index.set(keep[i].name, keep[i]);

let wrong = 0;
let made = 0;
let bytes = 0;
for (let day = 0; day < 40; day++) {
  // Garbage of the small classes: records, arrays and short strings.
  const today = [];
  for (let i = 0; i < 6000; i++) {
    const rec = { day, i, label: "d" + day + "-" + i, pair: [i, day] };
    today.push(rec);
    made++;
  }
  // Garbage of the bigger classes: strings from 100 bytes to a large block.
  let s = "x" + day;
  while (s.length < 50000) {
    s = s + s;
    bytes += s.length;
  }
  // A day's Map and Set, rebuilt every day, past the hashed threshold.
  const seen = new Map();
  const letters = new Set();
  for (let i = 0; i < 500; i++) {
    const key = today[i * 7].label;
    seen.set(key, i);
    letters.add(key[1]);
  }
  for (let i = 0; i < 500; i++) if (seen.get(today[i * 7].label) !== i) wrong++;
  if (letters.size < 1 || !letters.has(String(day)[0])) wrong++;
  // The long-lived records replaced in turn: the old one dies, the new one
  // must read as new.
  for (let i = 0; i < 30; i++) {
    const k = (day * 31 + i * 11) % 300;
    const old = keep[k];
    if (index.get(old.name) !== old || old.tags[0] !== old.id % 3) wrong++;
    index.delete(old.name);
    const id = old.id + 300;
    const rec = { id, name: "keep" + id, tags: [id % 3, id % 5] };
    keep[k] = rec;
    index.set(rec.name, rec);
  }
  // A day's records read back, last first, after the day's other garbage.
  for (let i = today.length - 1; i >= 0; i -= 97) {
    const r = today[i];
    if (r.label !== "d" + day + "-" + i || r.pair[0] !== i || r.pair[1] !== day) wrong++;
  }
}
let total = 0;
for (const r of keep) {
  if (index.get(r.name) !== r) wrong++;
  total += r.id + r.tags[1];
}
console.log(made, bytes, index.size, total, wrong);
