// The guarded fast path of a Map's and a Set's `get`, `set`, `has`,
// `delete` and `add` at a call site: Maps and Sets small and hashed, keys of
// every kind (-0 and NaN among them), missing keys, the answers (`set` and
// `add` the receiver, `delete` a boolean), receivers that change at one
// site, objects and classes with methods of the same names, and method
// values taken off and called later.
const keys = [0, -0, 1, 2.5, -7, NaN, 0 / 0, Infinity, "", "a", "0", "NaN", true, false, null, undefined];
const objectKey = { id: 1 };
const arrayKey = [1, 2];
const functionKey = () => 1;
keys.push(objectKey, arrayKey, functionKey);

function fill(m, n) {
  for (let i = 0; i < n; i++) m.set(keys[i % keys.length], i);
  return m;
}

function probe(m) {
  const got = [];
  for (const k of keys) got.push(m.get(k));
  got.push(m.get({ id: 1 }), m.get([1, 2]), m.get("missing"), m.get(-1));
  return got;
}

// Below the index's threshold, then past it.
for (const n of [3, 7, 8, 30]) {
  const m = fill(new Map(), n);
  console.log(n, m.size, probe(m).join(","));
  console.log(m.has(-0), m.has(0), m.has(NaN), m.has(objectKey), m.has({ id: 1 }), m.has("missing"));
}

// The answers.
const m = new Map();
const chained = m.set("a", 1).set("b", 2).set(-0, "zero").set(NaN, "nan");
console.log(chained === m, m.size, m.get(0), m.get(-0), m.get(NaN), m.get(0 / 0));
console.log(m.delete("a"), m.delete("a"), m.delete("missing"), m.size, m.has("a"), m.get("a"));
console.log(m.delete(0), m.has(-0), m.delete(NaN), m.size, m);
m.set("a", 3);
console.log([...m], m.get("a"));
console.log(m.set("x", undefined).get("x"), m.has("x"), m.get("y"));

// Sets.
const s = new Set();
const added = s.add(1).add(-0).add(NaN).add("1").add(objectKey);
console.log(added === s, s.size, s.has(0), s.has(NaN), s.has(1), s.has("1"), s.has(objectKey), s.has({ id: 1 }));
console.log(s.add(0) === s, s.size, s.delete(0), s.delete(0), s.has(-0), s.size, s);
for (let i = 0; i < 40; i++) s.add(i % 13);
console.log(s.size, s.has(12), s.has(13), s.delete(12), s.has(12), s.size);

// Many lookups in a loop, past the index's threshold, with deletes between.
const big = new Map();
for (let i = 0; i < 200; i++) big.set(i, i * 2);
let sum = 0;
for (let i = 0; i < 1000; i++) {
  const k = i % 250;
  const v = big.get(k);
  if (v !== undefined) sum = sum + v;
  if (i % 7 === 0) big.delete(k);
  if (i % 11 === 0) big.set(k + 1000, i);
}
console.log(sum, big.size, big.has(1000), big.get(1000));

// The arguments' counts the fast path doesn't take: too few, too many.
const odd = new Map([["k", 1]]);
console.log(odd.get(), odd.get("k", "extra"), odd.set("u").get("u"), odd.has(), odd.size);
console.log(odd.set("v", 2, 3).get("v"), new Set([undefined]).has(), new Set().add().size);

// Objects and classes with methods of the same names, at the same sites.
class Store {
  constructor() {
    this.items = [];
  }
  get(k) {
    return "store:" + k;
  }
  set(k, v) {
    this.items.push(k + "=" + v);
    return this;
  }
  has(k) {
    return k === "yes";
  }
  delete(k) {
    return "deleted " + k;
  }
  add(k) {
    this.items.push(k);
    return this.items.length;
  }
}
const plain = {
  get: (k) => "plain:" + k,
  set: (k, v) => k + v,
  has: (k) => k === 1,
  delete: () => "plain delete",
  add: (k) => k + 1,
};
const store = new Store();
const receivers = [new Map([["k", "map"]]), plain, store, new Set(["k"]), new Map(), plain];
const kinds = ["map", "object", "object", "set", "map", "object"];
function useAll(r, i) {
  const out = [];
  if (kinds[i] !== "set") {
    out.push(r.get("k"));
    out.push(r.set("k", i) === r);
  }
  out.push(r.has("k"), r.has(1), r.has("yes"));
  if (kinds[i] !== "map") out.push(r.add(i));
  out.push(r.delete("k"));
  return out.join("|");
}
let i = 0;
for (const r of receivers) {
  console.log(i, useAll(r, i));
  i++;
}
console.log(store.items);

// A site whose receiver changes kind as the loop runs.
const mixed = [new Map([[1, "one"]]), { get: (k) => k * 10 }, new Map(), store];
for (let round = 0; round < 3; round++) {
  const line = [];
  for (const r of mixed) line.push(r.get(1));
  console.log(line.join(","));
}

// Method values taken off and called later.
const getOf = plain.get;
const hasOf = store.has;
console.log(getOf("later"), hasOf("yes"));
const calls = [(x) => m.get(x), (x) => s.has(x), (x) => m.set(x, "late").size, (x) => s.add(x).size];
console.log(calls.map((f) => f("a")).join(","));
const later = { m: new Map(), s: new Set() };
later.m.set("k", later.s.add("v"));
console.log(later.m.get("k").has("v"), later.m.has("k"), later.s.delete("v"), later.m.get("k").size);

// `size` read in line, and of receivers that aren't Maps or Sets.
class Sized {
  constructor(n) {
    this.size = n;
  }
}
const sized = [new Map([[1, 2]]), new Set([1, 2, 3]), { size: "own" }, new Sized(9), new Map().keys(), {}];
console.log(sized.map((x) => x.size).join(","));
const growing = new Set();
const sizes = [];
for (let n = 0; n < 12; n++) {
  growing.add(n % 9);
  sizes.push(growing.size);
}
console.log(sizes.join(","));
