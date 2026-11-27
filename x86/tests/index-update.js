// `a[i]++`, `a[i]--`, `++a[i]` and `--a[i]`: the old number or the new, and
// the item stepped, on an array's items, whole and fractional, an object's
// property by a computed key, a value whose kind isn't known, and a receiver
// that is `undefined`.
const a = [1, 2.5, 10];
console.log(a[0]++, a[0], ++a[0], a[0], a[2]--, a[2], --a[2], a[2]);
console.log(a[1]++ === 2.5, a[1] === 3.5, --a[1] === 2.5, a[1] === 2.5);
a[1]++;
a[1]++;
--a[1];
console.log(a[1] === 3.5, a.length);

const counts = [0, 0, 0];
for (let i = 0; i < 10; i++) counts[i % 3]++;
console.log(counts);
let i = 0;
counts[i++]--;
console.log(i, counts, counts[i]++ + counts[i]++, counts);

const tally = {};
for (const word of ["red", "blue", "red", "green", "red"]) {
  if (tally[word] === undefined) tally[word] = 0;
  tally[word]++;
}
const key = "blue";
console.log(tally, tally[key]--, tally[key], ++tally["green"], --tally[key]);

const byNumber = { 1: 5 };
byNumber[1]++;
console.log(byNumber[1], ++byNumber[1], byNumber);

const halves = { h: 0.5 };
const h = "h";
halves[h]++;
console.log(halves[h] === 1.5, -halves[h]++ === -1.5, halves.h === 2.5);

const rows = new Map();
rows.set("x", [0, 0]);
rows.set("y", { n: 7 });
const row = rows.get("x");
row[1]++;
row[1]++;
const other = rows.get("y");
other["n"]--;
console.log(row, other, rows.get("x")[0]++, rows.get("x"));

let missing;
try {
  missing[0]++;
} catch (e) {
  console.log(e.message);
}
