// Maps and Sets past the count from which their keys are found by a hash
// (Collections.roc's header): SameValueZero's corners, strings that share a
// slot, objects by identity, deletes during and between walks, and the
// order of the entries after deletes and the index's regrowth.
const filler = (m, n) => {
  for (let i = 0; i < n; i++) m.set(`filler${i}`, i);
  return m;
};

// -0 and 0, NaN however it is made, and whole numbers made as integers
// and as doubles.
const corners = filler(new Map(), 20);
corners.set(-0, "zero");
corners.set(NaN, "nan");
corners.set(15, "fifteen");
const negativeZero = -1 * 0;
console.log(corners.get(0), corners.get(negativeZero), corners.get(-0), corners.has(0));
console.log(corners.get(0 / 0), corners.get(Math.sqrt(-1)), corners.get(NaN), corners.get(-NaN));
console.log(corners.get(7.5 * 2), corners.get(30 / 2), corners.get(Math.floor(15.9)), corners.get(15.000001));
corners.set(0, "zero again");
corners.set(0 / 0, "nan again");
console.log(corners.size, corners.get(-0), corners.get(NaN));
let found = 0;
for (let i = 0; i < 40; i++) {
  if (corners.has(i)) found = found + 1;
}
console.log("whole keys found", found);
const byInteger = new Map();
for (let i = 0; i < 30; i++) byInteger.set(i, i * i);
let fromDoubles = 0;
for (let j = 0; j < 30; j++) fromDoubles = fromDoubles + byInteger.get((j * 3) / 3);
console.log(fromDoubles, byInteger.get(29), byInteger.get(28.5), byInteger.get("29"));

// The same number, the string of it, a boolean, null and undefined are
// five keys.
const kinds = filler(new Map(), 10);
kinds.set(1, "number").set("1", "string").set(true, "true").set(null, "null").set(undefined, "undefined");
console.log(kinds.get(1), kinds.get("1"), kinds.get(true), kinds.get(null), kinds.get(undefined), kinds.get(false));

// k0, k11 and k28 share slot 9 of a 32-slot index, k8, k19 and k20 slot 17:
// each is found past the others, and a key that isn't there is missed past
// them.
const shared = new Map();
for (const k of ["k0", "k11", "k28", "k8", "k19", "k20", "a", "b", "c", "d"]) shared.set(k, k.length);
console.log(shared.get("k0"), shared.get("k11"), shared.get("k28"), shared.get("k20"), shared.get("k9"));
shared.delete("k11");
console.log(shared.get("k0"), shared.get("k11"), shared.get("k28"), shared.has("k11"));
shared.set("k11", 99);
console.log([...shared.keys()].join(" "), shared.get("k11"));

// Strings made as the program runs, found by their bytes; strings of 8
// bytes and more compared a word at a time.
const grid = new Map();
for (let x = 0; x < 12; x++) {
  for (let y = 0; y < 12; y++) grid.set(`${x},${y}`, x * 100 + y);
}
let gridSum = 0;
for (let x = 0; x < 12; x++) gridSum = gridSum + grid.get(`${x},${11 - x}`);
console.log(grid.size, gridSum, grid.get("3,4"), grid.get("3,44"), grid.get("34"));
const words = new Set();
for (const w of "a longer sentence with several longer words repeated longer sentence".split(" ")) words.add(w + w);
console.log(words.size, words.has("longerlonger"), words.has("longerlonge"), words.has("sentencesentence"), [...words]);
const longKeys = new Map();
for (let i = 0; i < 20; i++) longKeys.set("abcdefghijklmnop".slice(0, i), i);
console.log(longKeys.get(""), longKeys.get("abcdefg"), longKeys.get("abcdefgh"), longKeys.get("abcdefghi"), longKeys.get("abcdefghijklmnop"), longKeys.get("abcdefghijklmnoq"));

// Objects by identity: an equal one is another key.
const things = [];
const owners = new Map();
for (let i = 0; i < 30; i++) {
  const thing = { id: i };
  things.push(thing);
  owners.set(thing, `owner${i}`);
}
const list = [1, 2];
const fn = () => 1;
owners.set(list, "list").set(fn, "function");
console.log(owners.get(things[0]), owners.get(things[29]), owners.get({ id: 3 }), owners.get(list), owners.get([1, 2]), owners.get(fn));
const seenThings = new Set(things.filter((t) => t.id % 3 === 0));
console.log(seenThings.size, seenThings.has(things[3]), seenThings.has(things[4]), things.filter((t) => seenThings.has(t)).length);

// Deletes between walks, then the order: the deleted are gone, the rest
// keep their places, and a key set again goes last.
const order = new Map();
for (let i = 0; i < 40; i++) order.set(`n${i}`, i);
for (let i = 0; i < 40; i = i + 2) order.delete(`n${i}`);
console.log(order.size, [...order.values()].join(" "));
for (let i = 40; i < 140; i++) order.set(`n${i}`, i);
for (let i = 0; i < 10; i++) order.set(`n${i}`, -i);
let walked = 0;
let last = "";
for (const [k, v] of order) {
  walked = walked + 1;
  last = k;
}
console.log(order.size, walked, last, order.get("n0"), order.get("n1"), order.get("n2"), order.get("n139"));
console.log([...order.keys()].slice(0, 25).join(" "));
console.log([...order.keys()].slice(-12).join(" "));

// Deletes during a walk: an entry deleted ahead is not met, one set during
// the walk is, and one deleted then set again is met at its new place.
const live = new Map();
for (let i = 0; i < 16; i++) live.set(i, `v${i}`);
const visits = [];
for (const [k, v] of live) {
  visits.push(k);
  if (k === 2) {
    live.delete(5);
    live.delete(3);
    live.set(3, "back");
    live.set(100, "new");
  }
  if (k === 100) live.delete(15);
}
console.log(visits.join(" "), live.size, live.get(3), live.has(5));
const each = [];
live.forEach((v, k) => {
  if (k === 0) live.delete(1);
  each.push(k);
});
console.log(each.join(" "));
const iter = live.keys();
const firstFew = [];
for (const k of iter) {
  firstFew.push(k);
  if (firstFew.length === 3) break;
}
live.delete(6);
live.set(200, "late");
console.log(firstFew.join(" "), [...iter].join(" "));

// clear, then the same keys again past the threshold.
const reused = new Set();
for (let i = 0; i < 50; i++) reused.add(`r${i}`);
reused.clear();
console.log(reused.size, reused.has("r1"), [...reused]);
for (let i = 49; i >= 0; i--) reused.add(`r${i}`);
console.log(reused.size, reused.has("r1"), reused.has("r50"), [...reused].slice(0, 5));
