// One-byte strings made as the program runs are made once, in the
// read-only segment (x86/roc/RuntimeBuilders.roc's `one_byte_texts`): an
// index or `charAt` of a string, a walk of its characters, a spread, a
// split into characters or at a separator, a slice of one byte and a
// number of one digit. Each is held here against the literal and the
// string built of the same byte, for every ASCII byte, as a value, an
// equality, a Map's and a Set's key and an object's key.
let all = "";
for (let c = 0; c < 128; c++) all += String.fromCharCode(c);
console.log(all.length);

let same = 0;
let codes = 0;
for (let i = 0; i < all.length; i++) {
  const a = all[i];
  const b = all.charAt(i);
  const c = all.slice(i, i + 1);
  const d = all.substring(i, i + 1);
  const e = String.fromCharCode(i);
  if (a === b && b === c && c === d && d === e && a.length === 1) same++;
  codes += a.charCodeAt(0) + b.charCodeAt(0);
}
console.log(same, codes);

let walked = 0;
let count = 0;
for (const ch of all) {
  walked += ch.charCodeAt(0);
  count += ch.length;
}
console.log(walked, count);

const spread = [...all];
console.log(spread.length, spread[65], spread[97] + spread[48], spread[126] === "~");
const pieces = all.split("");
console.log(pieces.length, pieces.join("") === all, pieces[33] === "!");

// Pieces of one byte and of none, at a separator.
const parts = "a,b,,c,dd,e,,".split(",");
console.log(parts, parts.length, parts[2] === "", parts[0] === "a");
console.log("x".split(","), ",".split(","), "".split(","));
console.log("abc".slice(1, 2), "abc".slice(2), "abc".slice(-1), "abc".slice(1, 1) === "");

// The literal, the table's string and a built one are equal, and are one key.
const m = new Map();
for (const ch of "hello world") m.set(ch, (m.get(ch) ?? 0) + 1);
console.log(m.get("l"), m.get("o"), m.get(" "), m.get("w"), m.has("z"), m.size);
const built = "qr".slice(0, 1);
m.set(built, 7);
console.log(m.get("q"), m.get(all[113]), m.get("q" + ""), m.size);
m.set("q", 8);
console.log(m.get(built), m.size);
const s = new Set("mississippi".split(""));
console.log(s.size, s.has("s"), s.has("p"), s.has("m" + "i"));
for (const ch of "missouri") s.add(ch);
console.log(s.size, [...s].join(""));

const o = {};
for (const ch of "banana") o[ch] = (o[ch] || 0) + 1;
console.log(o, o.b, o["n"], Object.keys(o).join("|"));

// Digits.
let digits = "";
for (let i = 0; i < 10; i++) digits += String(i);
console.log(digits, String(7) === "7", `${3}` === "3", String(-4), String(10));
const counts = new Map();
for (let i = 0; i < 300; i++) {
  const key = String(i % 10);
  counts.set(key, (counts.get(key) ?? 0) + 1);
}
console.log(counts.get("3"), counts.get(all[57]), counts.size);

// Printed as node prints them, quoted and escaped inside an array.
console.log([all[0], all[9], all[10], all[39], all[34], all[92], all[127], all[65]]);
console.log(all[200], all.charAt(200) === "");
